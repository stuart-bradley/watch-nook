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
}) => MediaDetails(
  kind: MediaKind.tv,
  title: 'A Show',
  genres: const [],
  seasons: [
    for (final (n, c) in seasons) SeasonInfo(seasonNumber: n, episodeCount: c),
  ],
  nextEpisode: nextToAir == null
      ? null
      : EpisodeInfo(seasonNumber: nextToAir.$1, episodeNumber: nextToAir.$2),
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
  // test overrides watchQueueProvider with a static list — so the orchestration
  // (skip a cold show, sort) never actually runs. This drives it for real.
  // (Live re-advance on a tick is verified on-device and guaranteed by
  // `ref.watch(libraryItemsProvider)`; it's left to the widget layer.)
  group('watchQueue (provider orchestration)', () {
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
      // watchQueue is autoDispose: hold a listener so reading `.future` doesn't
      // tear it (and its library-stream dependency) down mid-load.
      addTearDown(container.listen(watchQueueProvider, (_, _) {}).close);

      final queue = await container.read(watchQueueProvider.future);
      expect(
        queue.map((e) => e.showTitle),
        ['Alpha', 'Zeta'],
        reason: 'the cold show is skipped (not fatal); the rest are sorted',
      );
      expect(queue.every((e) => e.season == 1 && e.episode == 2), isTrue);
    });
  });
}
