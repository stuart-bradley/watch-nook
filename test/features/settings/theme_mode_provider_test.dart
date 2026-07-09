import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';
import 'package:watch_nook/features/settings/data/theme_mode_provider.dart';

/// #35 / #51 / US-14: the appearance choice survives a restart.
///
/// Adversarial framing: the interesting input is not `'light'`, it is the value
/// nobody wrote — a downgrade, a hand-edited prefs file, an older build that
/// never had Dynamic. `AppAppearance.values.byName('purple')` throws
/// `ArgumentError`, and this provider is read on the first frame, so a throw
/// here is a boot loop. It must degrade, not throw.
void main() {
  Future<ProviderContainer> containerWith(Map<String, Object> stored) async {
    SharedPreferences.setMockInitialValues(stored);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('an empty prefs store defaults to dark', () async {
    final container = await containerWith({});
    expect(container.read(appThemeModeProvider), AppAppearance.dark);
  });

  test('a stored appearance is restored', () async {
    final container = await containerWith({themeModeKey: 'light'});
    expect(container.read(appThemeModeProvider), AppAppearance.light);
  });

  test('a value written by the old ThemeMode picker still resolves', () async {
    // Back-compat: 'system'/'light'/'dark' names are shared with ThemeMode.
    final container = await containerWith({themeModeKey: 'system'});
    expect(container.read(appThemeModeProvider), AppAppearance.system);
  });

  test('setMode persists the enum name and flips the state', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await container
        .read(appThemeModeProvider.notifier)
        .setMode(AppAppearance.dynamicColor);

    expect(container.read(appThemeModeProvider), AppAppearance.dynamicColor);
    // The *name*, not the index — an index would repaint every user's app the
    // day the enum is reordered.
    expect(prefs.getString(themeModeKey), 'dynamicColor');
  });

  test('a corrupt stored value falls back to dark, not a throw', () async {
    final container = await containerWith({themeModeKey: 'purple'});
    expect(container.read(appThemeModeProvider), AppAppearance.dark);
  });

  test('every appearance round-trips through prefs', () async {
    for (final appearance in AppAppearance.values) {
      final container = await containerWith({themeModeKey: appearance.name});
      expect(
        container.read(appThemeModeProvider),
        appearance,
        reason: appearance.name,
      );
    }
  });

  test('themeMode + usesDynamicColor map correctly', () {
    expect(AppAppearance.system.themeMode, ThemeMode.system);
    expect(AppAppearance.light.themeMode, ThemeMode.light);
    expect(AppAppearance.dark.themeMode, ThemeMode.dark);
    // Dynamic follows the system brightness.
    expect(AppAppearance.dynamicColor.themeMode, ThemeMode.system);

    expect(AppAppearance.dynamicColor.usesDynamicColor, isTrue);
    expect(AppAppearance.system.usesDynamicColor, isFalse);
    expect(AppAppearance.dark.usesDynamicColor, isFalse);
  });
}
