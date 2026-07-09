import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// StreamProviderFamily lives in the misc barrel, not the main one.
import 'package:flutter_riverpod/misc.dart' show StreamProviderFamily;
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/empty_state.dart';

/// The library grid filter — status and/or type, either null for "all". A
/// record so the family key has value equality (same filter reuses the stream).
typedef LibraryFilter = ({TrackStatus? status, MediaType? type});

/// The filtered library stream (#17). Plain `StreamProvider` (not `@riverpod`)
/// because it exposes a Drift-generated row type — the generator throws on
/// those (CLAUDE.md convention). Reads **only** the denormalized columns via
/// `watchLibrary`, so the grid never does a cross-domain join and renders
/// entirely offline.
final StreamProviderFamily<List<LibraryItem>, LibraryFilter>
libraryGridProvider = StreamProvider.family<List<LibraryItem>, LibraryFilter>(
  (ref, filter) => ref
      .watch(libraryDaoProvider)
      .watchLibrary(status: filter.status, type: filter.type),
);

/// The progress caption under a grid card, built **only** from the denormalized
/// fields (`watchedCount`, `lastWatched*`, `episodeCountTotal`) — never a
/// metadata fetch, so it renders offline (#17 acceptance: "S2E4 · 3 left").
///
/// - Movie: watched / unwatched.
/// - TV, nothing watched: total episode count, or "Not started".
/// - TV, in progress: `S{season}E{episode}` + " · {left} left" when the total
///   is known and any remain.
String libraryProgressLabel(LibraryItem item) {
  if (item.mediaType == MediaType.movie) {
    return item.watchedCount > 0 ? 'Watched' : 'Unwatched';
  }
  final season = item.lastWatchedSeason;
  final episode = item.lastWatchedEpisode;
  final total = item.episodeCountTotal;
  if (season == null || episode == null) {
    return total != null ? '$total episodes' : 'Not started';
  }
  final position = 'S${season}E$episode';
  if (total == null) return position;
  final left = total - item.watchedCount;
  return left > 0 ? '$position · $left left' : position;
}

/// The library home tab: a filterable, offline-first grid of tracked titles
/// (#17, US-13). Filter chips drive `watchLibrary`; cards render from the
/// denormalized progress fields.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  TrackStatus? _status;
  MediaType? _type;

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(
      libraryGridProvider((status: _status, type: _type)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FilterBar(
          status: _status,
          type: _type,
          onStatus: (s) => setState(() => _status = s),
          onType: (t) => setState(() => _type = t),
        ),
        Expanded(
          child: items.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => const EmptyState(
              icon: Icons.error_outline,
              headline: "Couldn't load your library.",
            ),
            data: (rows) => rows.isEmpty
                ? _EmptyLibrary(filtered: _status != null || _type != null)
                : _Grid(rows: rows),
          ),
        ),
      ],
    );
  }
}

/// An empty grid means one of two very different things, and saying the wrong
/// one is the bug this split exists to prevent: a user with 300 titles whose
/// filter matched nothing must not be told their library is empty (#35, US-13).
class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.filtered});

  /// Whether a status/type chip is narrowing the grid.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    if (filtered) {
      return const EmptyState(
        icon: Icons.filter_alt_off_outlined,
        headline: 'Nothing matches this filter',
        body: 'Try another status or type.',
      );
    }
    return EmptyState(
      icon: Icons.video_library_outlined,
      headline: 'Your library is empty',
      body:
          'Search for a film or show to track it, or import the history you '
          'already have somewhere else.',
      actions: [
        FilledButton.icon(
          onPressed: () => context.push('/search'),
          icon: const Icon(Icons.search),
          label: const Text('Search'),
        ),
        OutlinedButton.icon(
          onPressed: () => context.push('/import'),
          icon: const Icon(Icons.file_upload_outlined),
          label: const Text('Import'),
        ),
      ],
    );
  }
}

/// Two scrollable chip rows: tracking status, then media type. A null selection
/// (the "All" chip) clears that filter.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.status,
    required this.type,
    required this.onStatus,
    required this.onType,
  });

  final TrackStatus? status;
  final MediaType? type;
  final ValueChanged<TrackStatus?> onStatus;
  final ValueChanged<MediaType?> onType;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ChipRow(
          children: [
            _chip('All', status == null, () => onStatus(null)),
            for (final s in TrackStatus.values)
              _chip(_statusLabel(s), status == s, () => onStatus(s)),
          ],
        ),
        _ChipRow(
          children: [
            _chip('All types', type == null, () => onType(null)),
            _chip(
              'Films',
              type == MediaType.movie,
              () => onType(MediaType.movie),
            ),
            _chip('TV', type == MediaType.tv, () => onType(MediaType.tv)),
          ],
        ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: WatchnookSpacing.sm),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    ),
  );
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(
      horizontal: WatchnookSpacing.screen,
      vertical: WatchnookSpacing.xs,
    ),
    child: Row(children: children),
  );
}

class _Grid extends StatelessWidget {
  const _Grid({required this.rows});

  final List<LibraryItem> rows;

  @override
  Widget build(BuildContext context) => GridView.builder(
    padding: const EdgeInsets.all(WatchnookSpacing.screen),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 180,
      mainAxisSpacing: WatchnookSpacing.lg,
      crossAxisSpacing: WatchnookSpacing.md,
      // ponytail: poster (2:3) + two text lines. Fixed ratio; poster is
      // Expanded so text never overflows if the estimate is a touch off.
      childAspectRatio: 0.52,
    ),
    itemCount: rows.length,
    itemBuilder: (context, i) => _Card(item: rows[i]),
  );
}

class _Card extends ConsumerWidget {
  const _Card({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return InkWell(
      // Detail is a pushed route keyed by the library row id (#18, AD-5).
      onTap: () => context.push('/title/${item.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: WatchnookRadii.poster,
              child: _Poster(path: item.posterPath),
            ),
          ),
          const SizedBox(height: WatchnookSpacing.sm),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
          Text(
            libraryProgressLabel(item),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Poster art — offline-safe. A null path (or an image not yet cached) shows a
/// placeholder and never touches the network; only a non-null path reads the
/// active source for its URL, so the grid renders with no source provider in
/// tests.
class _Poster extends ConsumerWidget {
  const _Poster({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = this.path;
    if (path == null) return const _PosterPlaceholder();
    final url = ref
        .read(activeMetadataSourceProvider)
        .imageUrl(path, ImageSize.medium);
    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: PosterCacheManager.instance,
      fit: BoxFit.cover,
      width: double.infinity,
      placeholder: (_, _) => const _PosterPlaceholder(),
      errorWidget: (_, _, _) => const _PosterPlaceholder(),
    );
  }
}

class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder();

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

String _statusLabel(TrackStatus s) => switch (s) {
  TrackStatus.watchlist => 'Watchlist',
  TrackStatus.watching => 'Watching',
  TrackStatus.completed => 'Completed',
  TrackStatus.onHold => 'On hold',
  TrackStatus.dropped => 'Dropped',
};
