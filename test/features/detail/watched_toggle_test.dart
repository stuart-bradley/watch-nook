import 'dart:async';

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

/// #19 acceptance, from the UI in: tapping an episode toggle (or the movie
/// button) must produce exactly the `WatchEvents` rows the watched invariant
/// prescribes. The DAO owns the semantics — these tests prove the screen is
/// actually wired to it, against a **real** in-memory DB.
///
/// Adversarial framing:
/// - Assertions are on the *database*, not on the icon. A toggle wired to a
///   local `setState` would repaint and still fail here.
/// - The double-tap goes through the real widget twice, so a screen that calls
///   an insert directly (bypassing the idempotent DAO path) duplicates the row.
/// - Unwatching an episode with rewatches must clear all of them.

/// Serves fixed details/episodes; never the network.
class _FakeSource implements MetadataSource {
  _FakeSource({required this.details, this.episodes = const []});

  final MediaDetails details;
  final List<EpisodeInfo> episodes;

  @override
  Future<MediaDetails> showDetails(int sourceId) async => details;

  @override
  Future<MediaDetails> movieDetails(int sourceId) async => details;

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

  const showDetails = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama'],
    seasons: [SeasonInfo(seasonNumber: 1, episodeCount: 2)],
    tmdbId: 95396,
    episodeCountTotal: 2,
  );
  const movieDetails = MediaDetails(
    kind: MediaKind.movie,
    title: 'Dune',
    genres: ['Sci-Fi'],
    seasons: [],
    tmdbId: 438631,
    runtimeMinutes: 155,
  );
  const episodes = [
    EpisodeInfo(
      seasonNumber: 1,
      episodeNumber: 1,
      title: 'Good News',
      runtimeMinutes: 57,
    ),
    EpisodeInfo(seasonNumber: 1, episodeNumber: 2, title: 'Half Loop'),
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

  Future<int> insertMovie() => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.movie,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Dune',
      trackStatus: TrackStatus.completed,
      addedAt: now,
      updatedAt: now,
      tmdbId: const Value(438631),
      runtimeMinutes: const Value(155),
    ),
  );

  /// Mounts the detail screen over the real in-memory DB.
  ///
  /// The two DB-backed streams are overridden with synchronous `Stream.value`
  /// snapshots — a live Drift `.watch()` never quiesces under fake-async and
  /// would hang `pumpAndSettle` (CLAUDE.md testing note). So the screen doesn't
  /// repaint after a write; the assertions read the DB instead, which is the
  /// stronger check anyway.
  Future<void> pumpDetail(
    WidgetTester tester, {
    required int itemId,
    required MediaDetails details,
    Set<(int, int)> watched = const {},
  }) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final item = (await db.libraryDao.getItem(itemId))!;
    final source = _FakeSource(details: details, episodes: episodes);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataSourceProvider.overrideWithValue(source),
          // Overridden directly: the real one watches remote config for the
          // backend, which a widget test has no business booting.
          metadataRepositoryProvider.overrideWithValue(
            CachingMetadataRepository(
              source: source,
              sourceKind: MetadataSourceKind.tmdb,
              dao: db.mediaCacheDao,
            ),
          ),
          libraryItemProvider.overrideWith((ref, id) => Stream.value(item)),
          watchedEpisodesProvider.overrideWith(
            (ref, id) => Stream.value(watched),
          ),
        ],
        child: MaterialApp(home: DetailScreen(itemId: itemId)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expandSeason1(WidgetTester tester) async {
    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
  }

  testWidgets('tapping an episode toggle marks it watched, once', (
    tester,
  ) async {
    final id = await insertShow();
    await pumpDetail(tester, itemId: id, details: showDetails);
    await expandSeason1(tester);

    final toggle = find.byTooltip('Mark watched').first;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    // The state stream is stubbed, so the row still reads "unwatched" — tap it
    // again. A non-idempotent write path duplicates the marker here.
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final rows = await db.libraryDao.watchEventsFor(id);
    expect(rows, hasLength(1));
    expect(rows.single.seasonNumber, 1);
    expect(rows.single.episodeNumber, 1);
    expect(rows.single.isRewatch, isFalse);
    // Snapshotted from the episode, not the show.
    expect(rows.single.runtimeMinutes, 57);
    expect((await db.libraryDao.getItem(id))!.watchedCount, 1);
  });

  testWidgets('a watched episode toggles back off, clearing its rewatches', (
    tester,
  ) async {
    final id = await insertShow();
    await db.libraryDao.markWatched(id, season: 1, episode: 1);
    await db.libraryDao.logRewatch(id, season: 1, episode: 1);
    // E2 stays watched throughout — unwatching E1 must not touch it.
    await db.libraryDao.markWatched(id, season: 1, episode: 2);

    await pumpDetail(
      tester,
      itemId: id,
      details: showDetails,
      watched: {(1, 1), (1, 2)},
    );
    await expandSeason1(tester);

    await tester.tap(find.byTooltip('Mark unwatched').first);
    await tester.pumpAndSettle();

    final rows = await db.libraryDao.watchEventsFor(id);
    expect(rows, hasLength(1));
    expect(rows.single.episodeNumber, 2);
    expect((await db.libraryDao.getItem(id))!.watchedCount, 1);
  });

  testWidgets('a movie marks watched once, snapshotting its runtime', (
    tester,
  ) async {
    final id = await insertMovie();
    await pumpDetail(tester, itemId: id, details: movieDetails);

    expect(find.text('Log rewatch'), findsNothing); // nothing to rewatch yet
    await tester.tap(find.text('Mark watched'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark watched')); // the row is stubbed unwatched
    await tester.pumpAndSettle();

    final rows = await db.libraryDao.watchEventsFor(id);
    expect(rows, hasLength(1)); // null coords still dedupe (IS NULL)
    expect(rows.single.seasonNumber, isNull);
    expect(rows.single.runtimeMinutes, 155);
    expect((await db.libraryDao.getItem(id))!.watchedCount, 1);
  });

  testWidgets('a watched movie logs a rewatch without becoming twice-watched', (
    tester,
  ) async {
    final id = await insertMovie();
    await db.libraryDao.markWatched(id, watchedAt: DateTime(2020));
    await pumpDetail(tester, itemId: id, details: movieDetails);

    expect(find.text('Watched'), findsOneWidget);
    await tester.tap(find.text('Log rewatch'));
    await tester.pumpAndSettle();

    final rows = await db.libraryDao.watchEventsFor(id);
    expect(rows, hasLength(2));
    expect(rows.where((e) => e.isRewatch), hasLength(1));
    // The first watch's date survives, and a rewatch is not a second watch.
    expect(rows.where((e) => !e.isRewatch).single.watchedAt, DateTime(2020));
    expect((await db.libraryDao.getItem(id))!.watchedCount, 1);
  });

  testWidgets('a movie shows no episode toggle and no seasons', (tester) async {
    final id = await insertMovie();
    await pumpDetail(tester, itemId: id, details: movieDetails);

    expect(find.text('Season 1'), findsNothing);
    expect(find.byTooltip('Mark watched'), findsNothing); // no icon toggle
    expect(find.text('Mark watched'), findsOneWidget); // the movie button
  });

  testWidgets('the status chip moves the show to On hold, then Dropped', (
    tester,
  ) async {
    // The bug: On hold / Dropped (indeed every status) were unreachable — the
    // detail screen had no status control at all. The chip label reads the
    // stubbed row (always 'Watching'), so the assertions read the DB instead.
    final id = await insertShow(); // seeded as TrackStatus.watching
    await pumpDetail(tester, itemId: id, details: showDetails);

    // Only the status chip carries the exact text 'Watching' (the header
    // caption is a single joined string), so this taps the chip, not it.
    await tester.tap(find.text('Watching'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On hold'));
    await tester.pumpAndSettle();
    expect((await db.libraryDao.getItem(id))!.trackStatus, TrackStatus.onHold);

    // Row stream is stubbed at 'watching', so the chip still reads Watching;
    // re-open and pick Dropped — proving each status is reachable.
    await tester.tap(find.text('Watching'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dropped'));
    await tester.pumpAndSettle();
    expect((await db.libraryDao.getItem(id))!.trackStatus, TrackStatus.dropped);
  });

  testWidgets('a status change repaints the header from the live row', (
    tester,
  ) async {
    // The stronger half of the status test: not just the DB write, but that
    // the header the user sees actually updates. A controllable stream stands
    // in for the live `watchItem` (a real Drift `.watch()` never quiesces under
    // fake-async and hangs `pumpAndSettle` — CLAUDE.md), so re-emitting the
    // persisted row proves the header is bound to the stream, not a snapshot.
    final id = await insertShow(); // TrackStatus.watching
    final rows = StreamController<LibraryItem?>();
    addTearDown(rows.close);
    rows.add(await db.libraryDao.getItem(id));

    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final source = _FakeSource(details: showDetails, episodes: episodes);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db), // so updateStatus persists
          activeMetadataSourceProvider.overrideWithValue(source),
          metadataRepositoryProvider.overrideWithValue(
            CachingMetadataRepository(
              source: source,
              sourceKind: MetadataSourceKind.tmdb,
              dao: db.mediaCacheDao,
            ),
          ),
          libraryItemProvider.overrideWith((ref, i) => rows.stream),
          watchedEpisodesProvider.overrideWith(
            (ref, i) => Stream.value(const <(int, int)>{}),
          ),
        ],
        child: MaterialApp(home: DetailScreen(itemId: id)),
      ),
    );
    await tester.pumpAndSettle();

    // The caption starts on "Watching".
    expect(find.textContaining('· Watching'), findsOneWidget);

    await tester.tap(find.text('Watching')); // the status chip
    await tester.pumpAndSettle();
    await tester.tap(find.text('On hold'));
    await tester.pumpAndSettle();

    // The write persisted...
    final updated = (await db.libraryDao.getItem(id))!;
    expect(updated.trackStatus, TrackStatus.onHold);
    // ...and the header is bound to the row stream: it still reads "Watching"
    // until the (stubbed live) stream re-emits the persisted row.
    expect(find.textContaining('· Watching'), findsOneWidget);
    rows.add(updated);
    await tester.pumpAndSettle();
    expect(find.textContaining('· On hold'), findsOneWidget);
    expect(find.textContaining('· Watching'), findsNothing);
  });
}
