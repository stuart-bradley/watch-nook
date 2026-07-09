import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/detail/data/bulk_mark.dart';

/// #20 acceptance: **one action marks a whole season**, derived from
/// `CachedEpisodes` and fetching only the seasons that aren't cached.
///
/// Adversarial framing:
/// - The source **records every fetch**, so a bulk that re-fetches an already
///   cached season (or reaches for the specials) fails here.
/// - Specials are asserted absent from `WatchEvents`, not just from the fetch
///   list — a season-0 episode smuggled inside a real season's listing would
///   otherwise sail through.
/// - "Up to here" asserts the *later* episode stayed unwatched, which an
///   off-by-one inclusive bound (`>=` for `>`) breaks.
/// - Offline + cold cache asserts **zero** rows: a per-season write loop would
///   leave the first season marked and the rest not.

/// Serves only the seasons in [bySeason]; anything else is a 500 (offline).
class _RecordingSource implements MetadataSource {
  _RecordingSource(this.bySeason);

  final Map<int, List<EpisodeInfo>> bySeason;
  final fetched = <int>[];

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int showId, int season) async {
    fetched.add(season);
    final rows = bySeason[season];
    if (rows == null) throw const MetadataException(500, 'offline');
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final now = DateTime(2026, 7, 9);
  const showId = 95396;

  EpisodeInfo episode(int s, int e, {int? runtime}) =>
      EpisodeInfo(seasonNumber: s, episodeNumber: e, runtimeMinutes: runtime);

  Future<int> insertShow() => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.tv,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Severance',
      trackStatus: TrackStatus.watching,
      addedAt: now,
      updatedAt: now,
      tmdbId: const Value(showId),
    ),
  );

  /// Seeds a **fresh** cached season (fetchedAt == the fixed clock's now), so
  /// the repository serves it without touching the source.
  Future<void> cacheSeason(int season, List<EpisodeInfo> episodes) =>
      db.mediaCacheDao.replaceSeasonEpisodes(
        MetadataSourceKind.tmdb,
        showId,
        season,
        [
          for (final e in episodes)
            CachedEpisodesCompanion.insert(
              source: MetadataSourceKind.tmdb,
              showSourceId: showId,
              seasonNumber: e.seasonNumber,
              episodeNumber: e.episodeNumber,
              fetchedAt: now,
              runtimeMinutes: Value(e.runtimeMinutes),
            ),
        ],
      );

  CachingMetadataRepository repoOver(_RecordingSource source) =>
      CachingMetadataRepository(
        source: source,
        sourceKind: MetadataSourceKind.tmdb,
        dao: db.mediaCacheDao,
        clock: Clock.fixed(now),
      );

  Future<int> bulk(
    _RecordingSource source,
    int itemId, {
    required List<int> seasons,
    (int, int)? upTo,
  }) => withClock(
    Clock.fixed(now),
    () => bulkMarkWatched(
      dao: db.libraryDao,
      repo: repoOver(source),
      itemId: itemId,
      showSourceId: showId,
      seasons: seasons,
      upTo: upTo,
    ),
  );

  Future<Set<(int, int)>> watched(int itemId) async => {
    for (final r in await db.libraryDao.watchEventsFor(itemId))
      (r.seasonNumber!, r.episodeNumber!),
  };

  test('bulk from a partial cache marks the whole show, fetching only the '
      'uncached season, and never the specials', () async {
    final id = await insertShow();
    await cacheSeason(1, [episode(1, 1, runtime: 57), episode(1, 2)]);
    final source = _RecordingSource({
      0: [episode(0, 1)], // specials exist upstream — must never be fetched
      2: [episode(2, 1), episode(2, 2)],
    });

    expect(await bulk(source, id, seasons: [0, 1, 2]), 4);

    expect(source.fetched, [2]);
    expect(await watched(id), {(1, 1), (1, 2), (2, 1), (2, 2)});
    final item = (await db.libraryDao.getItem(id))!;
    expect(item.watchedCount, 4);
    expect(item.lastWatchedSeason, 2);
    expect(item.lastWatchedEpisode, 2);
    // Snapshotted from the cached episode row, not the show.
    final rows = await db.libraryDao.watchEventsFor(id);
    expect(
      rows
          .singleWhere((r) => r.seasonNumber == 1 && r.episodeNumber == 1)
          .runtimeMinutes,
      57,
    );

    // Re-running is a no-op: no new rows, and no new fetch.
    expect(await bulk(source, id, seasons: [0, 1, 2]), 0);
    expect(await db.libraryDao.watchEventsFor(id), hasLength(4));
    expect(source.fetched, [2]);
  });

  test(
    'a special listed inside a real season is dropped, not marked',
    () async {
      final id = await insertShow();
      // Some backends fold a special into a season's listing as seasonNumber 0.
      final source = _RecordingSource({
        1: [episode(1, 1), episode(0, 9)],
      });

      expect(await bulk(source, id, seasons: [1]), 1);
      expect(await watched(id), {(1, 1)});
    },
  );

  test(
    '"up to here" is inclusive, spans earlier seasons, and stops there',
    () async {
      final id = await insertShow();
      await cacheSeason(1, [episode(1, 1), episode(1, 2)]);
      await cacheSeason(2, [episode(2, 1), episode(2, 2)]);
      // Season 3 is deliberately uncached and unservable: a bound that leaks
      // past its season would try to resolve it and blow up.
      final source = _RecordingSource({});

      expect(await bulk(source, id, seasons: [1, 2, 3], upTo: (2, 1)), 3);

      expect(await watched(id), {(1, 1), (1, 2), (2, 1)});
      expect(source.fetched, isEmpty);
      final item = (await db.libraryDao.getItem(id))!;
      expect(item.lastWatchedSeason, 2);
      expect(item.lastWatchedEpisode, 1);
    },
  );

  test('offline with a cold cache throws and writes nothing at all', () async {
    final id = await insertShow();
    await cacheSeason(1, [episode(1, 1)]); // season 1 cached, season 2 is not
    final source = _RecordingSource({});

    await expectLater(
      bulk(source, id, seasons: [1, 2]),
      throwsA(isA<MetadataException>()),
    );

    // Season 1 resolved fine — a per-season write loop would have marked it.
    expect(await db.libraryDao.watchEventsFor(id), isEmpty);
    expect((await db.libraryDao.getItem(id))!.watchedCount, 0);
  });

  test('watchedAt is stamped from the injected clock', () async {
    final id = await insertShow();
    await cacheSeason(1, [episode(1, 1)]);
    await bulk(_RecordingSource({}), id, seasons: [1]);
    expect((await db.libraryDao.watchEventsFor(id)).single.watchedAt, now);
  });
}
