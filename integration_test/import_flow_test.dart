import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/routing/app_router.dart';
import 'package:watch_nook/features/import/data/import_providers.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';

/// **#29, US-11 — the import round trip, on a real device.**
///
/// Import a TV Time export → the library fills → bulk-mark a show → import the
/// *same file again* → nothing is duplicated, nothing is destroyed. That last
/// leg is the whole point: an import is a **merge**, not a restore (the
/// import≠restore invariant), and the regressions it guards against — a second
/// item row per show, a second copy of every watch event, a rewatch row
/// appended on every import, the bulk-marked episodes wiped — are all silent.
///
/// Only two seams are stubbed, and both are things a device test cannot drive:
/// the SAF file picker (a platform channel) and the metadata backend (a network
/// call to a live API, which would make this test flaky and key-dependent).
/// Everything between them is the real app: real routing, real screens, real
/// importer, real resolver, real `MergeApplier`, real Drift.
///
/// The DB is in-memory so each run starts from an empty library.
///
// TODO(stuart): extend with the export leg — import → mark → **export** →
// re-import — once `ImportExportService` lands in M4 (#30/#31). Tracked in #47;
// there is no exporter to call today.
void main() {
  patrolTest(
    'import to bulk mark to reimport keeps history intact',
    (
      $,
    ) async {
      // As `main()` does: never fetch a font over the network (offline-first).
      GoogleFonts.config.allowRuntimeFetching = false;

      SharedPreferences.setMockInitialValues({'onboarding_seen': true});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      final export = _tvTimeExportZip();

      await $.pumpWidgetAndSettle(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            appDatabaseProvider.overrideWithValue(db),
            activeMetadataSourceProvider.overrideWithValue(_FakeSource()),
            importFilePickerProvider.overrideWithValue(
              () async => (name: 'tv-time-export.zip', bytes: export),
            ),
          ],
          child: const _AppUnderTest(),
        ),
      );

      // ---- leg 1: import ---------------------------------------------
      await _import($);

      expect(await _titles(db), {'Severance', 'Andor', 'Blade Runner 2049'});
      // Severance: S1E1–E2 from seen_episode_source + S1E3 from seen_episode_
      // latest (a delta, unioned — not a replacement). Blade Runner: one watch
      // plus one rewatch. Andor is followed but unwatched.
      expect(await _watchEvents(db), 5);

      await $(BackButton).tap();
      expect($('Severance').exists, isTrue);
      expect($('Andor').exists, isTrue);

      // ---- leg 2: bulk-mark ------------------------------------------
      await $('Severance').tap();
      // ponytail: "Mark show watched" over the per-season button — same
      // `bulkMarkWatched` call, no ExpansionTile to expand first.
      await $('Mark show watched').scrollTo().tap();
      // 9 episodes in the season, 3 already watched by the import. Bulk mark is
      // idempotent, so it adds the other 6 and re-marks nothing.
      expect($('Marked 6 episodes watched.').exists, isTrue);
      expect(await _watchEvents(db), 11);

      await $(BackButton).tap();

      // ---- leg 3: re-import the same file -----------------------------
      await _import($);

      expect(await _titles(db), {'Severance', 'Andor', 'Blade Runner 2049'});
      // Unchanged: no duplicate items, no duplicate watch events, no extra
      // rewatch row, and the six bulk-marked episodes survive.
      expect(await _watchEvents(db), 11);
      expect(await _rewatches(db), 1);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// `WatchnookApp` minus its theme: the same router, the same screens.
///
/// `WatchnookTheme` builds its text theme with `google_fonts`, and with
/// runtime fetching off (as `main()` sets it) and no bundled `.ttf`,
/// `loadFontIfNecessary` **rethrows** — asynchronously. The running app
/// swallows that and renders the platform font, which is the documented
/// intent; a test binding turns any unhandled async error into a failure. Text
/// is what this test reads, not typography, so it mounts Material's default
/// theme. #48 bundles the two families; this drops back to `WatchnookApp` then.
class _AppUnderTest extends ConsumerWidget {
  const _AppUnderTest();

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'Watchnook',
    debugShowCheckedModeBanner: false,
    routerConfig: ref.watch(appRouterProvider),
  );
}

