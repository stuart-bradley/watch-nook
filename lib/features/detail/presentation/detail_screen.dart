import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/features/detail/data/bulk_mark.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';

/// Title detail (#18, US-6): backdrop, overview, the user's rating, the
/// seasons→episodes list, and the **mandatory** per-source attribution footer.
/// Route `/title/:id`, where `id` is the `LibraryItems` row — detail is only
/// reachable for a tracked title (search adds first).
///
/// Metadata comes from `titleDetailsProvider` (SWR, cache-first), so the screen
/// renders offline from cache and a failed revalidation never blanks it. The
/// per-episode watched toggle and the movie mark/rewatch buttons (#19) write
/// through `LibraryDao`, which owns the idempotent-toggle invariant.
class DetailScreen extends ConsumerWidget {
  /// Creates the detail screen for the `LibraryItems` row [itemId].
  const DetailScreen({required this.itemId, super.key});

  /// The `LibraryItems.id` from the route.
  final int itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(libraryItemProvider(itemId));
    return Scaffold(
      appBar: AppBar(title: Text(item.value?.title ?? '')),
      body: item.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const _Notice("Couldn't open this title."),
        data: (row) => row == null
            ? const _Notice('This title is no longer in your library.')
            : _Body(item: row),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourceId = detailSourceId(item);
    // ponytail: conditional watch — a row with no id for its own backend has no
    // details to fetch, so it renders from the stored columns alone.
    final async = sourceId == null
        ? null
        : ref.watch(titleDetailsProvider(item.mediaType, sourceId));
    final details = async?.value;
    final coldCache = async != null && !async.hasValue;

    return ListView(
      children: [
        _Backdrop(path: details?.backdropPath),
        if (coldCache && async.isLoading) const LinearProgressIndicator(),
        Padding(
          padding: const EdgeInsets.all(WatchnookSpacing.screen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(item: item, details: details),
              const SizedBox(height: WatchnookSpacing.md),
              _RatingRow(item: item),
              if (item.mediaType == MediaType.movie) ...[
                const SizedBox(height: WatchnookSpacing.md),
                _MovieWatchActions(item: item),
              ],
              if (details?.seasons.any((s) => s.seasonNumber > 0) ?? false) ...[
                const SizedBox(height: WatchnookSpacing.md),
                _BulkButton(
                  icon: Icons.done_all,
                  label: 'Mark show watched',
                  itemId: item.id,
                  showSourceId: sourceId!,
                  seasons: _seasonNumbers(details!),
                ),
              ],
              if (coldCache && async.hasError) ...[
                const SizedBox(height: WatchnookSpacing.md),
                const _Notice("Couldn't load details. You're offline."),
              ],
              if (details?.overview case final overview?
                  when overview.isNotEmpty) ...[
                const SizedBox(height: WatchnookSpacing.md),
                Text(overview, style: Theme.of(context).textTheme.bodyMedium),
              ],
              if (details?.nextEpisode case final next?) ...[
                const SizedBox(height: WatchnookSpacing.md),
                _NextEpisode(episode: next),
              ],
            ],
          ),
        ),
        // Seasons come from the details fetch; a movie has none.
        for (final season in details?.seasons ?? const <SeasonInfo>[])
          _SeasonTile(
            itemId: item.id,
            showSourceId: sourceId!,
            season: season,
            allSeasons: _seasonNumbers(details!),
          ),
        const _AttributionFooter(),
      ],
    );
  }
}

/// 16:9 backdrop. Offline-safe: a null path (or an uncached image) shows a
/// placeholder and never blocks the screen.
class _Backdrop extends ConsumerWidget {
  const _Backdrop({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = this.path;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: path == null
          ? const _BackdropPlaceholder()
          : CachedNetworkImage(
              imageUrl: ref
                  .read(activeMetadataSourceProvider)
                  .imageUrl(path, ImageSize.large),
              cacheManager: PosterCacheManager.instance,
              fit: BoxFit.cover,
              placeholder: (_, _) => const _BackdropPlaceholder(),
              errorWidget: (_, _, _) => const _BackdropPlaceholder(),
            ),
    );
  }
}

