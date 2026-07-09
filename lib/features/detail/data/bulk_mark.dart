import 'package:clock/clock.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';

/// **Bulk mark** (#20, US-3) — mark a season, a whole show, or everything up to
/// one episode, in a single action.
///
/// The episode set is derived from the cache (`CachedEpisodes`) via the
/// cache-first [CachingMetadataRepository]; a season that isn't cached is
/// fetched, so a partly-cached show still marks whole. The write is one
/// transaction with one denormalized recompute ([LibraryDao.markManyWatched])
/// and is idempotent — re-running marks nothing.
///
/// **Specials (season 0) are excluded by default** and there is no opt-in: they
/// aren't part of aired-order progress, so counting them would push
/// `watchedCount` past `episodeCountTotal`.
///
/// [upTo] is an inclusive aired-order `(season, episode)` bound — "watch up to
/// here" — and never touches a later episode. Returns the number of episodes
/// newly marked (0 when they were all already watched).
///
/// Throws if a needed season is neither cached nor fetchable (offline, cold
/// cache) — callers surface that; nothing is written.
Future<int> bulkMarkWatched({
  required LibraryDao dao,
  required CachingMetadataRepository repo,
  required int itemId,
  required int showSourceId,
  required Iterable<int> seasons,
  (int, int)? upTo,
}) async {
  final wanted =
      seasons
          .where((s) => s > 0 && (upTo == null || s <= upTo.$1))
          .toSet()
          .toList()
        ..sort();

  final marks = <EpisodeMark>[];
  for (final season in wanted) {
    // `.last` = the cache when it's fresh, the refetch when it isn't. It emits
    // at least once or throws, so it never hangs on an empty stream.
    final episodes = await repo.seasonEpisodes(showSourceId, season).last;
    for (final e in episodes) {
      if (e.seasonNumber <= 0) continue; // a special listed under a real season
      if (upTo != null &&
          e.seasonNumber == upTo.$1 &&
          e.episodeNumber > upTo.$2) {
        continue;
      }
      marks.add((
        season: e.seasonNumber,
        episode: e.episodeNumber,
        runtimeMinutes: e.runtimeMinutes,
      ));
    }
  }
  return dao.markManyWatched(itemId, marks, watchedAt: clock.now());
}
