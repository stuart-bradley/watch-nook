import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/empty_state.dart';
import 'package:watch_nook/core/widgets/poster_placeholder.dart';
import 'package:watch_nook/core/widgets/track_status_ui.dart';
import 'package:watch_nook/features/search/data/search_providers.dart';

/// Debounce before a keystroke fires a network search (#16).
const _debounce = Duration(milliseconds: 350);

/// Search films & shows on the active backend and add a hit to the library
/// with a chosen status (#16, US-1). Route `/search`.
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
    return ListTile(
      leading: _Poster(path: result.posterPath),
      title: Text(
        result.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle),
      onTap: () => unawaited(_pickStatusAndAdd(context, ref, result)),
    );
  }
}

/// Opens the status picker; on a choice, snapshots + adds the title and
/// confirms with a SnackBar.
Future<void> _pickStatusAndAdd(
  BuildContext context,
  WidgetRef ref,
  MediaSearchResult result,
) async {
  final status = await showTrackStatusPicker(context);
  if (status == null) return;

  final added = await addToLibrary(
    source: ref.read(activeMetadataSourceProvider),
    sourceKind: metadataSourceKindOf(ref.read(activeMetadataBackendProvider)),
    dao: ref.read(libraryDaoProvider),
    result: result,
    status: status,
  );

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Added "${added.title}" to ${status.label}'),
    ),
  );
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
