import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/empty_state.dart';
import 'package:watch_nook/core/widgets/poster_placeholder.dart';
import 'package:watch_nook/core/widgets/track_status_ui.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/search/data/search_providers.dart';

/// Debounce before a keystroke fires a network search (#16).
const _debounce = Duration(milliseconds: 350);

/// Search films & shows on the active backend (#16, US-1). Route `/search`.
/// Tapping a hit opens its detail screen — adding happens there, after you've
/// read it.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _timer;
  String _query = '';

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchResultsProvider(_query));
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search films & shows',
            border: InputBorder.none,
          ),
        ),
      ),
      body: results.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const EmptyState(
          icon: Icons.cloud_off,
          headline: "Couldn't search. Check your connection and try again.",
        ),
        data: (items) {
          if (_query.trim().isEmpty) {
            return const EmptyState(
              icon: Icons.search,
              headline: 'Search for a film or show to track.',
            );
          }
          if (items.isEmpty) {
            return EmptyState(
              icon: Icons.sentiment_dissatisfied,
              headline: 'No results',
              body:
                  'Nothing matched "${_query.trim()}". Try another spelling, '
                  'or the original-language title.',
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => _ResultTile(result: items[i]),
          );
        },
      ),
    );
  }
}

class _ResultTile extends ConsumerWidget {
  const _ResultTile({required this.result});

  final MediaSearchResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final year = result.year;
    final kind = result.kind == MediaKind.movie ? 'Film' : 'TV';
    final subtitle = <String>[if (year != null) '$year', kind].join(' · ');
    // Already tracked? Then say so on the row, rather than making the user tap
    // each hit to find out which of the six "Severance"s is the one they have.
    final tracked = ref.watch(trackedItemProvider(identityOfHit(result))).value;
    return ListTile(
      leading: _Poster(path: result.posterPath),
      title: Text(
        result.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle),
      trailing: tracked == null
          ? null
          : _InLibraryBadge(status: tracked.trackStatus),
      onTap: () => unawaited(_openTitle(context, ref, result)),
    );
  }
}

/// "You already have this, and here's where you put it." The status is more use
/// than a bare "in library" tick — it's the thing you'd have opened the row to
/// check.
class _InLibraryBadge extends StatelessWidget {
  const _InLibraryBadge({required this.status});

  final TrackStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'In your library',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: WatchnookSpacing.xs),
          Text(
            status.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the hit's detail screen — a tap **reads**, it never writes (US-1). It
/// used to add on the spot, which meant committing a title to the library
/// having seen nothing but its poster and year.
///
/// Which detail screen depends on whether we already track it: the same
/// `findByIdentity` cascade the add-dedupe uses (imdb → tmdb → tvdb → title +
/// year), so a title already in the library opens its tracked page rather than
/// an "Add to library" page for something you already have.
Future<void> _openTitle(
  BuildContext context,
  WidgetRef ref,
  MediaSearchResult result,
) async {
  // The same answer the badge is showing — one lookup, not two that could
  // disagree.
  final existing = await ref.read(
    trackedItemProvider(identityOfHit(result)).future,
  );
  if (!context.mounted) return;

  if (existing == null) {
    unawaited(context.push('/preview', extra: result));
  } else {
    unawaited(context.push('/title/${existing.id}'));
  }
}

/// Poster thumbnail — offline-safe via the shared [PosterCacheManager], with a
/// placeholder when there's no artwork or it hasn't been cached yet.
class _Poster extends ConsumerWidget {
  const _Poster({required this.path});

  final String? path;

  static const double _width = 40;
  static const double _height = _width / WatchnookTokens.posterAspect;

  // The row's subtitle already reads "2019 · Film", so no TypeBadge here.
  static const _placeholder = PosterPlaceholder(
    width: _width,
    height: _height,
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
        width: _width,
        height: _height,
        fit: BoxFit.cover,
        placeholder: (_, _) => _placeholder,
        errorWidget: (_, _, _) => _placeholder,
      ),
    );
  }
}
