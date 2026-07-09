import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

part 'up_next_providers.g.dart';

/// A tracked show as the upcoming fetch needs it: this backend's **own** show
/// id (the key `upcomingForTracked` takes) plus what its rows render. A record,
/// so `listEquals` can tell an unchanged tracked set from a changed one.
typedef TrackedShow = ({int sourceId, int itemId, String title});

/// One row of the Up Next list: a dated episode plus the tracked show it
/// belongs to. `itemId` is the `LibraryItems` row id, so a tap can push
/// `/title/:id`.
typedef UpcomingEntry = ({
  int itemId,
  String showTitle,
  UpcomingEpisode upcoming,
});

/// How far ahead "this week" reaches (US-5).
const int _windowDays = 7;

/// The tracked shows whose upcoming episodes belong on the Up Next tab (#21).
///
/// INVARIANT (mirrors the caching rule in CLAUDE.md — refresh only tracked
/// shows, skip `dropped` / ended-`completed`):
/// - **Shows only.** A movie release date does not exist in the data model
///   (`year` is an int; `MetadataSource` has no release-date call), so upcoming
///   movie releases are out of M2 scope — a follow-up issue.
/// - **Skip `dropped`**, and skip `completed` shows that have **ended**. A
///   completed *returning* show still airs new episodes, which is exactly what
///   the tab is for — so `completed` alone is not a reason to skip.
/// - **Skip a row whose `recordedSource` != [backend].** Its id column holds
///   the *other* backend's id; passing it to `upcomingForTracked` would
///   silently fetch an unrelated show (a post-switch `relinkFailed` row).
List<TrackedShow> trackedShowsForUpcoming(
  List<LibraryItem> items,
  MetadataSourceKind backend,
) => [
  for (final item in items)
    if (item.mediaType == MediaType.tv &&
        item.recordedSource == backend &&
        item.trackStatus != TrackStatus.dropped &&
        !(item.trackStatus == TrackStatus.completed &&
            showHasEnded(item.showStatus)))
      if (_sourceIdOf(item, backend) case final int sourceId)
        (sourceId: sourceId, itemId: item.id, title: item.title),
];

/// The id column matching [backend] — the one `recordedSource` pins.
int? _sourceIdOf(LibraryItem item, MetadataSourceKind backend) =>
    switch (backend) {
      MetadataSourceKind.tmdb => item.tmdbId,
      MetadataSourceKind.tvdb => item.tvdbId,
    };

/// The episodes from [episodes] that air within the next [_windowDays] days,
/// joined back to their tracked show and sorted chronologically.
///
/// An episode whose show id isn't in [byShowId] is **dropped** — an untracked
/// show can never reach the tab (US-5), whatever the source hands back.
List<UpcomingEntry> upcomingEntriesThisWeek(
  List<UpcomingEpisode> episodes,
  Map<int, TrackedShow> byShowId, {
  required MetadataSourceKind backend,
  required DateTime now,
}) {
  // Local midnight today, through +7 days exclusive. Calendar arithmetic (day
  // overflow normalizes) rather than `add(Duration(days: 7))`, so a DST shift
  // can't drag the boundary an hour into the previous day.
  final start = DateTime(now.year, now.month, now.day);
  final end = DateTime(now.year, now.month, now.day + _windowDays);

  final entries = <UpcomingEntry>[];
  for (final episode in episodes) {
    final showId = switch (backend) {
      MetadataSourceKind.tmdb => episode.tmdbId,
      MetadataSourceKind.tvdb => episode.tvdbId,
    };
    final show = byShowId[showId];
    if (show == null) continue;
    final airDate = episode.airDate;
    if (airDate.isBefore(start) || !airDate.isBefore(end)) continue;
    entries.add((
      itemId: show.itemId,
      showTitle: show.title,
      upcoming: episode,
    ));
  }
  entries.sort((a, b) {
    final byDate = a.upcoming.airDate.compareTo(b.upcoming.airDate);
    return byDate != 0 ? byDate : a.showTitle.compareTo(b.showTitle);
  });
  return entries;
}

/// Buckets already-chronological [entries] by local air day — the tab's day
/// headers. A plain map literal preserves insertion order, so the groups (and
/// the rows inside them) stay chronological.
Map<DateTime, List<UpcomingEntry>> groupByAirDay(List<UpcomingEntry> entries) {
  final byDay = <DateTime, List<UpcomingEntry>>{};
  for (final entry in entries) {
    final air = entry.upcoming.airDate;
    byDay
        .putIfAbsent(DateTime(air.year, air.month, air.day), () => [])
        .add(entry);
  }
  return byDay;
}

/// `S2E5`, plus the episode title when the backend supplied one.
String episodeLabel(EpisodeInfo episode) {
  final code = 'S${episode.seasonNumber}E${episode.episodeNumber}';
  final title = episode.title;
  return title == null || title.isEmpty ? code : '$code · $title';
}

/// The live tracked-show set feeding the upcoming fetch.
///
/// The `distinct` is load-bearing: every watch write rewrites `LibraryItems`'
/// denormalized columns, so without it marking a single episode would re-emit
/// here and fire a fresh network fetch.
@riverpod
Stream<List<TrackedShow>> trackedShows(Ref ref) {
  final backend = metadataSourceKindOf(
    ref.watch(activeMetadataBackendProvider),
  );
  return ref
      .watch(libraryDaoProvider)
      .watchAll()
      .map((items) => trackedShowsForUpcoming(items, backend))
      .distinct(listEquals);
}

/// This week's episodes for tracked shows (#21, US-5).
///
/// `upcomingForTracked` is **not** fronted by `CachingMetadataRepository` (it
/// has no cache-first stream), so offline this throws and the screen renders an
/// error state rather than a blank crash. Follow-up (US-13 offline parity):
/// degrade to the promoted `CachedMedia.nextAirDate` of tracked shows.
@riverpod
Future<List<UpcomingEntry>> upcomingThisWeek(Ref ref) async {
  final backend = metadataSourceKindOf(
    ref.watch(activeMetadataBackendProvider),
  );
  final shows = await ref.watch(trackedShowsProvider.future);
  if (shows.isEmpty) return const [];

  final byShowId = {for (final show in shows) show.sourceId: show};
  final episodes = await ref
      .watch(activeMetadataSourceProvider)
      .upcomingForTracked(byShowId.keys.toList());
  return upcomingEntriesThisWeek(
    episodes,
    byShowId,
    backend: backend,
    now: clock.now(),
  );
}
