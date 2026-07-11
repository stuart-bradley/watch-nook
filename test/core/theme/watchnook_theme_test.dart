import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/theme/watchnook_theme.dart';

/// #51 Material You: `WatchnookTheme.resolve` honours a wallpaper-derived
/// scheme only when Dynamic is chosen AND the platform supplies **both**
/// light+dark schemes; otherwise it falls back to the Honey brand scheme. The
/// fallback is the load-bearing case (Android < 12, or no wallpaper colours —
/// which is also what every widget test and non-dynamic device sees).
void main() {
  // Building the theme touches google_fonts, which needs the test binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  final honeyLightPrimary = WatchnookTheme.light.colorScheme.primary;
  final honeyDarkPrimary = WatchnookTheme.dark.colorScheme.primary;

  // A distinctive non-Honey palette so "dynamic applied" is unambiguous.
  const distinctive = Color(0xFF00E5FF);
  final dynLight = ColorScheme.fromSeed(seedColor: distinctive);
  final dynDark = ColorScheme.fromSeed(
    seedColor: distinctive,
    brightness: Brightness.dark,
  );

  test('Dynamic with no platform schemes falls back to Honey', () {
    final (light, dark) = WatchnookTheme.resolve(useDynamicColor: true);
    expect(light.colorScheme.primary, honeyLightPrimary);
    expect(dark.colorScheme.primary, honeyDarkPrimary);
  });

  test('Dynamic with only one scheme still falls back (needs both)', () {
    final (_, dark) = WatchnookTheme.resolve(
      useDynamicColor: true,
      lightDynamic: dynLight,
    );
    expect(dark.colorScheme.primary, honeyDarkPrimary);
  });

  test('Dynamic with both schemes uses the wallpaper palette, not Honey', () {
    final (light, dark) = WatchnookTheme.resolve(
      useDynamicColor: true,
      lightDynamic: dynLight,
      darkDynamic: dynDark,
    );
    expect(light.colorScheme.primary, isNot(honeyLightPrimary));
    expect(dark.colorScheme.primary, isNot(honeyDarkPrimary));
  });

  test('non-Dynamic ignores any supplied schemes (stays Honey)', () {
    final (light, dark) = WatchnookTheme.resolve(
      useDynamicColor: false,
      lightDynamic: dynLight,
      darkDynamic: dynDark,
    );
    expect(light.colorScheme.primary, honeyLightPrimary);
    expect(dark.colorScheme.primary, honeyDarkPrimary);
  });

  test('app-bar title is the larger serif (32sp) with negative tracking', () {
    // Regression for undersized page titles: the serif reads small at title
    // size, so the app-bar style must be headlineLarge (32sp) with the
    // prototype's ≈-0.01em tracking, not a smaller headline step.
    final style = WatchnookTheme.dark.appBarTheme.titleTextStyle;
    expect(style?.fontSize, 32);
    expect(style?.letterSpacing, isNotNull);
    expect(style?.letterSpacing, lessThan(0));
  });
}