/// App bar → Import → pick (stubbed) → wait for the summary.
Future<void> _import(PatrolIntegrationTester $) async {
  await $(Icons.file_upload_outlined).tap();
  await $('Choose file').tap();
  await $('Import complete').waitUntilVisible();
}

Future<Set<String>> _titles(AppDatabase db) async => {
  for (final item in await db.libraryDao.getAll()) item.title,
};

Future<int> _watchEvents(AppDatabase db) async => (await _events(db)).length;

Future<int> _rewatches(AppDatabase db) async =>
    (await _events(db)).where((e) => e.isRewatch).length;

Future<List<WatchEvent>> _events(AppDatabase db) async => [
  for (final item in await db.libraryDao.getAll())
    ...await db.libraryDao.watchEventsFor(item.id),
];

// ---------------------------------------------------------------------------
// The export. A hand-rolled miniature of `test/fixtures/tvtime/`, because a
// device test cannot read the repo's fixture files off the host — and the real
// ~300-row fixture is already exercised by the unit suite. Column names and the
// five-table shape match the real GDPR export exactly.
// ---------------------------------------------------------------------------

Uint8List _tvTimeExportZip() {
  final archive = Archive();
  _export.forEach(
    (name, content) => archive.add(ArchiveFile.string(name, content)),
  );
  return ZipEncoder().encodeBytes(archive);
}

/// `header` + one line per row, pulling each column by name so a 30-column TV
/// Time table can be written by naming the four fields that matter.
String _csv(List<String> header, List<Map<String, String>> rows) => [
  header.join(','),
  for (final row in rows) [for (final h in header) row[h] ?? ''].join(','),
].join('\n');

final _export = <String, String>{
  // `archived = 1` → the user finished it, so Andor lands as `completed`.
  'followed_tv_show.csv': _csv(
    const ['archived', 'user_id', 'tv_show_name', 'tv_show_id', 'active'],
    const [
      {
        'archived': '0',
        'user_id': '10000000',
        'tv_show_name': 'Severance',
        'tv_show_id': '371980',
        'active': '1',
      },
      {
        'archived': '1',
        'user_id': '10000000',
        'tv_show_name': 'Andor',
        'tv_show_id': '391153',
        'active': '1',
      },
    ],
  ),
  'user_tv_show_data.csv': _csv(
    const ['nb_episodes_seen', 'tv_show_name', 'tv_show_id', 'is_followed'],
    const [
      {
        'nb_episodes_seen': '3',
        'tv_show_name': 'Severance',
        'tv_show_id': '371980',
        'is_followed': '1',
      },
      {
        'nb_episodes_seen': '0',
        'tv_show_name': 'Andor',
        'tv_show_id': '391153',
        'is_followed': '1',
      },
    ],
  ),
  'seen_episode_source.csv': _csv(
    const [
      'episode_number',
      'created_at',
      'tv_show_name',
      'episode_season_number',
    ],
    const [
      {
        'episode_number': '1',
        'created_at': '2022-02-18 21:00:00',
        'tv_show_name': 'Severance',
        'episode_season_number': '1',
      },
      {
        'episode_number': '2',
        'created_at': '2022-02-25 21:00:00',
        'tv_show_name': 'Severance',
        'episode_season_number': '1',
      },
    ],
  ),
  // A delta on top of the table above, not a replacement — E3 only.
  'seen_episode_latest.csv': _csv(
    const [
      'created_at',
      'tv_show_name',
      'episode_season_number',
      'episode_number',
    ],
    const [
      {
        'created_at': '2022-03-04 21:00:00',
        'tv_show_name': 'Severance',
        'episode_season_number': '1',
        'episode_number': '3',
      },
    ],
  ),
  // One film, two rows keyed by the same uuid (a `follow` then a `watch`) —
  // collapsing on the uuid is what stops it becoming two library items.
  'tracking-prod-records.csv': _csv(
    const [
      'type',
      'uuid',
      'user_id',
      'entity_type',
      'movie_name',
      'release_date',
      'rewatch_count',
      'watch_date',
    ],
    const [
      {
        'type': 'follow',
        'uuid': 'a1b2c3d4-0000-0000-0000-000000000001',
        'user_id': '10000000',
        'entity_type': 'movie',
        'movie_name': 'Blade Runner 2049',
        'release_date': '2017-10-06 00:00:00',
      },
      {
        'type': 'watch',
        'uuid': 'a1b2c3d4-0000-0000-0000-000000000001',
        'user_id': '10000000',
        'entity_type': 'movie',
        'movie_name': 'Blade Runner 2049',
        'release_date': '2017-10-06 00:00:00',
        'rewatch_count': '1',
        'watch_date': '1546300800',
      },
    ],
  ),
};

