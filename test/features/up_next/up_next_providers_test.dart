import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
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
}
