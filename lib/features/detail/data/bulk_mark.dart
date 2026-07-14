import 'package:clock/clock.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart'
    show airsBefore;

/// The outcome of a bulk mark.
///
/// `marked` is what was newly written. A zero has **two** causes and the caller
/// must tell them apart, which is what `airedCandidates` is for — the number of
/// episodes that had aired and were therefore eligible, watched already or not:
///
/// - `marked == 0 && airedCandidates == 0` → nothing has aired yet. Telling
///   this user "already watched" — while the season bar they just tapped reads
///   "0/10 watched" — is a flat lie, and it hides the very under-mark [hasAired]
///   deliberately chooses (whose whole justification is that it is *visible*).
/// - `marked == 0 && airedCandidates > 0` → genuinely already watched.
///
/// It must be `airedCandidates`, NOT "how many did we skip": a show you are
/// caught up on with unaired episodes ahead skips several AND is already
/// watched. Both are true at once.
typedef BulkMarkResult = ({int marked, int airedCandidates});

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
/// here" — and never touches a later episode. An `upTo` aimed at an episode
/// that has NOT aired (the detail screen lets you long-press one) is clamped by
/// [hasAired], not by the bound.
///
/// Throws if a needed season is neither cached nor fetchable (offline, cold
/// cache) — callers surface that; nothing is written.
Future<BulkMarkResult> bulkMarkWatched({
  required LibraryDao dao,
  required CachingMetadataRepository repo,
  required int itemId,
  required int showSourceId,
  required Iterable<int> seasons,
  (int, int)? upTo,
}) async {
  final now = clock.now();
  // The show's own next-/last-to-air markers — the SAME authority the watch
  // queue uses (`nextUnwatchedAired`). Cache-only, so this never fetches and
  // never throws; a cold show yields null and [hasAired] falls back to dates.
  final details = (await repo.cachedShowDetails([showSourceId]))[showSourceId];

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
      if (!hasAired(e, details, now)) continue;
      marks.add((
        season: e.seasonNumber,
        episode: e.episodeNumber,
        runtimeMinutes: e.runtimeMinutes,
      ));
    }
  }
  final marked = await dao.markManyWatched(itemId, marks, watchedAt: now);
  return (marked: marked, airedCandidates: marks.length);
}

/// Has [e] aired by [now]? Bulk-mark's eligibility rule — and deliberately the
/// **same** rule the watch queue applies in `nextUnwatchedAired`, so the two
/// can never disagree about which episode you are allowed to be on.
///
/// [details] is the show's cached `MediaDetails` (null when the show is cold in
/// the cache).
///
/// **The backend's own markers win over the date**, and that is the crux. A
/// date-only `air_date` parses to *local midnight*, so a naive
/// `!airDate.isAfter(now)` calls tonight's episode "aired" from 00:00 on air
/// day — and it is worse across timezones, where a US Sunday-21:00 broadcast is
/// "aired" to a UK viewer for most of a day. Bulk-marking on the morning of air
/// day would then silently mark an episode that has not broadcast, park the
/// progress pointer on the next-to-air coordinate, and drop the show out of Up
/// Next with that episode never offered again: the precise corruption this
/// filter exists to prevent. `next_episode_to_air` states the boundary exactly,
/// with no timezone to get wrong.
///
/// An **undated** episode counts as NOT aired. That is deliberate too:
///
/// - A backend leaves `airDate` null mostly on *unscheduled future* episodes (a
///   stubbed next season, a TBA finale); an aired episode almost always carries
///   a date. So null is far likelier to mean "not yet" than "we lost the date".
/// - The two failure modes are not symmetric. **Over-marking is silent and
///   corrupting** — the progress pointer jumps past reality and the show drops
///   out of Up Next with nothing to tell the user why. **Under-marking is
///   visible and cheap** — the season simply reads "9/10 watched" and one tap
///   fixes it. When the data is ambiguous, fail the way the user can see.
bool hasAired(EpisodeInfo e, MediaDetails? details, DateTime now) {
  final coord = (e.seasonNumber, e.episodeNumber);

  // Everything at or after the next-to-air episode is unaired, whatever its
  // date says. This is what stops a mark on the morning of air day.
  final next = details?.nextEpisode;
  if (next != null &&
      !airsBefore(coord, (next.seasonNumber, next.episodeNumber))) {
    return false;
  }
  // ...and nothing strictly after the last aired episode has aired. Guards a
  // stubbed future season, which carries no next_episode_to_air. (TVDB never
  // populates lastEpisode, so there this is a no-op and the date rule carries.)
  final last = details?.lastEpisode;
  if (last != null &&
      airsBefore((last.seasonNumber, last.episodeNumber), coord)) {
    return false;
  }

  // Date rule — the only signal for a cold show, or one whose backend gives no
  // markers. Undated is unaired.
  final airDate = e.airDate;
  return airDate != null && !airDate.isAfter(now);
}
