import 'package:flutter/material.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';

/// Small pill that labels a title's type (TV / Film). Colour is never the only
/// signal — it always rides with this text label, per the accessibility rule in
/// `docs/DESIGN_BRIEF.md`.
class TypeBadge extends StatelessWidget {
  const TypeBadge(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(WatchnookRadii.sm),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Poster stand-in shown when a title has no artwork, or before the image
/// resolves. Offline-first: it never touches the network, so every grid and
/// list renders with no metadata source in tests.
///
/// [width] / [height] are required by the thumbnail call sites, where this is
/// handed to `CachedNetworkImage`'s `placeholder` and must reserve the same box
/// as the image it stands in for. The library grid omits both and fills its
/// cell.
class PosterPlaceholder extends StatelessWidget {
  const PosterPlaceholder({
    super.key,
    this.width,
    this.height,
    this.tag,
    this.radius,
  });

  final double? width;
  final double? height;

  /// Optional "TV" / "Film" pill, drawn top-left. Only worth passing where
  /// nothing else on the tile carries the type.
  final String? tag;

  /// Defaults to [WatchnookRadii.poster] via the shared token.
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: WatchnookTokens.posterPlaceholder(
        context,
      ).copyWith(borderRadius: radius),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Center(
            child: Icon(
              Icons.movie_outlined,
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              size: 22,
            ),
          ),
          if (tag != null) Positioned(top: 7, left: 7, child: TypeBadge(tag!)),
        ],
      ),
    );
  }
}
