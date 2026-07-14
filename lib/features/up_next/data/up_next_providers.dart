import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/library_item_ids.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

part 'up_next_providers.g.dart';

/// One row of the Up Next **watch queue** (#21): the next episode to watch for
/// a tracked show. `itemId` is the `LibraryItems` row id, so a tap can push
/// `/title/:id` and the tick can mark exactly this coordinate watched.
typedef QueueEntry = ({
  int itemId,
  String showTitle,
  String? posterPath,
  int season,
  int episode,
});

/// One row of the **Upcoming** list (R4/US-5): a tracked show's next episode,
/// scheduled but not yet aired. Unlike a [QueueEntry] it carries an
/// `episodeTitle` (the backend supplies one for a scheduled episode) and the
/// `airDate` that sorts and labels it.
///
/// It deliberately has no "mark watched" affordance anywhere it is rendered —
/// ticking an unaired episode would push the progress pointer past reality.
typedef UpcomingEntry = ({
  int itemId,
  String showTitle,
  String? posterPath,
  int season,
  int episode,
  String? episodeTitle,
  DateTime airDate,
});

/// Everything the Up Next page renders, from **one** batched cache read.
///
/// A show can legitimately appear in BOTH lists: you are behind on it (an aired
/// backlog sits in `queue`) *and* its next episode is scheduled (`upcoming`).
/// Both facts are true and both are useful — deduplicating would hide "new
/// episode Friday" for exactly the shows you watch most.
///
/// `now` is the instant the board was computed, and the screen **must** group
/// and label from it rather than calling `clock.now()` again at build time. The
/// two are not the same clock read: a rebuild that does not re-run the provider
/// (the tab left open across midnight) would otherwise group against a *newer*
/// today than the one that filtered `upcoming` — landing an episode that aired
/// today under "Later", dated in the past. Stale-but-consistent beats
/// fresh-but-contradictory; the board recomputes on the next library write.
typedef UpNextBoard = ({
  List<QueueEntry> queue,
  List<UpcomingEntry> upcoming,
  DateTime now,
});

/// Which tracked shows can contribute to the watch queue.
///
/// - **TV only**, recorded against the active [backend] (so its id column
///   holds the right catalogue's id).
/// - **Skip `dropped`** (walked away) and **`watchlist`** (never started — the
///   queue is "continue watching", not "start watching").
/// - **Skip `completed` shows that have ended** — nothing left to watch. A
///   `completed` *returning* show stays: it may have a new aired season.
List<LibraryItem> showsForQueue(
  List<LibraryItem> items,
  MetadataSourceKind backend,
) => [
  for (final item in items)
    if (item.mediaType == MediaType.tv &&
        item.recordedSource == backend &&
        item.trackStatus != TrackStatus.dropped &&
        item.trackStatus != TrackStatus.watchlist &&
        !(item.trackStatus == TrackStatus.completed &&
            showHasEnded(item.showStatus)))
      item,
];

/// The next episode to watch after the `(lastSeason, lastEpisode)` progress
/// pointer, **if it has already aired** — the heart of the watch queue.
///
/// "Next" is strictly the episode after the last-watched one (the user's chosen
/// rule): mid-season skips are ignored. Season 0 (specials) is dropped from
/// ordering. Returns null when the show is caught up — nothing exists after the
/// pointer, or the candidate has not aired: it is at/after the next-to-air
/// (`details.nextEpisode`), or strictly after the last aired episode
/// (`details.lastEpisode`, which guards a stubbed-but-unaired next season).
(int season, int episode)? nextUnwatchedAired(
  int? lastSeason,
  int? lastEpisode,
  MediaDetails details,
) {
  final seasons =
      details.seasons
          .where((s) => s.seasonNumber > 0 && s.episodeCount > 0)
          .toList()
        ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
  if (seasons.isEmpty) return null;

  final (int, int) candidate;
  if (lastSeason == null || lastEpisode == null) {
    // Nothing watched yet → the very first episode.
    candidate = (seasons.first.seasonNumber, 1);
  } else {
    final current = _seasonNumbered(seasons, lastSeason);
    if (current != null && lastEpisode < current.episodeCount) {
      candidate = (lastSeason, lastEpisode + 1);
    } else {
      // At (or past) the end of that season → roll to the next season's E1.
      final next = _firstSeasonAfter(seasons, lastSeason);
      if (next == null) return null; // watched the last episode that exists
      candidate = (next.seasonNumber, 1);
    }
  }

  // Aired? Everything strictly before the next-to-air episode has aired.
  final nextAir = details.nextEpisode;
  if (nextAir != null &&
      !airsBefore(candidate, (nextAir.seasonNumber, nextAir.episodeNumber))) {
    return null;
  }
  // ...and nothing strictly after the last aired episode has. TMDB reports a
  // last_episode_to_air for any show that's aired, and (unlike next-to-air) it
  // survives between seasons — so this is what stops a stubbed-but-unaired next
  // season, which carries no next_episode_to_air, being offered as watchable
  // and corrupting the progress pointer when ticked.
  final lastAir = details.lastEpisode;
  if (lastAir != null &&
      airsBefore((lastAir.seasonNumber, lastAir.episodeNumber), candidate)) {
    return null;
  }
  return candidate;
}

