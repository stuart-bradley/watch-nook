import 'package:flutter/material.dart' show ThemeMode;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';

part 'theme_mode_provider.g.dart';

/// Where the chosen appearance is persisted. Public so a test can seed it.
const themeModeKey = 'theme_mode';

/// The user's appearance choice (#35 / #51 Material You). Extends the original
/// System/Light/Dark with **Dynamic** — wallpaper-derived Material You colours.
///
/// The `system`/`light`/`dark` names match the old `ThemeMode` values, so a
/// value written by the previous picker still resolves (back-compatible). The
/// `dynamic` case is spelled `dynamicColor` because `dynamic` is a Dart
/// built-in identifier and can't name a member.
enum AppAppearance {
  system,
  light,
  dark,
  dynamicColor;

  /// Brightness for `MaterialApp`. Dynamic follows the system brightness.
  ThemeMode get themeMode => switch (this) {
    AppAppearance.light => ThemeMode.light,
    AppAppearance.dark => ThemeMode.dark,
    AppAppearance.system || AppAppearance.dynamicColor => ThemeMode.system,
  };

  /// Whether to source colours from the wallpaper (Material You). Only takes
  /// effect when the platform actually supplies a dynamic scheme (Android 12+);
  /// otherwise the app falls back to the Honey brand scheme.
  bool get usesDynamicColor => this == AppAppearance.dynamicColor;
}

/// The user's appearance choice (#35, US-14), persisted across restarts.
///
/// Stored as the enum **name**, never its index: enum ordering is Flutter's to
/// change, and an index would silently repaint every user's app on an SDK bump.
/// An unknown or corrupt stored value (a downgrade, a hand-edited prefs file)
/// falls back to the default rather than throwing — this runs on the first
/// frame, and a throw here is a boot loop.
///
/// Lives in SharedPreferences, so it is **not** part of `ExportData` and not in
/// the Auto Backup allowlist (the two-data-domains invariant): a restored user
/// gets the default appearance, not a leaked setting.
@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  /// The delivered design intent is dark-leaning.
  static const AppAppearance defaultAppearance = AppAppearance.dark;

  @override
  AppAppearance build() {
    final stored = ref.watch(sharedPreferencesProvider).getString(themeModeKey);
    return AppAppearance.values.firstWhere(
      (a) => a.name == stored,
      orElse: () => defaultAppearance,
    );
  }

  /// Persists [appearance] and repaints the app (`main.dart` watches this).
  Future<void> setMode(AppAppearance appearance) async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(themeModeKey, appearance.name);
    state = appearance;
  }
}
