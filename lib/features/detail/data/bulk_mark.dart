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
    // `.first`, not `.last`: take the cache-first emission and don't block the
    // write on a network revalidation. A whole-show mark walks every season, so
    // waiting for each season's refetch made the mark appear to "do nothing
    // until you reload" (the write was stuck behind N round-trips, or aborted
    // offline). Cold seasons still fetch here; a warmed show marks instantly.
    final episodes = await repo.seasonEpisodes(showSourceId, season).first;
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