// ---------------------------------------------------------------------------
// The backend. Titles resolve on the resolver's search rung (TV Time carries
// TheTVDB ids and TMDB is the active backend, so no id rung applies) — an exact
// title hit each, which is what makes every record auto-resolve and the
// confirmation queue stay empty. Posters are null: no image, no network.
// ---------------------------------------------------------------------------

const _severance = 95396;

const _catalogue = [
  MediaSearchResult(
    kind: MediaKind.tv,
    title: 'Severance',
    tmdbId: _severance,
    year: 2022,
  ),
  MediaSearchResult(
    kind: MediaKind.tv,
    title: 'Andor',
    tmdbId: 83867,
    year: 2022,
  ),
  MediaSearchResult(
    kind: MediaKind.movie,
    title: 'Blade Runner 2049',
    tmdbId: 335984,
    year: 2017,
  ),
];

const _severanceDetails = MediaDetails(
  kind: MediaKind.tv,
  title: 'Severance',
  genres: ['Drama'],
  seasons: [SeasonInfo(seasonNumber: 1, episodeCount: 9)],
  tmdbId: _severance,
  episodeCountTotal: 9,
);

/// Severance season 1, aired order.
const _severanceEpisodes = [
  EpisodeInfo(seasonNumber: 1, episodeNumber: 1, runtimeMinutes: 57),
  EpisodeInfo(seasonNumber: 1, episodeNumber: 2, runtimeMinutes: 45),
  EpisodeInfo(seasonNumber: 1, episodeNumber: 3, runtimeMinutes: 46),
  EpisodeInfo(seasonNumber: 1, episodeNumber: 4, runtimeMinutes: 40),
  EpisodeInfo(seasonNumber: 1, episodeNumber: 5, runtimeMinutes: 47),
  EpisodeInfo(seasonNumber: 1, episodeNumber: 6, runtimeMinutes: 51),
  EpisodeInfo(seasonNumber: 1, episodeNumber: 7, runtimeMinutes: 40),
  EpisodeInfo(seasonNumber: 1, episodeNumber: 8, runtimeMinutes: 49),
  EpisodeInfo(seasonNumber: 1, episodeNumber: 9, runtimeMinutes: 40),
];

class _FakeSource implements MetadataSource {
  /// Exactly one exact-title hit per query, which is the resolver's
  /// "confident" threshold. An unknown title returns nothing and would land in
  /// the confirmation queue — no record in this export does.
  @override
  Future<List<MediaSearchResult>> search(
    String query, {
    MediaKind? kind,
  }) async => [
    for (final hit in _catalogue)
      if (hit.title == query && (kind == null || hit.kind == kind)) hit,
  ];

  @override
  Future<MediaDetails> showDetails(int sourceId) async => _severanceDetails;

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(
    int showSourceId,
    int seasonNumber,
  ) async => [
    for (final e in _severanceEpisodes)
      if (e.seasonNumber == seasonNumber) e,
  ];

  @override
  Future<MediaDetails> movieDetails(int sourceId) async => const MediaDetails(
    kind: MediaKind.movie,
    title: 'Blade Runner 2049',
    genres: ['Science Fiction'],
    seasons: [],
    tmdbId: 335984,
    year: 2017,
    runtimeMinutes: 164,
  );

  @override
  Future<List<UpcomingEpisode>> upcomingForTracked(
    List<int> showSourceIds,
  ) async => [];

  @override
  Future<MediaSearchResult?> resolveByExternalId(String imdbId) async => null;

  @override
  String imageUrl(String path, ImageSize size) =>
      'https://example.invalid/$path';

  @override
  Attribution attribution() => const Attribution(
    notice: 'Fake source',
    linkUrl: 'https://example.invalid/',
  );
}