class _BackdropPlaceholder extends StatelessWidget {
  const _BackdropPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
      child: Center(
        child: Icon(Icons.movie_outlined, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Title + a "2022 · TV · Watching · Returning Series" caption. Falls back to
/// the stored row when details haven't loaded, so it renders offline.
class _Header extends StatelessWidget {
  const _Header({required this.item, required this.details});

  final LibraryItem item;
  final MediaDetails? details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final year = details?.year ?? item.year;
    final showStatus = details?.showStatus ?? item.showStatus;
    final kind = item.mediaType == MediaType.movie ? 'Film' : 'TV';
    final caption = <String>[
      if (year != null) '$year',
      kind,
      _statusLabel(item.trackStatus),
      ?showStatus,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          details?.title ?? item.title,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: WatchnookSpacing.xs),
        Text(
          caption,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The **user's** rating (`LibraryItems.rating`, 0–10) — the only rating in the
/// data model; neither backend's score is snapshotted. Tapping opens a picker
/// so the column set by `updateRating` is actually reachable.
class _RatingRow extends ConsumerWidget {
  const _RatingRow({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rating = item.rating;
    return ActionChip(
      avatar: Icon(rating == null ? Icons.star_border : Icons.star),
      label: Text(rating == null ? 'Rate' : '$rating/10'),
      onPressed: () => unawaited(_pickRating(context, ref, item)),
    );
  }
}

Future<void> _pickRating(
  BuildContext context,
  WidgetRef ref,
  LibraryItem item,
) async {
  // -1 distinguishes "cleared" from "dismissed" (null) — a rating of 0 is real.
  final picked = await showModalBottomSheet<int>(
    context: context,
    builder: (context) => SafeArea(
      child: Wrap(
        children: [
          for (var i = 10; i >= 1; i--)
            ListTile(
              leading: const Icon(Icons.star),
              title: Text('$i/10'),
              onTap: () => Navigator.pop(context, i),
            ),
          ListTile(
            leading: const Icon(Icons.star_border),
            title: const Text('Clear rating'),
            onTap: () => Navigator.pop(context, -1),
          ),
        ],
      ),
    ),
  );
  if (picked == null) return;
  await ref
      .read(libraryDaoProvider)
      .updateRating(item.id, picked == -1 ? null : picked, now: clock.now());
}

/// A movie's watched toggle + rewatch log (#19, US-2/US-4). Watched-ness is the
/// denormalized `watchedCount` on the live row — no cross-domain join, and a
/// rewatch (which never raises the count) leaves the button as it was.
class _MovieWatchActions extends ConsumerWidget {
  const _MovieWatchActions({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dao = ref.watch(libraryDaoProvider);
    final watched = item.watchedCount > 0;
    return Wrap(
      spacing: WatchnookSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          icon: Icon(watched ? Icons.check_circle : Icons.check_circle_outline),
          label: Text(watched ? 'Watched' : 'Mark watched'),
          onPressed: () => unawaited(
            watched
                ? dao.unwatch(item.id)
                : dao.markWatched(
                    item.id,
                    watchedAt: clock.now(),
                    runtimeMinutes: item.runtimeMinutes,
                  ),
          ),
        ),
        if (watched)
          TextButton.icon(
            icon: const Icon(Icons.replay),
            label: const Text('Log rewatch'),
            onPressed: () => unawaited(
              dao.logRewatch(
                item.id,
                watchedAt: clock.now(),
                runtimeMinutes: item.runtimeMinutes,
              ),
            ),
          ),
      ],
    );
  }
}

class _NextEpisode extends StatelessWidget {
  const _NextEpisode({required this.episode});

  final EpisodeInfo episode;

  @override
  Widget build(BuildContext context) {
    final airDate = episode.airDate;
    final parts = <String>[
      'Next: S${episode.seasonNumber}E${episode.episodeNumber}',
      if (episode.title != null) episode.title!,
      if (airDate != null) _isoDate(airDate),
    ];
    return Row(
      children: [
        const Icon(Icons.schedule, size: 16),
        const SizedBox(width: WatchnookSpacing.sm),
        Expanded(child: Text(parts.join(' · '))),
      ],
    );
  }
}

/// One collapsible season. `ExpansionTile` doesn't build its children while
/// collapsed, so the episode fetch happens on expand — one season at a time.
class _SeasonTile extends StatelessWidget {
  const _SeasonTile({
    required this.itemId,
    required this.showSourceId,
    required this.season,
    required this.allSeasons,
  });

  final int itemId;
  final int showSourceId;
  final SeasonInfo season;

  /// Every season number of the show — "watch up to here" spans the seasons
  /// before this one, so the episode rows need more than their own season.
  final List<int> allSeasons;

  @override
  Widget build(BuildContext context) {
    final name = season.name ?? 'Season ${season.seasonNumber}';
    return ExpansionTile(
      title: Text(name),
      subtitle: Text('${season.episodeCount} episodes'),
      children: [
        // Specials (season 0) have no bulk action — they're excluded from
        // aired-order progress, so the button would mark nothing.
        if (season.seasonNumber > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: WatchnookSpacing.screen,
              ),
              child: _BulkButton(
                icon: Icons.playlist_add_check,
                label: 'Mark season watched',
                itemId: itemId,
                showSourceId: showSourceId,
                seasons: [season.seasonNumber],
              ),
            ),
          ),
        _SeasonEpisodes(
          itemId: itemId,
          showSourceId: showSourceId,
          seasonNumber: season.seasonNumber,
          allSeasons: allSeasons,
        ),
      ],
    );
  }
}

/// Fires a bulk mark (#20) and reports the outcome. `seasons`/`upTo` are handed
/// straight to [bulkMarkWatched], which excludes specials and is idempotent.
class _BulkButton extends ConsumerWidget {
  const _BulkButton({
    required this.icon,
    required this.label,
    required this.itemId,
    required this.showSourceId,
    required this.seasons,
  });

  final IconData icon;
  final String label;
  final int itemId;
  final int showSourceId;
  final List<int> seasons;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OutlinedButton.icon(
    icon: Icon(icon),
    label: Text(label),
    onPressed: () => unawaited(
      _runBulk(
        context,
        ref,
        itemId: itemId,
        showSourceId: showSourceId,
        seasons: seasons,
      ),
    ),
  );
}

/// Runs a bulk mark and surfaces the result in a snack bar. The messenger is
/// captured **before** the await, so no `BuildContext` crosses the async gap.
/// A cold cache with no network throws out of [bulkMarkWatched] having written
/// nothing — the user sees the offline notice, not a half-marked season.
Future<void> _runBulk(
  BuildContext context,
  WidgetRef ref, {
  required int itemId,
  required int showSourceId,
  required List<int> seasons,
  (int, int)? upTo,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final marked = await bulkMarkWatched(
      dao: ref.read(libraryDaoProvider),
      repo: ref.read(metadataRepositoryProvider),
      itemId: itemId,
      showSourceId: showSourceId,
      seasons: seasons,
      upTo: upTo,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          switch (marked) {
            0 => 'Already watched.',
            1 => 'Marked 1 episode watched.',
            _ => 'Marked $marked episodes watched.',
          },
        ),
      ),
    );
  } on Object {
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't load episodes. You're offline.")),
    );
  }
}

