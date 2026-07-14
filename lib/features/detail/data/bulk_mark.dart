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
/// **Only episodes that have AIRED are marked** — see [hasAired]. A currently
/// airing season is cached whole (future episodes included, with their dates),
/// so without this a "mark season watched" on an airing show would mark
/// episodes that do not exist yet: `lastWatchedSeason`/`lastWatchedEpisode`
/// would jump past reality, `watchedCount` would inflate, and the show would
/// silently vanish from the Up Next queue (which reads that pointer) with the
/// genuinely-next episode never offered.
///
/// [upTo] is an inclusive aired-order `(season, episode)` bound — "watch up to
/// here" — and never touches a later episode. Returns the number of episodes
/// newly marked (0 when they were all already watched, or none have aired).
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
  final now = clock.now();
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
      if (!hasAired(e.airDate, now)) continue;
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
  return dao.markManyWatched(itemId, marks, watchedAt: now);
}

/// Has this episode aired by [now]? Bulk-mark's eligibility rule.
///
/// An **undated** episode counts as NOT aired. That is deliberate, and it is
/// the interesting half of the rule:
///
/// - A backend leaves `airDate` null mostly on *unscheduled future* episodes (a
///   stubbed next season, a TBA finale); an aired episode almost always carries
///   a date. So null is far likelier to mean "not yet" than "we lost the date".
/// - The two failure modes are not symmetric. **Over-marking is silent and
///   corrupting** — the progress pointer jumps past reality and the show drops
///   out of Up Next with nothing to tell the user why. **Under-marking is
///   visible and cheap** — the season simply reads "9/10 watched" and one tap
///   fixes it. When the data is ambiguous, fail the way the user can see.
///
/// Date-only air dates parse to local midnight, so an episode airing *today* is
/// aired (its midnight is not after `now`).
bool hasAired(DateTime? airDate, DateTime now) =>
    airDate != null && !airDate.isAfter(now);