SeasonInfo? _seasonNumbered(List<SeasonInfo> seasons, int n) {
  for (final s in seasons) {
    if (s.seasonNumber == n) return s;
  }
  return null;
}

SeasonInfo? _firstSeasonAfter(List<SeasonInfo> seasons, int n) {
  for (final s in seasons) {
    if (s.seasonNumber > n) return s; // seasons are sorted ascending
  }
  return null;
}

/// `(s1,e1)` airs strictly before `(s2,e2)` in aired order.
bool airsBefore((int, int) a, (int, int) b) =>
    a.$1 < b.$1 || (a.$1 == b.$1 && a.$2 < b.$2);

/// `S2E5`, plus the episode title when the backend supplied one.
String episodeLabel(int season, int episode, [String? title]) {
  final code = 'S${season}E$episode';
  return title == null || title.isEmpty ? code : '$code · $title';
}

/// How far ahead Upcoming looks. Not a load limit — a backend returns exactly
/// **one** next-to-air episode per show, and it is already decoded in memory by
/// the read the queue performs anyway. It is a *signal* limit: a show returning
/// in two years is noise, and a date that distant is usually a placeholder the
/// backend will revise.
const upcomingHorizonMonths = 6;

/// The next scheduled episode for a tracked show — the unit of Upcoming — or
/// null when the show has nothing to wait for.
///
/// Requires a next-to-air episode with a **date**, falling inside
/// `[today, today + `[upcomingHorizonMonths]`]`:
///
/// - The **lower** bound is load-bearing. `nextEpisode` comes from a cache that
///   may be stale (airing shows have a 12h TTL), so its air date can already
///   have passed. An episode that has aired must never sit in Upcoming.
///
///   **Known gap:** such a show lands in NEITHER list until the cache
///   refreshes.
///   Upcoming drops it by *date* (here); the queue drops it by *coordinate*
///   (`nextUnwatchedAired` compares against the same stale `nextEpisode`, so
///   the just-aired episode still reads as "not yet airing"). So on the day an
///   episode airs, a caught-up show can briefly vanish from the page. Bounded
///   by the 12h airing TTL, healed by the next sync / app resume. Pinned by
///   "a stale-aired show falls into NEITHER list" in up_next_providers_test —
///   change that test deliberately, not by accident.
/// - An **ended** show carries no `nextEpisode` at all, so it excludes itself;
///   no show-status check is needed here.
UpcomingEntry? upcomingFor(
  LibraryItem item,
  MediaDetails details,
  DateTime now,
) {
  final next = details.nextEpisode;
  final airDate = next?.airDate;
  if (next == null || airDate == null) return null;
  if (daysUntil(now, airDate) < 0) return null; // stale cache: already aired
  if (airDate.isAfter(_horizon(now))) return null;
  return (
    itemId: item.id,
    showTitle: item.title,
    posterPath: item.posterPath,
    season: next.seasonNumber,
    episode: next.episodeNumber,
    episodeTitle: next.title,
    airDate: airDate,
  );
}

/// Calendar months, not a day count: `DateTime` normalises `month > 12` into
/// the following year on its own, and building a date carries none of the DST
/// hazard `Duration` arithmetic does. A day that doesn't exist in the target
/// month (31 Aug + 6 → "31 Feb") rolls forward a day or two, which is
/// immaterial for a horizon cut-off.
DateTime _horizon(DateTime now) =>
    DateTime(now.year, now.month + upcomingHorizonMonths, now.day);

