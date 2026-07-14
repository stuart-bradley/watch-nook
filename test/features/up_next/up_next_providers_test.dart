import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';

/// #21 — the Up Next **watch queue**. The core is [nextUnwatchedAired]: given a
/// progress pointer and a show's shape, what is the next episode to watch, and
/// has it aired? The regressions that matter are (a) surfacing an episode that
/// has NOT aired yet (a queue that lies), and (b) never advancing past a season
/// boundary (a queue that gets stuck).

MediaDetails _show({
  required List<(int season, int episodes)> seasons,
  (int, int)? nextToAir,
  (int, int)? lastToAir,
  DateTime? nextAirDate,
  String? nextTitle,
}) => MediaDetails(
  kind: MediaKind.tv,
  title: 'A Show',
  genres: const [],
  seasons: [
    for (final (n, c) in seasons) SeasonInfo(seasonNumber: n, episodeCount: c),
  ],
  nextEpisode: nextToAir == null
      ? null
      : EpisodeInfo(
          seasonNumber: nextToAir.$1,
          episodeNumber: nextToAir.$2,
          airDate: nextAirDate,
          title: nextTitle,
        ),
  lastEpisode: lastToAir == null
      ? null
      : EpisodeInfo(seasonNumber: lastToAir.$1, episodeNumber: lastToAir.$2),
);

LibraryItem _item({
  int id = 1,
  MediaType mediaType = MediaType.tv,
  MetadataSourceKind recordedSource = MetadataSourceKind.tmdb,
  TrackStatus trackStatus = TrackStatus.watching,
  String? showStatus,
  int? tmdbId = 100,
  int? tvdbId,
  int? lastSeason,
  int? lastEpisode,
}) => LibraryItem(
  id: id,
  mediaType: mediaType,
  recordedSource: recordedSource,
  title: 'Item $id',
  trackStatus: trackStatus,
  showStatus: showStatus,
  tmdbId: tmdbId,
  tvdbId: tvdbId,
  lastWatchedSeason: lastSeason,
  lastWatchedEpisode: lastEpisode,
  watchedCount: 0,
  addedAt: DateTime(2026),
  updatedAt: DateTime(2026),
  relinkFailed: false,
);

/// A repository fake: [cachedShowDetails] returns the seeded details for the
/// requested ids that it has. An id it lacks is simply omitted — the cold show
/// the queue must SKIP rather than crash the whole list on.
class _FakeRepo implements CachingMetadataRepository {
  _FakeRepo(this.byId);

  final Map<int, MediaDetails> byId;

  @override
  Future<Map<int, MediaDetails>> cachedShowDetails(
    Iterable<int> sourceIds,
  ) async => {for (final id in sourceIds) id: ?byId[id]};

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A container wiring the real library DAO (over an in-memory DB) and the fake
/// repo into the queue's providers, so `watchQueue` runs for real.
ProviderContainer _containerOver(AppDatabase db, _FakeRepo repo) =>
    ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
        metadataRepositoryProvider.overrideWithValue(repo),
      ],
    );

Future<int> _seed(
  AppDatabase db, {
  required String title,
  required int tmdbId,
  int? lastSeason,
  int? lastEpisode,
}) => db.libraryDao.insertItem(
  LibraryItemsCompanion.insert(
    mediaType: MediaType.tv,
    recordedSource: MetadataSourceKind.tmdb,
    title: title,
    trackStatus: TrackStatus.watching,
    addedAt: DateTime(2026),
    updatedAt: DateTime(2026),
    tmdbId: Value(tmdbId),
    lastWatchedSeason: Value(lastSeason),
    lastWatchedEpisode: Value(lastEpisode),
  ),
);

