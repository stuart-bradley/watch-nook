import 'package:flutter/material.dart';

import '../theme/watchnook_tokens.dart';

/// Small pill that labels a title's type (TV / Film). Colour is never the
/// only signal — it always rides with this text label (and an icon at the
/// list level), per the accessibility rule in the brief.
class TypeBadge extends StatelessWidget {
  const TypeBadge(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(0.72),
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

/// Poster stand-in shown before the TMDB image resolves (offline-first —
/// the grid must render with no network). Swap the inner Icon for an
/// Image / CachedNetworkImage in production.
class PosterPlaceholder extends StatelessWidget {
  const PosterPlaceholder({super.key, this.tag, this.radius});

  final String? tag;
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: WatchnookTokens.posterPlaceholder(context).copyWith(
        borderRadius: radius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Center(
            child: Icon(
              Icons.movie_outlined,
              color: cs.onSurfaceVariant.withOpacity(0.4),
              size: 22,
            ),
          ),
          if (tag != null)
            Positioned(top: 7, left: 7, child: TypeBadge(tag!)),
        ],
      ),
    );
  }
}
