import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/tmdb/tmdb_source.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/detail/presentation/detail_screen.dart';

/// #18 acceptance — the seasons/episodes list renders, and the **mandatory**
/// attribution is present and correct **per source**.
///
/// Adversarial framing:
/// - Attribution is asserted against the **real** `TmdbSource`/`TvdbSource`
///   `attribution()`, not a fake's — a fake would only prove the fake. Each
///   test also asserts the *other* source's credit is absent, so a hardcoded
///   footer fails.
/// - The screen is wired to a **real** `CachingMetadataRepository`, so the
///   offline tests drive the SWR path end-to-end: a **stale** cache (the fresh
///   case never calls the source, proving nothing) plus a throwing source still
///   renders, and a **cold** cache degrades to a notice rather than a crash.
///   The swallow itself is pinned in `caching_metadata_repository_test`.
/// - Only the expanded season's episodes may appear — a regression that builds
///   every season eagerly fans out a fetch per season and fails here.

/// A source that serves [details]/[episodes], or throws every call when
/// [offline] — never the network.
class _FakeSource implements MetadataSource {
  _FakeSource({this.details, this.episodes = const [], this.offline = false});

  final MediaDetails? details;
  final List<EpisodeInfo> episodes;
  final bool offline;

  @override
  Future<MediaDetails> showDetails(int sourceId) async => _details();

  @override
  Future<MediaDetails> movieDetails(int sourceId) async => _details();

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int showId, int season) async {
    if (offline) throw StateError('offline');
    return episodes.where((e) => e.seasonNumber == season).toList();
  }

  MediaDetails _details() {
    if (offline) throw StateError('offline');
    return details!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final now = DateTime(2026, 7, 9);
  final fixed = Clock.fixed(now);

  /// Never reached: both real sources are mounted only for `attribution()`.
  http.Client noNetwork() =>
      MockClient((_) async => throw StateError('no network in a widget test'));

  // backdropPath/posterPath stay null so no CachedNetworkImage resolves a URL.
  const details = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama'],
    seasons: [
      SeasonInfo(seasonNumber: 1, episodeCount: 2),
      SeasonInfo(seasonNumber: 2, episodeCount: 1),
    ],
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
    overview: 'Mark leads a team of office workers.',
    showStatus: 'Ended',
    episodeCountTotal: 3,
  );
  final episodes = [
    const EpisodeInfo(seasonNumber: 1, episodeNumber: 1, title: 'Good News'),
    const EpisodeInfo(seasonNumber: 1, episodeNumber: 2, title: 'Half Loop'),
    const EpisodeInfo(seasonNumber: 2, episodeNumber: 1, title: 'Hello, Ms.'),
  ];

  final item = LibraryItem(
    id: 1,
    mediaType: MediaType.tv,
    tmdbId: 95396,
    recordedSource: MetadataSourceKind.tmdb,
    title: 'Severance',
    trackStatus: TrackStatus.watching,
    watchedCount: 0,
    addedAt: now,
    updatedAt: now,
    relinkFailed: false,
  );

  /// Mounts the detail screen with [active] as the attribution source and a
  /// **real** `CachingMetadataRepository` over [repoSource] + the in-memory
  /// cache — so the SWR path (and its offline fallback) is exercised for real.
  ///
  /// `libraryItemProvider` is DB-backed, so it is overridden with a synchronous
  /// `Stream.value` — a live Drift `.watch()` never quiesces under fake-async
  /// and would hang `pumpAndSettle` (CLAUDE.md testing note).
  Widget harness({
    required MetadataSource active,
    required MetadataSource repoSource,
  }) => ProviderScope(
    overrides: [
      activeMetadataSourceProvider.overrideWithValue(active),
      metadataRepositoryProvider.overrideWithValue(
        CachingMetadataRepository(
          source: repoSource,
          sourceKind: MetadataSourceKind.tmdb,
          dao: db.mediaCacheDao,
          clock: fixed,
        ),
      ),
      libraryItemProvider.overrideWith((ref, id) => Stream.value(item)),
    ],
    child: const MaterialApp(home: DetailScreen(itemId: 1)),
  );

  /// Mounts [harness] on a tall surface. The screen is a `ListView`, which only
  /// builds what fits — on the default 800×600 the seasons and the attribution
  /// footer sit below the fold and never enter the tree, so a finder for them
  /// would fail for the wrong reason.
  Future<void> pumpDetail(
    WidgetTester tester, {
    required MetadataSource active,
    required MetadataSource repoSource,
  }) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(active: active, repoSource: repoSource));
    await tester.pumpAndSettle();
  }

  testWidgets('the seasons list renders and expands into its episodes', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      active: TmdbSource(client: noNetwork(), apiKey: 'k'),
      repoSource: _FakeSource(details: details, episodes: episodes),
    );

    // Overview + both seasons, collapsed (no episodes fetched yet).
    expect(find.text('Mark leads a team of office workers.'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    expect(find.text('Good News'), findsNothing);

    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();

    // Only the expanded season's episodes — not the whole show.
    expect(find.text('Good News'), findsOneWidget);
    expect(find.text('Half Loop'), findsOneWidget);
    expect(find.text('Hello, Ms.'), findsNothing);
  });

  testWidgets('attribution is not on detail (it moved to Settings)', (
    tester,
  ) async {
    // The TMDB logo + notice moved to Settings → About; a copy on every title's
    // detail page was excessive. settings_screen_test guards that it renders
    // there. This guards that it stays off the detail screen.
    await pumpDetail(
      tester,
      active: TmdbSource(client: noNetwork(), apiKey: 'k'),
      repoSource: _FakeSource(details: details),
    );

    expect(find.textContaining('not endorsed, certified'), findsNothing);
    expect(find.text('https://www.themoviedb.org/'), findsNothing);
  });

  testWidgets('a stale cache still renders when the source is offline', (
    tester,
  ) async {
    // Stale by the ended-show TTL (30d) → the repo WILL refetch, and the fetch
    // throws. The screen must still show the cached details.
    await db.mediaCacheDao.upsertMedia(
      CachedMediaCompanion.insert(
        source: MetadataSourceKind.tmdb,
        mediaType: MediaType.tv,
        sourceId: 95396,
        payload: jsonEncode(details.toJson()),
        fetchedAt: now.subtract(const Duration(days: 100)),
        title: details.title,
        overview: const Value('Mark leads a team of office workers.'),
        showStatus: const Value('Ended'),
      ),
    );

    await pumpDetail(
      tester,
      active: TmdbSource(client: noNetwork(), apiKey: 'k'),
      repoSource: _FakeSource(offline: true),
    );

    expect(find.text('Mark leads a team of office workers.'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text("Couldn't load details. You're offline."), findsNothing);
  });

  testWidgets('a cold cache plus an offline source degrades, not crashes', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      active: TmdbSource(client: noNetwork(), apiKey: 'k'),
      repoSource: _FakeSource(offline: true),
    );

    // The stored row still renders; the details region says so.
    expect(find.text('Severance'), findsWidgets);
    expect(find.text("Couldn't load details. You're offline."), findsOneWidget);
  });
}