void main() {
  group('nextUnwatchedAired', () {
    test('nothing watched → the first aired episode', () {
      // S1 has 10 eps; next-to-air is S1E5, so E1–4 have aired.
      final next = nextUnwatchedAired(
        null,
        null,
        _show(seasons: [(1, 10)], nextToAir: (1, 5)),
      );
      expect(next, (1, 1));
    });

    test('after the last watched, same season', () {
      final next = nextUnwatchedAired(
        1,
        3,
        _show(seasons: [(1, 10)], nextToAir: (1, 5)),
      );
      expect(next, (1, 4));
    });

    test('the next episode has not aired yet → caught up (null)', () {
      // Watched up to E4; the next-to-air is E5, so E5 itself is unaired.
      final next = nextUnwatchedAired(
        1,
        4,
        _show(seasons: [(1, 10)], nextToAir: (1, 5)),
      );
      expect(next, isNull, reason: 'a queue must never surface an unaired ep');
    });

    test('rolls over to the next season when a season is finished', () {
      // Watched S1E8 (last of S1); S2 has aired episodes (next-to-air S2E4).
      final next = nextUnwatchedAired(
        1,
        8,
        _show(seasons: [(1, 8), (2, 8)], nextToAir: (2, 4)),
      );
      expect(next, (2, 1));
    });

    test('caught up on a returning show awaiting an undated next season', () {
      // Shōgun-shape: watched all of S1; S2 announced with 0 episodes so far.
      final next = nextUnwatchedAired(
        1,
        10,
        _show(seasons: [(1, 10), (2, 0)]),
      );
      expect(next, isNull);
    });

    test('does not surface a stubbed-but-unaired next season (bug-2)', () {
      // Returning show: watched all of S1; S2 already exists in `seasons` with
      // episodes but has NOT aired (no next-to-air). last-aired is still S1's
      // finale, so S2E1 hasn't aired and must not be offered — a tick on it
      // would corrupt the progress pointer.
      final next = nextUnwatchedAired(
        1,
        10,
        _show(seasons: [(1, 10), (2, 8)], lastToAir: (1, 10)),
      );
      expect(next, isNull, reason: 'S2E1 is stubbed but unaired');
    });

    test('surfaces an aired next season even with no next-to-air', () {
      // S2 has fully aired (last_episode_to_air is in S2) with a gap before S3,
      // so next_episode_to_air is null — the aired S2E1 must still surface. The
      // bug-2 guard must not over-suppress this.
      final next = nextUnwatchedAired(
        1,
        10,
        _show(seasons: [(1, 10), (2, 8)], lastToAir: (2, 8)),
      );
      expect(next, (2, 1));
    });

    test('caught up when the finished season is the last that exists', () {
      final next = nextUnwatchedAired(1, 10, _show(seasons: [(1, 10)]));
      expect(next, isNull);
    });

    test('a null next-to-air treats existing episodes as aired', () {
      // Ended show, watched S1E5 of 10; the rest aired long ago.
      final next = nextUnwatchedAired(1, 5, _show(seasons: [(1, 10)]));
      expect(next, (1, 6));
    });

    test('specials (season 0) are excluded from the ordering', () {
      // Nothing watched → S1E1, never S0E1.
      final next = nextUnwatchedAired(
        null,
        null,
        _show(seasons: [(0, 3), (1, 10)]),
      );
      expect(next, (1, 1));
    });

    test('a show with no real seasons yields nothing', () {
      expect(nextUnwatchedAired(null, null, _show(seasons: [(0, 5)])), isNull);
    });
  });

  group('showsForQueue', () {
    List<LibraryItem> filter(List<LibraryItem> items) =>
        showsForQueue(items, MetadataSourceKind.tmdb);

    test('keeps a watching TV show recorded against the active backend', () {
      expect(filter([_item()]), hasLength(1));
    });

    test('drops movies, dropped, and watchlist', () {
      expect(filter([_item(mediaType: MediaType.movie)]), isEmpty);
      expect(filter([_item(trackStatus: TrackStatus.dropped)]), isEmpty);
      expect(filter([_item(trackStatus: TrackStatus.watchlist)]), isEmpty);
    });

    test(
      'drops a completed show that has ended, keeps one still returning',
      () {
        expect(
          filter([
            _item(trackStatus: TrackStatus.completed, showStatus: 'Ended'),
          ]),
          isEmpty,
        );
        expect(
          filter([
            _item(
              trackStatus: TrackStatus.completed,
              showStatus: 'Returning Series',
            ),
          ]),
          hasLength(1),
          reason: 'a returning show may have a new aired season to watch',
        );
      },
    );

    test('keeps on-hold shows', () {
      expect(filter([_item(trackStatus: TrackStatus.onHold)]), hasLength(1));
    });

    test('drops a row recorded against the other backend', () {
      expect(
        filter([_item(recordedSource: MetadataSourceKind.tvdb)]),
        isEmpty,
      );
    });
  });

  group('episodeLabel', () {
    test('adds the title when there is one', () {
      expect(episodeLabel(2, 5, 'The Reckoning'), 'S2E5 · The Reckoning');
    });

    test('falls back to the coordinate alone', () {
      expect(episodeLabel(2, 5), 'S2E5');
      expect(episodeLabel(2, 5, ''), 'S2E5');
    });
  });

  // The watch-queue rewrite is the highest-risk surface here, but every widget
  // test overrides upNextBoardProvider with a static board — so the
  // orchestration (skip a cold show, sort) never actually runs. This drives it
  // for real. (Live re-advance on a tick is verified on-device and guaranteed
  // by `ref.watch(libraryItemsProvider)`; it's left to the widget layer.)
  group('upNextBoard (provider orchestration)', () {
    test('skips a show absent from cache and title-sorts the rest', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _seed(db, title: 'Zeta', tmdbId: 1, lastSeason: 1, lastEpisode: 1);
      await _seed(db, title: 'Alpha', tmdbId: 2, lastSeason: 1, lastEpisode: 1);
      await _seed(
        db,
        title: 'Cold',
        tmdbId: 3,
        lastSeason: 1,
        lastEpisode: 1,
      );
      final repo = _FakeRepo({
        1: _show(seasons: [(1, 10)]),
        2: _show(seasons: [(1, 10)]),
        // tmdbId 3 absent from cache → omitted from the batch → skipped.
      });
      final container = _containerOver(db, repo);
      addTearDown(container.dispose);
      // upNextBoard is autoDispose: hold a listener so reading `.future`
      // doesn't
      // tear it (and its library-stream dependency) down mid-load.
      addTearDown(container.listen(upNextBoardProvider, (_, _) {}).close);

      final board = await container.read(upNextBoardProvider.future);
      expect(
        board.queue.map((e) => e.showTitle),
        ['Alpha', 'Zeta'],
        reason: 'the cold show is skipped (not fatal); the rest are sorted',
      );
      expect(board.queue.every((e) => e.season == 1 && e.episode == 2), isTrue);
    });

    // Upcoming sorts by DATE, the queue by TITLE. A copy-paste of the queue's
    // comparator would pass every single-show test and silently mis-order the
    // one list whose whole purpose is chronology.
    test('sorts upcoming by air date, not by title', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _seed(db, title: 'Alpha', tmdbId: 1);
      await _seed(db, title: 'Zeta', tmdbId: 2);
      final repo = _FakeRepo({
        // Alphabetically first, but airs LAST.
        1: _show(
          seasons: [(1, 10)],
          nextToAir: (1, 1),
          nextAirDate: DateTime(2026, 7, 20),
        ),
        2: _show(
          seasons: [(1, 10)],
          nextToAir: (1, 1),
          nextAirDate: DateTime(2026, 7, 16),
        ),
      });
      final container = _containerOver(db, repo);
      addTearDown(container.dispose);
      addTearDown(container.listen(upNextBoardProvider, (_, _) {}).close);

      final board = await withClock(
        Clock.fixed(DateTime(2026, 7, 14)),
        () => container.read(upNextBoardProvider.future),
      );
      expect(board.upcoming.map((e) => e.showTitle), ['Zeta', 'Alpha']);
    });

    // The deliberate duplicate. You are behind on a show (S1E2 aired,
    // unwatched) AND its next episode is scheduled. Both facts are true and
    // both useful; "deduplicating" would hide "new episode Friday" for exactly
    // the shows you watch most. If someone ever makes upcoming an `else` of the
    // queue, this test is what stops them.
    test('a show behind AND scheduled appears in BOTH lists', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _seed(
        db,
        title: 'The Bear',
        tmdbId: 1,
        lastSeason: 1,
        lastEpisode: 1,
      );
      final repo = _FakeRepo({
        // Watched S1E1. S1E4 is next-to-air, so S1E2 and S1E3 have aired.
        1: _show(
          seasons: [(1, 10)],
          nextToAir: (1, 4),
          nextAirDate: DateTime(2026, 7, 17),
        ),
      });
      final container = _containerOver(db, repo);
      addTearDown(container.dispose);
      addTearDown(container.listen(upNextBoardProvider, (_, _) {}).close);

      final board = await withClock(
        Clock.fixed(DateTime(2026, 7, 14)),
        () => container.read(upNextBoardProvider.future),
      );
      expect(board.queue.single.showTitle, 'The Bear');
      expect(board.queue.single.episode, 2, reason: 'the aired backlog');
      expect(board.upcoming.single.showTitle, 'The Bear');
      expect(board.upcoming.single.episode, 4, reason: 'the scheduled one');
    });

    // Both lists run through `showsForQueue`. A scheduled episode is tempting
    // to show for ANY show with a date — but a dropped show is one you walked
    // away from, and a watchlist show is one you never started. Neither is
    // something you are waiting for. This pins that Upcoming did not quietly
    // grow its own looser filter.
    test('a dropped show is in neither list, however imminent', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.libraryDao.insertItem(
        LibraryItemsCompanion.insert(
          mediaType: MediaType.tv,
          recordedSource: MetadataSourceKind.tmdb,
          title: 'Abandoned',
          trackStatus: TrackStatus.dropped,
          addedAt: DateTime(2026),
          updatedAt: DateTime(2026),
          tmdbId: const Value(1),
        ),
      );
      final repo = _FakeRepo({
        1: _show(
          seasons: [(1, 10)],
          nextToAir: (1, 1),
          nextAirDate: DateTime(2026, 7, 15),
        ),
      });
      final container = _containerOver(db, repo);
      addTearDown(container.dispose);
      addTearDown(container.listen(upNextBoardProvider, (_, _) {}).close);

      final board = await withClock(
        Clock.fixed(DateTime(2026, 7, 14)),
        () => container.read(upNextBoardProvider.future),
      );
      expect(board.queue, isEmpty);
      expect(board.upcoming, isEmpty);
    });
  });

  group('upcomingFor', () {
    final now = DateTime(2026, 7, 14);
    final item = _item();

    UpcomingEntry? upcoming(MediaDetails details) =>
        upcomingFor(item, details, now);

    MediaDetails scheduled(DateTime? airDate, {String? title}) => _show(
      seasons: [(1, 10)],
      nextToAir: (2, 1),
      nextAirDate: airDate,
      nextTitle: title,
    );

    test('a dated, future next episode becomes a row', () {
      final entry = upcoming(
        scheduled(DateTime(2026, 7, 17), title: 'Cold Harbor'),
      );
      expect(entry, isNotNull);
      expect(entry!.season, 2);
      expect(entry.episode, 1);
      expect(entry.episodeTitle, 'Cold Harbor');
      expect(entry.airDate, DateTime(2026, 7, 17));
      expect(entry.itemId, item.id);
    });

    // The most urgent row on the page. An off-by-one in the lower bound (`> 0`
    // instead of `>= 0`) drops today's episode — the one the user most wants.
    test('an episode airing TODAY is included', () {
      expect(upcoming(scheduled(now)), isNotNull);
    });

    // The sync is daily, so a cached `nextEpisode` can have aired since. An
    // aired episode must never sit in Upcoming — it belongs in the queue, and
    // the next sync moves it there.
    test('a stale cache whose episode already aired is excluded', () {
      expect(upcoming(scheduled(DateTime(2026, 7, 13))), isNull);
      expect(upcoming(scheduled(DateTime(2026, 6))), isNull);
    });

    test('an ended show (no next episode) is excluded', () {
      expect(upcoming(_show(seasons: [(1, 10)])), isNull);
    });

    test('a scheduled but UNDATED (TBA) episode is excluded', () {
      expect(
        upcoming(scheduled(null)),
        isNull,
        reason: 'an undated row cannot be sorted or labelled',
      );
    });

    group('the 6-month horizon', () {
      test('inside the horizon is kept, beyond it is dropped', () {
        expect(upcoming(scheduled(DateTime(2026, 12, 14))), isNotNull);
        expect(upcoming(scheduled(DateTime(2027, 1, 14))), isNotNull);
        expect(
          upcoming(scheduled(DateTime(2027, 2, 14))),
          isNull,
          reason: '7 months out is noise',
        );
      });

      // `month + 6` from October is month 16. If that were clamped or wrapped
      // by hand rather than left to DateTime's own normalisation, the horizon
      // would land in the wrong year and admit (or drop) a whole season.
      test('crosses a year boundary correctly', () {
        final october = DateTime(2026, 10, 14);
        expect(
          upcomingFor(item, scheduled(DateTime(2027, 3, 14)), october),
          isNotNull,
          reason: 'Oct + 6 months = April NEXT year, so March is inside',
        );
        expect(
          upcomingFor(item, scheduled(DateTime(2027, 5, 14)), october),
          isNull,
        );
      });
    });
  });

  group('daysUntil', () {
    test('counts whole calendar days, ignoring the time of day', () {
      // 23:00 today → 01:00 tomorrow is 2 hours, but it is still ONE day.
      expect(
        daysUntil(DateTime(2026, 7, 14, 23), DateTime(2026, 7, 15, 1)),
        1,
      );
      expect(daysUntil(DateTime(2026, 7, 14), DateTime(2026, 7, 14)), 0);
      expect(daysUntil(DateTime(2026, 7, 14), DateTime(2026, 7, 13)), -1);
    });

    // The exact bug `_streakDays` (stats_snapshot.dart) documents: across a DST
    // transition a local "day" is 23 or 25 hours, so `difference().inDays` on
    // raw instants rounds a day away. In the UK, 29 Mar 2026 is the spring
    // forward — the 28th→29th "day" is 23 hours and would floor to 0.
    test('is exact across a DST transition', () {
      expect(
        daysUntil(DateTime(2026, 3, 28), DateTime(2026, 3, 29)),
        1,
        reason: 'a 23-hour day is still one day',
      );
      expect(
        daysUntil(DateTime(2026, 10, 24), DateTime(2026, 10, 25)),
        1,
        reason: 'a 25-hour day is still one day',
      );
      expect(daysUntil(DateTime(2026, 3, 25), DateTime(2026, 4)), 7);
    });
  });

  group('isThisWeek', () {
    test('today through day 6, and no further', () {
      expect(isThisWeek(0), isTrue);
      expect(isThisWeek(6), isTrue);
      expect(isThisWeek(7), isFalse, reason: 'day 7 belongs to Later');
      expect(isThisWeek(-1), isFalse);
    });
  });

  group('airLabel', () {
    // 14 Jul 2026 is a Tuesday.
    final now = DateTime(2026, 7, 14);

    test('names the near days', () {
      expect(airLabel(DateTime(2026, 7, 14), now), 'Today');
      expect(airLabel(DateTime(2026, 7, 15), now), 'Tomorrow');
      expect(airLabel(DateTime(2026, 7, 17), now), 'Friday');
      expect(airLabel(DateTime(2026, 7, 20), now), 'Monday');
    });

    test('falls back to a date past the week', () {
      expect(airLabel(DateTime(2026, 7, 21), now), '21 Jul');
      expect(airLabel(DateTime(2026, 12, 3), now), '3 Dec');
    });

    test('adds the year only when it differs', () {
      expect(airLabel(DateTime(2027, 3, 12), now), '12 Mar 2027');
      expect(airLabel(DateTime(2026, 9), now), '1 Sep');
    });
  });
}
