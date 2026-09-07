import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/poster_placeholder.dart';

/// Every remote image in the app.
///
/// The rules are the same everywhere and easy to get wrong one call site at a
/// time, so they live here once:
///
/// - a null reference **never touches the network** — it renders a
///   placeholder, so every grid and list works offline and in tests with no
///   metadata source;
/// - a reference minted by a backend that is no longer the active one renders
///   the same placeholder. Paths are backend-relative and only their own
///   source can turn one into a URL, so resolving a TheTVDB path through TMDB
///   builds a URL that 404s or, worse, loads an unrelated image. A relink
///   rewrites ids but not `posterPath`, and the periodic sync only heals TV
///   rows, so a stranded movie poster never recovers on its own — the
///   placeholder is the honest answer until it does;
/// - the path is otherwise resolved through the active source, which knows its
///   own URL shape (TMDB size buckets vs TheTVDB's full URLs);
/// - images go through [PosterCacheManager], not the default cache, so posters
///   share one disk budget and survive a restart;
/// - a failed load falls back to the same placeholder as an empty one. A broken
///   image is not an error state worth showing a user.
///
/// Three shapes, three constructors: the call site picks one and passes an
/// [ArtworkRef].
/// Geometry, radius, image size and placeholder are this module's business, not
/// the caller's.
class RemoteImage extends ConsumerWidget {
  /// A 40dp list thumbnail — search results, import candidates, Up Next rows.
  const RemoteImage.thumbnail({required this.artwork, super.key})
    : _shape = _Shape.thumbnail,
      tag = null;

  /// A library grid card: fills its cell, and carries a "TV"/"Film" [tag] on
  /// the placeholder because a card has no subtitle to say so.
  const RemoteImage.card({
    required this.artwork,
    required this.tag,
    super.key,
  }) : _shape = _Shape.card;

  /// The 16:9 detail-screen backdrop.
  const RemoteImage.backdrop({required this.artwork, super.key})
    : _shape = _Shape.backdrop,
      tag = null;

  /// The artwork and the backend that minted it, or null when the title has
  /// none.
  final ArtworkRef? artwork;

  /// "TV" / "Film" pill for the card placeholder.
  final String? tag;

  final _Shape _shape;

  /// One definition of the thumbnail box, rather than the same two lines
  /// repeated in each list screen.
  static const double thumbnailWidth = 40;

  /// Height that keeps [thumbnailWidth] at the poster aspect ratio.
  static const double thumbnailHeight =
      thumbnailWidth / WatchnookTokens.posterAspect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artwork = this.artwork;
    final placeholder = _placeholder();

    if (artwork == null) return placeholder;
    // The stranded case. Only the source that minted a path can resolve it.
    if (artwork.kind != ref.watch(activeMetadataKindProvider)) {
      return placeholder;
    }

    final url = ref
        .watch(activeMetadataSourceProvider)
        .imageUrl(artwork.path, _shape.imageSize);

    final image = CachedNetworkImage(
      imageUrl: url,
      cacheManager: PosterCacheManager.instance,
      fit: BoxFit.cover,
      width: switch (_shape) {
        _Shape.thumbnail => thumbnailWidth,
        _Shape.card => double.infinity,
        _Shape.backdrop => null,
      },
      height: _shape == _Shape.thumbnail ? thumbnailHeight : null,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );

    return switch (_shape) {
      _Shape.thumbnail => ClipRRect(
        borderRadius: WatchnookRadii.thumb,
        child: image,
      ),
      _Shape.card => image,
      _Shape.backdrop => AspectRatio(aspectRatio: 16 / 9, child: image),
    };
  }

  Widget _placeholder() => switch (_shape) {
    _Shape.thumbnail => const PosterPlaceholder(
      width: thumbnailWidth,
      height: thumbnailHeight,
      radius: WatchnookRadii.thumb,
    ),
    _Shape.card => PosterPlaceholder(tag: tag),
    _Shape.backdrop => const AspectRatio(
      aspectRatio: 16 / 9,
      child: _BackdropPlaceholder(),
    ),
  };
}

enum _Shape {
  thumbnail(ImageSize.small),
  card(ImageSize.medium),
  backdrop(ImageSize.large);

  const _Shape(this.imageSize);

  final ImageSize imageSize;
}

/// The backdrop's own stand-in: full-bleed, no rounded corners, no type badge —
/// [PosterPlaceholder]'s poster geometry would be wrong at 16:9.
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