/// Aired-order season numbers of a show's details, specials included (the bulk
/// helpers do the season-0 filtering, in one place).
List<int> _seasonNumbers(MediaDetails details) =>
    details.seasons.map((s) => s.seasonNumber).toList();

class _SeasonEpisodes extends ConsumerWidget {
  const _SeasonEpisodes({
    required this.itemId,
    required this.showSourceId,
    required this.seasonNumber,
    required this.allSeasons,
  });

  final int itemId;
  final int showSourceId;
  final int seasonNumber;
  final List<int> allSeasons;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodes = ref.watch(
      seasonEpisodesProvider(showSourceId, seasonNumber),
    );
    // Before the first emission nothing is known to be watched — an unwatched
    // toggle that marks is the safe default (marking is idempotent; unwatching
    // is destructive).
    final watched =
        ref.watch(watchedEpisodesProvider(itemId)).value ??
        const <(int, int)>{};
    return episodes.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(WatchnookSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const _Notice("Couldn't load episodes."),
      data: (rows) => Column(
        children: [
          for (final e in rows)
            ListTile(
              dense: true,
              leading: Text('E${e.episodeNumber}'),
              title: Text(e.title ?? 'Episode ${e.episodeNumber}'),
              subtitle: e.airDate == null ? null : Text(_isoDate(e.airDate!)),
              // "Watch up to here" (#20): everything aired-order ≤ this
              // episode, across the earlier seasons too.
              onLongPress: e.seasonNumber <= 0
                  ? null
                  : () => unawaited(
                      _runBulk(
                        context,
                        ref,
                        itemId: itemId,
                        showSourceId: showSourceId,
                        seasons: allSeasons,
                        upTo: (e.seasonNumber, e.episodeNumber),
                      ),
                    ),
              trailing: _EpisodeToggle(
                itemId: itemId,
                episode: e,
                watched: watched.contains((e.seasonNumber, e.episodeNumber)),
              ),
            ),
        ],
      ),
    );
  }
}

