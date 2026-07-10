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
      !_before(candidate, (nextAir.seasonNumber, nextAir.episodeNumber))) {
    return null;
  }
  // ...and nothing strictly after the last aired episode has. TMDB reports a
  // last_episode_to_air for any show that's aired, and (unlike next-to-air) it
  // survives between seasons — so this is what stops a stubbed-but-unaired next
  // season, which carries no next_episode_to_air, being offered as watchable
  // and corrupting the progress pointer when ticked.
  final lastAir = details.lastEpisode;
  if (lastAir != null &&
      _before((lastAir.seasonNumber, lastAir.episodeNumber), candidate)) {
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
bool _before((int, int) a, (int, int) b) =>
    a.$1 < b.$1 || (a.$1 == b.$1 && a.$2 < b.$2);

/// `S2E5`, plus the episode title when the backend supplied one.
String episodeLabel(int season, int episode, [String? title]) {
  final code = 'S${season}E$episode';
  return title == null || title.isEmpty ? code : '$code · $title';
}

/// The live library, re-emitting on **every** write (a watch mark included), so
/// the queue advances the moment an episode is ticked. (The old upcoming stream
/// deliberately suppressed watch re-emissions; that is exactly what stopped the
/// tab refreshing.) Plain `StreamProvider` per the CLAUDE.md Drift-row rule.
final libraryItemsProvider = StreamProvider<List<LibraryItem>>(
  (ref) => ref.watch(libraryDaoProvider).watchAll(),
);

/// The Up Next watch queue: the next unwatched aired episode for every tracked
/// show that has one (#21). Reads all its shows' details from cache in a single
/// batched query and degrades offline. Re-runs on any library write (via
/// [libraryItemsProvider]), recomputing from cache — so ticking an episode
/// updates the list live.
@riverpod
Future<List<QueueEntry>> watchQueue(Ref ref) async {
  final backend = metadataSourceKindOf(
    ref.watch(activeMetadataBackendProvider),
  );
  final items = await ref.watch(libraryItemsProvider.future);
  final repo = ref.watch(metadataRepositoryProvider);

  final shows = showsForQueue(items, backend);
  // One batched, cache-only read for the whole queue — not an N+1 of per-show
  // reads on a provider that recomputes on every library write. A cold show is
  // absent from [details] and skipped; the tracked-show sync warms its cache
  // and the queue recomputes (via [libraryItemsProvider]) once it does.
  final sourceIds = [
    for (final item in shows)
      if (item.sourceIdFor(backend) case final int id) id,
  ];
  final details = await repo.cachedShowDetails(sourceIds);

  final entries = <QueueEntry>[];
  for (final item in shows) {
    final sourceId = item.sourceIdFor(backend);
    final d = sourceId == null ? null : details[sourceId];
    if (d == null) continue;
    final next = nextUnwatchedAired(
      item.lastWatchedSeason,
      item.lastWatchedEpisode,
      d,
    );
    if (next == null) continue;
    entries.add((
      itemId: item.id,
      showTitle: item.title,
      posterPath: item.posterPath,
      season: next.$1,
      episode: next.$2,
    ));
  }

  entries.sort(
    (a, b) => a.showTitle.toLowerCase().compareTo(b.showTitle.toLowerCase()),
  );
  return entries;
}
