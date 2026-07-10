import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
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

/// Max concurrent detail lookups while (re)building the queue. Cache-first
/// are instant; this only bites on a cold cache (first build after an import),
/// where it keeps the TMDB per-IP limit happy.
const _queueConcurrency = 6;

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

/// The id column matching [backend] — the one `recordedSource` pins.
int? sourceIdOf(LibraryItem item, MetadataSourceKind backend) =>
    switch (backend) {
      MetadataSourceKind.tmdb => item.tmdbId,
      MetadataSourceKind.tvdb => item.tvdbId,
    };

/// The next episode to watch after the `(lastSeason, lastEpisode)` progress
/// pointer, **if it has already aired** — the heart of the watch queue.
///
/// "Next" is strictly the episode after the last-watched one (the user's chosen
/// rule): mid-season skips are ignored. Season 0 (specials) is dropped from
/// ordering. Returns null when the show is caught up — either nothing exists
/// after the pointer, or the next episode has not aired (it is at or after
/// `details.nextEpisode`, the next-to-air).
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

  // Aired? Everything strictly before the next-to-air episode has aired. A null
  // next-to-air means the show is between/after seasons — existing episodes have
  // aired.
  final nextAir = details.nextEpisode;
  if (nextAir != null &&
      !_before(candidate, (nextAir.seasonNumber, nextAir.episodeNumber))) {
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
/// show that has one (#21). Cache-first per show (`showDetails(...).first`), so
/// it degrades offline and a single failed show is skipped rather than crashing
/// the whole list. Re-runs on any library write (via [libraryItemsProvider]),
/// recomputing from cache — so ticking an episode updates the list live.
@riverpod
Future<List<QueueEntry>> watchQueue(Ref ref) async {
  final backend = metadataSourceKindOf(
    ref.watch(activeMetadataBackendProvider),
  );
  final items = await ref.watch(libraryItemsProvider.future);
  final repo = ref.watch(metadataRepositoryProvider);

  final shows = showsForQueue(items, backend);
  final entries = <QueueEntry>[];
  // Bounded fan-out: cache-first reads are instant, so this only paces the
  // cold-cache first build.
  for (var i = 0; i < shows.length; i += _queueConcurrency) {
    final batch = shows.skip(i).take(_queueConcurrency);
    final results = await Future.wait(
      batch.map((item) => _entryFor(item, backend, repo)),
    );
    entries.addAll(results.whereType<QueueEntry>());
  }

  entries.sort(
    (a, b) => a.showTitle.toLowerCase().compareTo(b.showTitle.toLowerCase()),
  );
  return entries;
}

/// One show's queue entry, or null when it is caught up / can't be resolved.
Future<QueueEntry?> _entryFor(
  LibraryItem item,
  MetadataSourceKind backend,
  CachingMetadataRepository repo,
) async {
  final sourceId = sourceIdOf(item, backend);
  if (sourceId == null) return null;
  try {
    final details = await repo.showDetails(sourceId).first;
    final next = nextUnwatchedAired(
      item.lastWatchedSeason,
      item.lastWatchedEpisode,
      details,
    );
    if (next == null) return null;
    return (
      itemId: item.id,
      showTitle: item.title,
      posterPath: item.posterPath,
      season: next.$1,
      episode: next.$2,
    );
  } on Object {
    return null; // offline / 404 / cold-and-unreachable — skip this show
  }
}
