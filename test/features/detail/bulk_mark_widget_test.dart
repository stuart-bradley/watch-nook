import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/detail/presentation/detail_screen.dart';

/// #20 from the UI in: the bulk buttons must write through the DAO's bulk path
/// against a **real** in-memory DB. Assertions are on `WatchEvents`, so a
/// button wired to a stub (or to a per-episode loop that skips the idempotent
/// path) fails here. The watched-state stream is stubbed, so nothing repaints —
/// the DB is the check.

class _FakeSource implements MetadataSource {
  _FakeSource(this.details, this.episodes);

  final MediaDetails details;
  final List<EpisodeInfo> episodes;

  @override
  Future<MediaDetails> showDetails(int sourceId) async => details;

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int showId, int season) async =>
      episodes.where((e) => e.seasonNumber == season).toList();

  @override
  Attribution attribution() =>
      const Attribution(notice: 'Fake', linkUrl: 'https://example.org/');

  @override
  String imageUrl(String path, ImageSize size) => 'https://example.org/$path';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final now = DateTime(2026, 7, 9);

  const details = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama'],
    seasons: [
      SeasonInfo(seasonNumber: 0, episodeCount: 1, name: 'Specials'),
      SeasonInfo(seasonNumber: 1, episodeCount: 2),
      SeasonInfo(seasonNumber: 2, episodeCount: 2),
    ],
    tmdbId: 95396,
    episodeCountTotal: 4,
  );
  const episodes = [
    EpisodeInfo(seasonNumber: 0, episodeNumber: 1),
    EpisodeInfo(seasonNumber: 1, episodeNumber: 1, runtimeMinutes: 57),
    EpisodeInfo(seasonNumber: 1, episodeNumber: 2),
    EpisodeInfo(seasonNumber: 2, episodeNumber: 1),
    EpisodeInfo(seasonNumber: 2, episodeNumber: 2),
  ];

  Future<int> insertShow() => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.tv,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Severance',
      trackStatus: TrackStatus.watching,
      addedAt: now,
      updatedAt: now,
      tmdbId: const Value(95396),
    ),
  );

  Future<void> pumpDetail(
    WidgetTester tester,
    int itemId, {
    Set<(int, int)> alreadyWatched = const {},
  }) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final item = (await db.libraryDao.getItem(itemId))!;
    final source = _FakeSource(details, episodes);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataSourceProvider.overrideWithValue(source),
          metadataRepositoryProvider.overrideWithValue(
            CachingMetadataRepository(
              source: source,
              sourceKind: MetadataSourceKind.tmdb,
              dao: db.mediaCacheDao,
            ),
          ),
          libraryItemProvider.overrideWith((ref, id) => Stream.value(item)),
          watchedEpisodesProvider.overrideWith(
            (ref, id) => Stream.value(alreadyWatched),
          ),
        ],
        child: MaterialApp(home: DetailScreen(itemId: itemId)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<Set<(int, int)>> watched(int itemId) async => {
    for (final r in await db.libraryDao.watchEventsFor(itemId))
      (r.seasonNumber!, r.episodeNumber!),
  };

  /// The bulk control on one season's **bar**. Scoped to the named tile, so a
  /// test can't accidentally hit a different season's button.
  Finder seasonButton(String name) => find.descendant(
    of: find.widgetWithText(ExpansionTile, name),
    matching: find.byTooltip('Mark season watched'),
  );

  /// A season bar's progress caption, scoped to its own tile.
  Finder seasonSays(String name, String caption) => find.descendant(
    of: find.widgetWithText(ExpansionTile, name),
    matching: find.text(caption),
  );

  testWidgets('"Mark show watched" marks every season but the specials', (
    tester,
  ) async {
    final id = await insertShow();
    await pumpDetail(tester, id);

    await tester.tap(find.text('Mark show watched'));
    await tester.pumpAndSettle();

    expect(await watched(id), {(1, 1), (1, 2), (2, 1), (2, 2)});
    expect((await db.libraryDao.getItem(id))!.watchedCount, 4);
    expect(find.text('Marked 4 episodes watched.'), findsOneWidget);

    // Let the snack bar expire, or the next one just queues behind it.
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Re-running is idempotent all the way through the widget.
    await tester.tap(find.text('Mark show watched'));
    await tester.pumpAndSettle();
    expect(await db.libraryDao.watchEventsFor(id), hasLength(4));
    expect(find.text('Already watched.'), findsOneWidget);
  });

  testWidgets('"Mark show watched" sits above the seasons, not above all', (
    tester,
  ) async {
    // It used to sit directly under the status control, at the top of the
    // screen, where it read as *the* thing you do with a title — drowning out
    // the category control next to it. It belongs to the seasons list below it.
    final id = await insertShow();
    await pumpDetail(tester, id);

    final button = tester.getTopLeft(find.text('Mark show watched')).dy;
    expect(
      button,
      greaterThan(tester.getTopLeft(find.byType(DropdownMenu<TrackStatus>)).dy),
    );
    expect(
      button,
      lessThan(tester.getTopLeft(find.byType(ExpansionTile).first).dy),
    );
  });

  testWidgets('a season is marked from its bar, without expanding it', (
    tester,
  ) async {
    // The point of the control: marking season 2 must not mean expanding
    // season 2 first. A test that expanded would keep passing with the button
    // buried inside the tile, so this one never expands anything.
    final id = await insertShow();
    await pumpDetail(tester, id);

    expect(find.text('Episode 1'), findsNothing); // nothing is expanded

    await tester.tap(seasonButton('Season 2'));
    await tester.pumpAndSettle();

    expect(await watched(id), {(2, 1), (2, 2)}); // season 1 untouched
    expect(find.text('Episode 1'), findsNothing); // and still nothing expanded
  });

  testWidgets('a season bar marks only its own season, with runtimes', (
    tester,
  ) async {
    final id = await insertShow();
    await pumpDetail(tester, id);

    await tester.tap(seasonButton('Season 1'));
    await tester.pumpAndSettle();

    expect(await watched(id), {(1, 1), (1, 2)});
    // Runtime snapshotted per episode at mark-time.
    final rows = await db.libraryDao.watchEventsFor(id);
    expect(rows.singleWhere((r) => r.episodeNumber == 1).runtimeMinutes, 57);
  });

  testWidgets('the specials season offers no bulk button', (tester) async {
    final id = await insertShow();
    await pumpDetail(tester, id);

    expect(seasonButton('Specials'), findsNothing);
    // Two real seasons, two buttons — and none on the specials.
    expect(find.byTooltip('Mark season watched'), findsNWidgets(2));
  });

  testWidgets('each season bar shows its own watched progress', (tester) async {
    // Adversarial: a filter that counts every watched episode into every season
    // (or forgets to filter at all) reads "1/2 watched" on both.
    final id = await insertShow();
    await pumpDetail(tester, id, alreadyWatched: const {(1, 1)});

    expect(seasonSays('Season 1', '1/2 watched'), findsOneWidget);
    expect(seasonSays('Season 2', '0/2 watched'), findsOneWidget);
  });

  testWidgets('a fully-watched season says so and disables its button', (
    tester,
  ) async {
    final id = await insertShow();
    await pumpDetail(tester, id, alreadyWatched: const {(1, 1), (1, 2)});

    expect(seasonSays('Season 1', '2/2 watched'), findsOneWidget);

    // It re-reads as a state, not an invitation: marking is idempotent, but a
    // live button says "maybe there's something left" when there isn't.
    final tile = find.widgetWithText(ExpansionTile, 'Season 1');
    expect(
      find.descendant(of: tile, matching: find.byTooltip('Season watched')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(
            find.descendant(of: tile, matching: find.byType(IconButton)),
          )
          .onPressed,
      isNull,
    );

    // Season 2 is untouched and still actionable.
    expect(seasonButton('Season 2'), findsOneWidget);
  });

  testWidgets('long-pressing an episode watches up to it, inclusive', (
    tester,
  ) async {
    final id = await insertShow();
    await pumpDetail(tester, id);

    await tester.tap(find.text('Season 2'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Episode 1'));
    await tester.pumpAndSettle();

    // S1 (an earlier season) is included; S2E2 (later) is not.
    expect(await watched(id), {(1, 1), (1, 2), (2, 1)});
    final item = (await db.libraryDao.getItem(id))!;
    expect(item.lastWatchedSeason, 2);
    expect(item.lastWatchedEpisode, 1);
  });
}