/// Whole calendar days from [now] to [airDate] — negative once it has aired.
int daysUntil(DateTime now, DateTime airDate) =>
    // Compare UTC midnights, NOT `difference(...).inDays` on raw instants: a
    // DST shift makes a local "day" 23 or 25 hours long, which silently rounds
    // a day away. The hazard `_streakDays` documents in stats_snapshot.dart.
    DateTime.utc(
      airDate.year,
      airDate.month,
      airDate.day,
    ).difference(DateTime.utc(now.year, now.month, now.day)).inDays;

/// Airing within the next 7 days (today included) — the "This week" group.
/// Rolling, not a calendar week: a calendar week is empty by definition on a
/// Sunday.
bool isThisWeek(int days) => days >= 0 && days < 7;

/// When an episode airs, relative to [now]: `Today`, `Tomorrow`, a weekday name
/// inside the week, otherwise a date (`12 Mar`, or `12 Mar 2027` when it falls
/// in another year).
///
/// Hand-rolled because the project has no `intl` dependency — see `_isoDate` in
/// detail_screen.dart, which hand-rolls for the same reason.
String airLabel(DateTime airDate, DateTime now) {
  final days = daysUntil(now, airDate);
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (isThisWeek(days)) return _weekdays[airDate.weekday - 1];
  final date = '${airDate.day} ${_months[airDate.month - 1]}';
  return airDate.year == now.year ? date : '$date ${airDate.year}';
}

/// Indexed by `DateTime.weekday - 1` (1 = Monday).
const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Indexed by `DateTime.month - 1`.
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// The live library, re-emitting on **every** write (a watch mark included), so
/// the queue advances the moment an episode is ticked. (The old upcoming stream
/// deliberately suppressed watch re-emissions; that is exactly what stopped the
/// tab refreshing.) Plain `StreamProvider` per the CLAUDE.md Drift-row rule.
final libraryItemsProvider = StreamProvider<List<LibraryItem>>(
  (ref) => ref.watch(libraryDaoProvider).watchAll(),
);

/// Everything the Up Next page shows, from one batched cache read (#21, R4):
/// the next unwatched **aired** episode for every tracked show that has one
/// (the watch queue), and every tracked show's next **scheduled** episode
/// (upcoming). Both projections need the same `MediaDetails` for the same
/// shows, so they share the read rather than each paying for one.
///
/// Degrades offline (cache-only). Re-runs on any library write (via
/// [libraryItemsProvider]), recomputing from cache — so ticking an episode
/// updates the list live.
@riverpod
Future<UpNextBoard> upNextBoard(Ref ref) async {
  final backend = metadataSourceKindOf(
    ref.watch(activeMetadataBackendProvider),
  );
  final items = await ref.watch(libraryItemsProvider.future);
  final repo = ref.watch(metadataRepositoryProvider);
  final now = clock.now();

  final shows = showsForQueue(items, backend);
  // One batched, cache-only read for the whole page — not an N+1 of per-show
  // reads on a provider that recomputes on every library write. A cold show is
  // absent from [details] and skipped; the tracked-show sync warms its cache
  // and the page recomputes (via [libraryItemsProvider]) once it does.
  final sourceIds = [
    for (final item in shows)
      if (item.sourceIdFor(backend) case final int id) id,
  ];
  final details = await repo.cachedShowDetails(sourceIds);

  final queue = <QueueEntry>[];
  final upcoming = <UpcomingEntry>[];
  for (final item in shows) {
    final sourceId = item.sourceIdFor(backend);
    final d = sourceId == null ? null : details[sourceId];
    if (d == null) continue;

    final next = nextUnwatchedAired(
      item.lastWatchedSeason,
      item.lastWatchedEpisode,
      d,
    );
    if (next != null) {
      queue.add((
        itemId: item.id,
        showTitle: item.title,
        posterPath: item.posterPath,
        season: next.$1,
        episode: next.$2,
      ));
    }

    // Independent of the queue, NOT an `else`: a show you are behind on can
    // also have its next episode scheduled. It belongs in both lists.
    if (upcomingFor(item, d, now) case final soon?) upcoming.add(soon);
  }

  queue.sort(
    (a, b) => a.showTitle.toLowerCase().compareTo(b.showTitle.toLowerCase()),
  );
  // Soonest first. Title only breaks a same-day tie, so the order is stable.
  upcoming.sort((a, b) {
    final byDate = a.airDate.compareTo(b.airDate);
    return byDate != 0
        ? byDate
        : a.showTitle.toLowerCase().compareTo(b.showTitle.toLowerCase());
  });
  return (queue: queue, upcoming: upcoming, now: now);
}
