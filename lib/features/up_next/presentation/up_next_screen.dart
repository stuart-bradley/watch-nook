import 'package:cached_network_image/cached_network_image.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/empty_state.dart';
import 'package:watch_nook/core/widgets/poster_placeholder.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';

/// Up Next tab (#21) — the **watch queue**: the next unwatched aired episode
/// every tracked show that has one, each with a poster and a tick to mark it
/// watched without leaving the tab. Ticking advances the row live (the queue
/// recomputes from the library stream). Renders its three states, never a blank
/// crash when a show's (cache-first) fetch fails offline.
class UpNextScreen extends ConsumerWidget {
  const UpNextScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(watchQueueProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => EmptyState(
            icon: Icons.cloud_off,
            headline: "Couldn't load your queue.",
            body: "You're offline, or the metadata service is unreachable.",
            actions: [
              TextButton(
                onPressed: () => ref.invalidate(watchQueueProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
          data: (entries) => entries.isEmpty
              ? const _NothingUpNext()
              : _Queue(entries: entries),
        );
  }
}

/// An empty queue has two causes with opposite advice: a user tracking no shows
/// needs to add one; a user tracking many is caught up. Distinguished off
/// the live library — until it resolves, "caught up" is the safe default (it is
/// the less-wrong thing to tell someone with a full library).
class _NothingUpNext extends ConsumerWidget {
  const _NothingUpNext();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(libraryItemsProvider).value;
    // Backend-agnostic on purpose: the empty-state copy only needs "is there a
    // TV show to be caught up on?", not the active-backend id filter the queue
    // itself applies. Keeps this off remote config (and thus test-friendly).
    final hasShows =
        items != null &&
        items.any(
          (i) =>
              i.mediaType == MediaType.tv &&
              i.trackStatus != TrackStatus.dropped,
        );
    if (items != null && !hasShows) {
      return const EmptyState(
        icon: Icons.tv_off_outlined,
        headline: 'No shows tracked yet',
        body:
            'Add a TV show to your library and its next episode turns up here.',
      );
    }
    return const EmptyState(
      icon: Icons.check_circle_outline,
      headline: "You're all caught up",
      body: 'Every tracked show is watched up to its latest aired episode.',
    );
  }
}

/// Flat, alphabetical list of "continue watching" cards.
class _Queue extends StatelessWidget {
  const _Queue({required this.entries});

  final List<QueueEntry> entries;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: WatchnookSpacing.sm),
    itemCount: entries.length,
    itemBuilder: (context, i) => _QueueTile(entry: entries[i]),
  );
}

class _QueueTile extends ConsumerWidget {
  const _QueueTile({required this.entry});

  final QueueEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: _Poster(path: entry.posterPath),
    title: Text(entry.showTitle),
    subtitle: Text('Next: ${episodeLabel(entry.season, entry.episode)}'),
    // Mark this exact episode watched from the queue; the library stream
    // re-emits and the queue advances this row to the next episode (or drops
    // it when caught up) — no reload needed.
    trailing: IconButton(
      icon: const Icon(Icons.check_circle_outline),
      tooltip: 'Mark watched',
      onPressed: () => ref
          .read(libraryDaoProvider)
          .markWatched(
            entry.itemId,
            season: entry.season,
            episode: entry.episode,
            watchedAt: clock.now(),
          ),
    ),
    // Detail is a pushed route keyed by the library row id (AD-5).
    onTap: () => context.push('/title/${entry.itemId}'),
  );
}

/// Show thumbnail — the same offline-safe poster the search + import rows use.
class _Poster extends ConsumerWidget {
  const _Poster({required this.path});

  final String? path;

  static const _placeholder = PosterPlaceholder(
    width: _posterWidth,
    height: _posterHeight,
    radius: WatchnookRadii.thumb,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = this.path;
    if (path == null) return _placeholder;
    final url = ref
        .read(activeMetadataSourceProvider)
        .imageUrl(path, ImageSize.small);
    return ClipRRect(
      borderRadius: WatchnookRadii.thumb,
      child: CachedNetworkImage(
        imageUrl: url,
        cacheManager: PosterCacheManager.instance,
        width: _posterWidth,
        height: _posterHeight,
        fit: BoxFit.cover,
        placeholder: (_, _) => _placeholder,
        errorWidget: (_, _, _) => _placeholder,
      ),
    );
  }
}

const double _posterWidth = 40;
const double _posterHeight = _posterWidth / WatchnookTokens.posterAspect;
