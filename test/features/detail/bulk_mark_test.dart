import 'dart:convert';

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

  /// Seeds the show's `CachedMedia` row — the backend's own aired markers,
  /// which `hasAired` trusts over the date. Without this the show is cold and
  /// the date rule alone applies (itself a case worth testing).
  Future<void> cacheShowDetails({
    (int, int)? nextToAir,
    (int, int)? lastToAir,
    DateTime? nextAirDate,
  }) {
    final details = MediaDetails(
      kind: MediaKind.tv,
      title: 'Severance',
      genres: const [],
      seasons: const [],
      tmdbId: showId,
      nextEpisode: nextToAir == null
          ? null
          : EpisodeInfo(
              seasonNumber: nextToAir.$1,
              episodeNumber: nextToAir.$2,
              airDate: nextAirDate,
            ),
      lastEpisode: lastToAir == null
          ? null
          : EpisodeInfo(
              seasonNumber: lastToAir.$1,
              episodeNumber: lastToAir.$2,
            ),
    );
    return db.mediaCacheDao.upsertMedia(
      CachedMediaCompanion.insert(
        source: MetadataSourceKind.tmdb,
        mediaType: MediaType.tv,
        sourceId: showId,
        payload: jsonEncode(details.toJson()),
        fetchedAt: now,
        title: 'Severance',
      ),
    );
  }

  CachingMetadataRepository repoOver(_RecordingSource source) =>
      CachingMetadataRepository(
        source: source,
        sourceKind: MetadataSourceKind.tmdb,
        dao: db.mediaCacheDao,
        clock: Clock.fixed(now),
      );

  Future<BulkMarkResult> bulkResult(
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

  /// Returns the marked count — the existing tests assert on that. Use
  /// [bulkResult] when the skipped-unaired half matters.
  Future<int> bulk(
    _RecordingSource source,
    int itemId, {
    required List<int> seasons,
    (int, int)? upTo,
  }) async =>
      (await bulkResult(source, itemId, seasons: seasons, upTo: upTo)).marked;

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

  group("the backend's aired markers beat the date", () {
    // THE air-day bug. A date-only `air_date` parses to LOCAL MIDNIGHT, so a
    // naive `!airDate.isAfter(now)` calls tonight's episode "aired" from 00:00.
    // Catching up on the MORNING of air day would then silently mark an episode
    // that has not broadcast, park the pointer on the next-to-air coordinate,
    // and drop the show out of Up Next with that episode never offered again.
    // `next_episode_to_air` states the boundary exactly, with no clock to lose.
    test(
      'the episode airing TONIGHT is not marked on the morning of air day',
      () async {
        final id = await insertShow();
        // It is 09:00 on air day. E4 airs at 21:00 tonight; its date is today.
        final airDay = DateTime(2026, 7, 9, 9);
        await cacheSeason(1, [
          episode(1, 1),
          episode(1, 2),
          episode(1, 3),
          episode(1, 4, airDate: DateTime(2026, 7, 9)), // tonight
        ]);
        await cacheShowDetails(
          nextToAir: (1, 4), // the backend says E4 has NOT aired
          lastToAir: (1, 3),
          nextAirDate: DateTime(2026, 7, 9),
        );

        final result = await withClock(
          Clock.fixed(airDay),
          () => bulkMarkWatched(
            dao: db.libraryDao,
            repo: repoOver(_RecordingSource({})),
            itemId: id,
            showSourceId: showId,
            seasons: [1],
          ),
        );

        expect(result.marked, 3, reason: 'E1-E3 only — E4 has not broadcast');
        expect(await watched(id), {(1, 1), (1, 2), (1, 3)});
        expect(
          (await db.libraryDao.getItem(id))!.lastWatchedEpisode,
          3,
          reason:
              'the pointer must not land on the next-to-air coordinate, or '
              'the queue stops offering E4 forever',
        );
      },
    );

    // The other half: an episode that aired EARLIER today is genuinely watched
    // and must still be markable. A blanket "today is unaired" rule would break
    // this, so the coordinate check (not the date) has to be what excludes E4.
    test('an episode that aired earlier today IS marked', () async {
      final id = await insertShow();
      await cacheSeason(1, [episode(1, 1, airDate: DateTime(2026, 7, 9))]);
      await cacheShowDetails(nextToAir: (1, 2), lastToAir: (1, 1));

      final result = await withClock(
        Clock.fixed(DateTime(2026, 7, 9, 22)), // 22:00, it aired at 21:00
        () => bulkMarkWatched(
          dao: db.libraryDao,
          repo: repoOver(_RecordingSource({})),
          itemId: id,
          showSourceId: showId,
          seasons: [1],
        ),
      );

      expect(result.marked, 1);
      expect(await watched(id), {(1, 1)});
    });

    // A stubbed future season carries no next_episode_to_air, so lastEpisode is
    // the only marker that catches it — the same guard the queue uses.
    test('nothing after the last-aired episode is marked', () async {
      final id = await insertShow();
      await cacheSeason(1, [episode(1, 1), episode(1, 2)]);
      // S2 is stubbed with DATED episodes in the past (a backend data quirk) —
      // only lastEpisode says they have not really aired.
      await cacheSeason(2, [episode(2, 1), episode(2, 2)]);
      await cacheShowDetails(lastToAir: (1, 2));

      expect(await bulk(_RecordingSource({}), id, seasons: [1, 2]), 2);
      expect(await watched(id), {(1, 1), (1, 2)});
      expect((await db.libraryDao.getItem(id))!.lastWatchedSeason, 1);
    });
  });

  // The long-press "watch up to here" on the detail screen is enabled for EVERY
  // episode with seasonNumber > 0 — including unaired ones, whose row literally
  // renders a future air date. So `upTo` and `hasAired` compose in production,
  // and nothing pinned that. The aired filter must clamp the bound, not the
  // other way round.
  test(
    'an `upTo` aimed at an UNAIRED episode is clamped to what aired',
    () async {
      final id = await insertShow();
      await cacheSeason(1, [
        episode(1, 1),
        episode(1, 2),
        episode(1, 3),
        episode(1, 4, airDate: DateTime(2026, 7, 16)), // future
        episode(1, 5, airDate: DateTime(2026, 7, 23)), // future
      ]);
      await cacheShowDetails(nextToAir: (1, 4), lastToAir: (1, 3));

      // The user long-presses E5 — an episode that has not aired.
      final result = await bulkResult(
        _RecordingSource({}),
        id,
        seasons: [1],
        upTo: (1, 5),
      );

      expect(result.marked, 3, reason: 'clamped by hasAired, not by the bound');
      expect(result.airedCandidates, 3);
      expect(await watched(id), {(1, 1), (1, 2), (1, 3)});
      expect((await db.libraryDao.getItem(id))!.lastWatchedEpisode, 3);
    },
  );

  // The two zero cases. "Already watched." on a season reading 0/10 is a lie,
  // and it hides precisely the under-mark `hasAired` deliberately chooses — the
  // whole justification for which is that the user can SEE it.
  group('the two zeroes are distinguishable', () {
    test('nothing aired yet → airedCandidates == 0', () async {
      final id = await insertShow();
      await cacheSeason(1, [episode(1, 1, airDate: DateTime(2027))]);

      final result = await bulkResult(_RecordingSource({}), id, seasons: [1]);

      expect(result.marked, 0);
      expect(
        result.airedCandidates,
        0,
        reason:
            'the caller must not say '
            '"Already watched." to someone looking at 0/1 watched',
      );
    });

    test('genuinely already watched → airedCandidates > 0', () async {
      final id = await insertShow();
      await cacheSeason(1, [episode(1, 1), episode(1, 2)]);
      await bulk(_RecordingSource({}), id, seasons: [1]);

      final result = await bulkResult(_RecordingSource({}), id, seasons: [1]);

      expect(result.marked, 0);
      expect(result.airedCandidates, 2);
    });

    // Caught up on a currently-AIRING show: episodes are skipped as unaired AND
    // everything aired is already watched. Both at once. Keying the message off
    // "did we skip anything" would tell this user "Nothing has aired yet."
    // while they stare at two watched episodes. (Caught on-device against House
    // the Dragon: pointer S3E4, with S3E5-E8 stubbed and unaired.)
    test(
      'caught up on an airing show is "already watched", not "none aired"',
      () async {
        final id = await insertShow();
        await cacheSeason(1, [
          episode(1, 1),
          episode(1, 2),
          episode(1, 3, airDate: DateTime(2027)), // unaired
          episode(1, 4, airDate: DateTime(2027)), // unaired
        ]);
        await bulk(_RecordingSource({}), id, seasons: [1]); // marks E1-E2

        final result = await bulkResult(_RecordingSource({}), id, seasons: [1]);

        expect(result.marked, 0);
        expect(
          result.airedCandidates,
          2,
          reason: 'E1-E2 aired and are watched — NOT "nothing has aired"',
        );
      },
    );
  });

  group('hasAired', () {
    EpisodeInfo ep(int s, int e, {DateTime? airDate}) =>
        EpisodeInfo(seasonNumber: s, episodeNumber: e, airDate: airDate);

    test('with no cached details, falls back to the date', () {
      expect(hasAired(ep(1, 1, airDate: DateTime(2026)), null, now), isTrue);
      expect(
        hasAired(ep(1, 1, airDate: DateTime(2026, 7, 10)), null, now),
        isFalse,
      );
    });

    test('undated counts as NOT aired', () {
      expect(
        hasAired(ep(1, 1), null, now),
        isFalse,
        reason:
            'null is likelier an unscheduled stub than a lost date, and '
            'under-marking fails visibly where over-marking fails silently',
      );
    });

    test(
      'the next-to-air coordinate is unaired even when its date has "passed"',
      () {
        const details = MediaDetails(
          kind: MediaKind.tv,
          title: 'Severance',
          genres: [],
          seasons: [],
          nextEpisode: EpisodeInfo(seasonNumber: 1, episodeNumber: 4),
        );
        // Its date-only airDate is local midnight TODAY, i.e. already "past".
        expect(
          hasAired(ep(1, 4, airDate: DateTime(2026, 7, 9)), details, now),
          isFalse,
          reason:
              'the backend says it has not aired; the date must not override',
        );
        expect(
          hasAired(ep(1, 3, airDate: DateTime(2026, 7, 9)), details, now),
          isTrue,
        );
      },
    );
  });
}
