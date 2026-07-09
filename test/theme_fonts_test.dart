import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/theme/watchnook_theme.dart';

/// The design is "applied" only if Newsreader + Manrope actually render (#36).
///
/// `main()` sets `GoogleFonts.config.allowRuntimeFetching = false`, so a face
/// that isn't bundled throws *inside* google_fonts' loader, where the exception
/// is caught and merely printed — the app then silently falls back to Roboto
/// and every check stays green. That failure is invisible to a normal widget
/// test, so it gets pinned here.
///
/// google_fonts resolves a bundled face by scanning the **asset manifest** for
/// a file whose name ends with `<Family>-<Variant>.ttf` (see its
/// `_findFamilyWithVariantAssetPath`) — hence `assets:` in pubspec, not
/// `fonts:`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Inverse of google_fonts' `GoogleFontsVariant.toApiFilenamePart()`:
  /// the `Manrope_500` half of a `fontFamily` maps to `Manrope-Medium.ttf`.
  String fileNamePart(String variant) {
    const weightNames = <String, String>{
      '100': 'Thin',
      '200': 'ExtraLight',
      '300': 'Light',
      '400': 'Regular',
      '500': 'Medium',
      '600': 'SemiBold',
      '700': 'Bold',
      '800': 'ExtraBold',
      '900': 'Black',
    };

    final italic = variant.endsWith('italic');
    final weight = variant.replaceAll('italic', '');
    final key = weight.isEmpty || weight == 'regular' ? '400' : weight;
    final name = weightNames[key];
    if (name == null) {
      throw StateError('unmapped google_fonts variant: $variant');
    }
    if (name == 'Regular') return italic ? 'Italic' : 'Regular';
    return italic ? '${name}Italic' : name;
  }

  /// Every face the built theme *names*. Derived from the theme rather than
  /// hard-coded, so re-weighting a style (which silently re-resolves the
  /// variant google_fonts loads) fails here instead of shipping as Roboto.
  Set<String> requiredFontAssets() {
    final assets = <String>{};
    final themes = <ThemeData>[WatchnookTheme.dark, WatchnookTheme.light];
    for (final theme in themes) {
      final t = theme.textTheme;
      final styles = <TextStyle?>[
        t.displayLarge,
        t.displayMedium,
        t.displaySmall,
        t.headlineLarge,
        t.headlineMedium,
        t.headlineSmall,
        t.titleLarge,
        t.titleMedium,
        t.titleSmall,
        t.bodyLarge,
        t.bodyMedium,
        t.bodySmall,
        t.labelLarge,
        t.labelMedium,
        t.labelSmall,
      ];
      for (final style in styles) {
        final family = style?.fontFamily;
        if (family == null) continue;
        // google_fonts names the style `<Family>_<variant>`.
        final split = family.split('_');
        expect(
          split.length,
          2,
          reason:
              '$family is not a google_fonts family — the theme lost its '
              'custom type and is rendering the platform font',
        );
        assets.add('${split.first}-${fileNamePart(split.last)}.ttf');
      }
    }
    return assets;
  }

  test('the theme only names Newsreader and Manrope', () {
    final assets = requiredFontAssets();
    final families = assets.map((a) => a.split('-').first).toSet();

    expect(families, <String>{'Newsreader', 'Manrope'});
  });

  test('every font face the theme names is bundled as an asset', () async {
    final required = requiredFontAssets();
    expect(required, isNotEmpty);

    for (final name in required) {
      final path = 'assets/fonts/$name';
      // rootBundle — not dart:io — because the asset manifest is exactly what
      // google_fonts queries at runtime. A file present on disk but missing
      // from pubspec's `assets:` would pass a File.existsSync check and still
      // render Roboto on device.
      await expectLater(
        rootBundle.load(path),
        completes,
        reason:
            '$path is missing from the asset bundle; google_fonts will '
            'fall back to Roboto with allowRuntimeFetching = false',
      );
    }
  });
}