/// The per-episode watched toggle (#19, US-2). Mark is idempotent; unwatch
/// removes the episode's rewatches too. `runtimeMinutes` is snapshotted from
/// the episode at mark-time so stats never read the disposable cache.
class _EpisodeToggle extends ConsumerWidget {
  const _EpisodeToggle({
    required this.itemId,
    required this.episode,
    required this.watched,
  });

  final int itemId;
  final EpisodeInfo episode;
  final bool watched;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dao = ref.watch(libraryDaoProvider);
    return IconButton(
      icon: Icon(watched ? Icons.check_circle : Icons.check_circle_outline),
      tooltip: watched ? 'Mark unwatched' : 'Mark watched',
      onPressed: () => unawaited(
        watched
            ? dao.unwatch(
                itemId,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
              )
            : dao.markWatched(
                itemId,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
                watchedAt: clock.now(),
                runtimeMinutes: episode.runtimeMinutes,
              ),
      ),
    );
  }
}

/// **Mandatory** per-source attribution (CLAUDE.md): TMDB's "not endorsed"
/// notice, or TheTVDB's linked credit. Rendered from the active source's own
/// `attribution()`, so flipping the backend flips the credit with no code
/// change. Neither source bundles a logo yet — `logoAsset` is honoured when one
/// appears.
class _AttributionFooter extends ConsumerWidget {
  const _AttributionFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final attribution = ref.watch(activeMetadataSourceProvider).attribution();
    final url = Uri.parse(attribution.linkUrl);
    return Padding(
      padding: const EdgeInsets.all(WatchnookSpacing.xl),
      child: Column(
        children: [
          if (attribution.logoAsset case final asset?)
            Image.asset(asset, height: 20),
          Text(
            attribution.notice,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextButton(
            onPressed: () => unawaited(
              launchUrl(url, mode: LaunchMode.externalApplication),
            ),
            child: Text(attribution.linkUrl),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(WatchnookSpacing.lg),
    child: Text(message, textAlign: TextAlign.center),
  );
}

/// ISO-8601 date, no `intl` dependency for one label.
String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _statusLabel(TrackStatus s) => switch (s) {
  TrackStatus.watchlist => 'Watchlist',
  TrackStatus.watching => 'Watching',
  TrackStatus.completed => 'Completed',
  TrackStatus.onHold => 'On hold',
  TrackStatus.dropped => 'Dropped',
};
