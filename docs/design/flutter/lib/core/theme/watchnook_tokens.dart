import 'package:flutter/material.dart';

/// Watchnook design tokens.
///
/// Small, dependency-free set: spacing scale, radii, and the signature
/// elevation-0 hairline "rail" card. Drop into `lib/core/theme/`.
class WatchnookSpacing {
  WatchnookSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Default horizontal padding for screen content.
  static const double screen = 16;
}

class WatchnookRadii {
  WatchnookRadii._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;

  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius poster = BorderRadius.all(Radius.circular(md));
  static const BorderRadius thumb = BorderRadius.all(Radius.circular(sm));
}

class WatchnookTokens {
  WatchnookTokens._();

  /// Posters are TMDB 2:3.
  static const double posterAspect = 2 / 3;

  /// Full-width primary CTA height (FilledButton / OutlinedButton).
  static const double buttonHeight = 52;

  static const double navBarHeight = 68;

  /// The Watchnook "rail" card: elevation 0, thin outline, no fill lift.
  static BoxDecoration railCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: cs.surface,
      borderRadius: WatchnookRadii.card,
      border: Border.all(color: cs.outlineVariant, width: 1),
    );
  }

  /// Placeholder shown until the poster image resolves (offline-first).
  static BoxDecoration posterPlaceholder(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: cs.surfaceContainerHigh,
      borderRadius: WatchnookRadii.poster,
      border: Border.all(color: cs.outlineVariant, width: 1),
    );
  }
}
