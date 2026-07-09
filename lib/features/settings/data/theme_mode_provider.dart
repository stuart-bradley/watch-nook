import 'package:flutter/material.dart' show ThemeMode;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';

part 'theme_mode_provider.g.dart';

/// Where the chosen [ThemeMode] is persisted. Public so a test can seed it.
const themeModeKey = 'theme_mode';

/// The user's appearance choice (#35, US-14), persisted across restarts.
///
/// Stored as the enum **name**, never its index: `ThemeMode`'s ordering is
/// Flutter's to change, and an index would silently repaint every user's app
/// on an SDK bump. An unknown or corrupt stored value (a downgrade, a
/// hand-edited prefs file) falls back to the default rather than throwing —
/// this runs on the first frame, and a throw here is a boot loop.
///
/// Lives in SharedPreferences, so it is **not** part of `ExportData` and not
/// in the Auto Backup allowlist (the two-data-domains invariant): a restored
/// user gets the default appearance, not a leaked setting.
@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  /// The delivered design intent is dark-leaning; that was `main.dart`'s
  /// hardcoded value before this provider existed.
  static const ThemeMode defaultMode = ThemeMode.dark;

  @override
  ThemeMode build() {
    final stored = ref.watch(sharedPreferencesProvider).getString(themeModeKey);
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == stored,
      orElse: () => defaultMode,
    );
  }

  /// Persists [mode] and repaints the app (`main.dart` watches this provider).
  Future<void> setMode(ThemeMode mode) async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(themeModeKey, mode.name);
    state = mode;
  }
}
