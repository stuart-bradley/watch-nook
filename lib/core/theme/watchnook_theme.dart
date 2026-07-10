import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';

/// Watchnook theme — "Honey · gold", warm dark-leaning Material 3.
///
/// Type: Newsreader (serif) for display / headline / title-large,
/// Manrope for everything else. Requires `google_fonts` in pubspec.
///
/// Offline-first: `main()` sets `GoogleFonts.config.allowRuntimeFetching =
/// false`, so the app never makes a font network call (only the metadata API
/// may touch the network). Both families are bundled under `assets/fonts/` —
/// google_fonts finds a face by scanning the *asset manifest* for
/// `<Family>-<Variant>.ttf`, so a face it names but that isn't bundled is
/// swallowed by its loader and silently renders Roboto. Every style below
/// resolves to the `regular` variant (the `copyWith(fontWeight:)` calls run
/// *after* the variant is chosen from `base`, so they synthesize weight rather
/// than pull a second face). `test/theme_fonts_test.dart` pins that contract.
class WatchnookTheme {
  WatchnookTheme._();

  static ThemeData get dark => _build(_honeyDark);
  static ThemeData get light => _build(_honeyLight);

  /// The (light, dark) [ThemeData] for the current appearance, given the
  /// platform's Material You schemes (#51). Dynamic colour is honoured only
  /// when [useDynamicColor] is set AND both [lightDynamic]/[darkDynamic] are
  /// supplied (Android 12+); otherwise the Honey brand scheme is used. Pure —
  /// so the fallback is unit-testable without the platform channel. The
  /// Watchnook type + component styling is kept; only the palette changes.
  static (ThemeData light, ThemeData dark) resolve({
    required bool useDynamicColor,
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    if (useDynamicColor && lightDynamic != null && darkDynamic != null) {
      return (
        _build(lightDynamic.harmonized()),
        _build(darkDynamic.harmonized()),
      );
    }
    return (light, dark);
  }

  // ---- Colour schemes ----------------------------------------------------

  static const ColorScheme _honeyDark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFE9BF64),
    onPrimary: Color(0xFF3A2A00),
    primaryContainer: Color(0xFF564409),
    onPrimaryContainer: Color(0xFFFFE08A),
    secondary: Color(0xFFD8C6A0),
    onSecondary: Color(0xFF3A2F12),
    secondaryContainer: Color(0xFF4E4327),
    onSecondaryContainer: Color(0xFFF5E2BC),
    tertiary: Color(0xFFB7CBB0),
    onTertiary: Color(0xFF223423),
    tertiaryContainer: Color(0xFF384B38),
    onTertiaryContainer: Color(0xFFD3E7CB),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: Color(0xFF14110B),
    onSurface: Color(0xFFF2E8D4),
    onSurfaceVariant: Color(0xFFC3B596),
    outline: Color(0xFF8C7E5E),
    outlineVariant: Color(0xFF37301F),
    surfaceDim: Color(0xFF14110B),
    surfaceBright: Color(0xFF3A3122),
    surfaceContainerLowest: Color(0xFF0E0B06),
    surfaceContainerLow: Color(0xFF1B160E),
    surfaceContainer: Color(0xFF1F1910),
    surfaceContainerHigh: Color(0xFF2A2216),
    surfaceContainerHighest: Color(0xFF352C1D),
    inverseSurface: Color(0xFFF2E8D4),
    onInverseSurface: Color(0xFF352C1D),
    inversePrimary: Color(0xFF735B12),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  static const ColorScheme _honeyLight = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF7A5F10),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFFFE08A),
    onPrimaryContainer: Color(0xFF261A00),
    secondary: Color(0xFF6E5F3E),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFF7E3BC),
    onSecondaryContainer: Color(0xFF251A04),
    tertiary: Color(0xFF4E6349),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFD0E8C7),
    onTertiaryContainer: Color(0xFF0C1F0B),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
    surface: Color(0xFFFCF6E6),
    onSurface: Color(0xFF221C0E),
    onSurfaceVariant: Color(0xFF6A5D3F),
    outline: Color(0xFF7C6E4E),
    outlineVariant: Color(0xFFD8C8A3),
    surfaceDim: Color(0xFFDDD6C6),
    surfaceBright: Color(0xFFFCF6E6),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7F0DF),
    surfaceContainer: Color(0xFFF3EAD0),
    surfaceContainerHigh: Color(0xFFEDE3C8),
    surfaceContainerHighest: Color(0xFFE7DDBE),
    inverseSurface: Color(0xFF373021),
    onInverseSurface: Color(0xFFFBEFD6),
    inversePrimary: Color(0xFFE9BF64),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  // ---- Type --------------------------------------------------------------

  static TextTheme _textTheme(ColorScheme cs) {
    final base = ThemeData(brightness: cs.brightness).textTheme;
    final serif = GoogleFonts.newsreaderTextTheme(base);
    final sans = GoogleFonts.manropeTextTheme(base);

    return sans
        .copyWith(
          displayLarge: serif.displayLarge?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          displayMedium: serif.displayMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          displaySmall: serif.displaySmall?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          headlineLarge: serif.headlineLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          headlineMedium: serif.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          headlineSmall: serif.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          titleLarge: serif.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          // titleMedium / titleSmall / body* / label* stay Manrope.
        )
        .apply(bodyColor: cs.onSurface, displayColor: cs.onSurface);
  }

  // ---- ThemeData ---------------------------------------------------------

  static ThemeData _build(ColorScheme cs) {
    final text = _textTheme(cs);

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,

      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // headlineMedium, not headlineSmall: the Newsreader serif reads small
        // at title size, so app-bar/page titles looked undersized on-device.
        titleTextStyle: text.headlineMedium,
      ),

      // Rail card: elevation 0, hairline outline.
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: WatchnookRadii.card,
          side: BorderSide(color: cs.outlineVariant),
        ),
      ),

      // Full-width primary CTA, 52px.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(WatchnookTokens.buttonHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WatchnookRadii.md),
          ),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(WatchnookTokens.buttonHeight),
          side: BorderSide(color: cs.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WatchnookRadii.md),
          ),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cs.primary,
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: cs.surface,
        selectedColor: cs.primary.withValues(alpha: 0.22),
        side: BorderSide(color: cs.outlineVariant),
        shape: const StadiumBorder(),
        showCheckmark: false,
        labelStyle: text.labelLarge,
        secondaryLabelStyle: text.labelLarge?.copyWith(color: cs.primary),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),

      navigationBarTheme: NavigationBarThemeData(
        height: WatchnookTokens.navBarHeight,
        backgroundColor: cs.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        indicatorColor: cs.primary.withValues(alpha: 0.22),
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(
          text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? cs.primary : cs.onSurfaceVariant,
          );
        }),
      ),

      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
