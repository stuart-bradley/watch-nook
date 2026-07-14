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

/// Sentinel so `episode(..., airDate: null)` means "undated", distinct from
/// "caller said nothing, use the aired default".
const _defaultAirDate = Object();

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
/// - **Unaired episodes are never marked** — a season is cached whole, future
///   episodes included, so marking an *airing* season used to push the progress
///   pointer past reality and silently drop the show out of the Up Next queue.

/// Serves only the seasons in [bySeason]; anything else throws [onMissing]
/// (a 500/offline by default; pass a 404 to stand in for a non-transient error).
class _RecordingSource implements MetadataSource {
  _RecordingSource(
    this.bySeason, {
    this.onMissing = const MetadataException(500, 'offline'),
  });

  final Map<int, List<EpisodeInfo>> bySeason;
  final MetadataException onMissing;
  final fetched = <int>[];

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int showId, int season) async {
    fetched.add(season);
    final rows = bySeason[season];
    if (rows == null) throw onMissing;
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

  /// Comfortably before [now] — the default, so an episode is "aired" unless a
  /// test deliberately says otherwise.
  final aired = DateTime(2026);

  /// [airDate] defaults to [aired]. Pass `airDate: null` explicitly for an
  /// undated (TBA) episode, or a future date for one that has not aired.
  EpisodeInfo episode(
    int s,
    int e, {
    int? runtime,
    Object? airDate = _defaultAirDate,
  }) => EpisodeInfo(
    seasonNumber: s,
    episodeNumber: e,
    runtimeMinutes: runtime,
    airDate: identical(airDate, _defaultAirDate) ? aired : airDate as DateTime?,
  );

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

  /// Seeds a cached season. [fetchedAt] defaults to the fixed clock's now (a
  /// **fresh** cache the repository serves without touching the source); pass
  /// an older time to seed a **stale** one that would revalidate.
  Future<void> cacheSeason(
    int season,
    List<EpisodeInfo> episodes, {
    DateTime? fetchedAt,
  }) => db.mediaCacheDao.replaceSeasonEpisodes(
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
          fetchedAt: fetchedAt ?? now,
          runtimeMinutes: Value(e.runtimeMinutes),
          // The cached path must carry the air date too — bulk-mark's
          // eligibility rule reads it, and a companion that dropped it would
          // make every cached episode look undated (and so unaired).
          airDate: Value(e.airDate),
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

  test('a stale cached season still marks from cache (uses .first)', () async {
    // Regression guard for "does nothing until reload": a stale cache must mark
    // from its cache-first emission, not abort on the revalidation. With a
    // non-transient (404) upstream error the SWR stream errors *after* the
    // cache emission — `.last` would rethrow and mark nothing; `.first` marks
    // from cache and completes.
    final id = await insertShow();
    await cacheSeason(
      1,
      [episode(1, 1), episode(1, 2)],
      fetchedAt: DateTime(2026, 6), // stale: > 12h before the clock's now
    );
    final source = _RecordingSource(
      const {},
      onMissing: const MetadataException(404, 'gone'),
    );

    expect(await bulk(source, id, seasons: [1]), 2);
    expect(await watched(id), {(1, 1), (1, 2)});
  });

  test('watchedAt is stamped from the injected clock', () async {
    final id = await insertShow();
    await cacheSeason(1, [episode(1, 1)]);
    await bulk(_RecordingSource({}), id, seasons: [1]);
    expect((await db.libraryDao.watchEventsFor(id)).single.watchedAt, now);
  });

  group('unaired episodes are never marked', () {
    // THE bug. A season is cached whole — future episodes included, with their
    // dates — so "mark season watched" on a currently AIRING season used to
    // mark episodes that do not exist yet. The damage is silent: the progress
    // pointer jumps to the last *stubbed* episode, watchedCount inflates past
    // what aired, and the Up Next queue (which reads that pointer) drops the
    // show entirely, never offering the genuinely-next episode.
    test('an airing season marks only what has aired', () async {
      final id = await insertShow();
      await cacheSeason(1, [
        episode(1, 1),
        episode(1, 2),
        episode(1, 3, airDate: now), // airs TODAY → aired
        episode(1, 4, airDate: DateTime(2026, 7, 16)), // next week
        episode(1, 5, airDate: DateTime(2026, 7, 23)),
      ]);

      expect(await bulk(_RecordingSource({}), id, seasons: [1]), 3);

      expect(await watched(id), {(1, 1), (1, 2), (1, 3)});
      final item = (await db.libraryDao.getItem(id))!;
      expect(item.watchedCount, 3, reason: 'not the 5 episodes in the season');
      expect(
        (item.lastWatchedSeason, item.lastWatchedEpisode),
        (1, 3),
        reason:
            'the pointer lands on the last AIRED episode, not the last one '
            'that exists — Up Next reads this and must still offer S1E4',
      );
    });

    // An episode airing today is watchable today. A `.isBefore(now)` bound (or
    // a strict `>`) would drop the single most likely episode to be marked.
    test('an episode airing TODAY is marked', () async {
      final id = await insertShow();
      await cacheSeason(1, [episode(1, 1, airDate: now)]);
      expect(await bulk(_RecordingSource({}), id, seasons: [1]), 1);
      expect(await watched(id), {(1, 1)});
    });

    // Undated is treated as unaired — the deliberate, documented call (see
    // `hasAired`). Under-marking is visible and one tap to fix; over-marking is
    // silent and corrupts the pointer.
    test('an undated (TBA) episode is not marked', () async {
      final id = await insertShow();
      await cacheSeason(1, [episode(1, 1), episode(1, 2, airDate: null)]);

      expect(await bulk(_RecordingSource({}), id, seasons: [1]), 1);
      expect(await watched(id), {(1, 1)});
      expect((await db.libraryDao.getItem(id))!.lastWatchedEpisode, 1);
    });

    // "Mark show watched" walks every season, including a next season TMDB has
    // stubbed but not aired. It must contribute nothing — and crucially must
    // not drag the pointer into that season.
    test('a stubbed, wholly unaired next season contributes nothing', () async {
      final id = await insertShow();
      await cacheSeason(1, [episode(1, 1), episode(1, 2)]);
      await cacheSeason(2, [
        episode(2, 1, airDate: DateTime(2027)),
        episode(2, 2, airDate: null),
      ]);

      expect(await bulk(_RecordingSource({}), id, seasons: [1, 2]), 2);

      expect(await watched(id), {(1, 1), (1, 2)});
      final item = (await db.libraryDao.getItem(id))!;
      expect(
        (item.lastWatchedSeason, item.lastWatchedEpisode),
        (1, 2),
        reason: 'the pointer must not enter an unaired season',
      );
    });

    test(
      'a season with nothing aired yet marks nothing and writes no rows',
      () async {
        final id = await insertShow();
        await cacheSeason(1, [episode(1, 1, airDate: DateTime(2027))]);

        expect(await bulk(_RecordingSource({}), id, seasons: [1]), 0);
        expect(await db.libraryDao.watchEventsFor(id), isEmpty);
        expect((await db.libraryDao.getItem(id))!.watchedCount, 0);
      },
    );
  });

  group('hasAired', () {
    test('a past date has aired; today has aired; the future has not', () {
      expect(hasAired(DateTime(2026), now), isTrue);
      expect(hasAired(now, now), isTrue, reason: 'airing today is watchable');
      expect(hasAired(DateTime(2026, 7, 10), now), isFalse);
    });

    test('undated counts as NOT aired', () {
      expect(
        hasAired(null, now),
        isFalse,
        reason:
            'null is likelier an unscheduled stub than a lost date, and '
            'under-marking fails visibly where over-marking fails silently',
      );
    });
  });
}
