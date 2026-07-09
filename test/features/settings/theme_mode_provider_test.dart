import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';
import 'package:watch_nook/features/settings/data/theme_mode_provider.dart';

/// #35 / US-14: the appearance choice survives a restart.
///
/// Adversarial framing: the interesting input is not `'light'`, it is the value
/// nobody wrote — a downgrade, a hand-edited prefs file, a future build that
/// added a fourth mode. `ThemeMode.values.byName('purple')` throws
/// `ArgumentError`, and this provider is read on the first frame, so a throw
/// here is a boot loop (CLAUDE.md, Dart gotchas). It must degrade, not throw.
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
    expect(container.read(appThemeModeProvider), ThemeMode.dark);
  });

  test('a stored mode is restored', () async {
    final container = await containerWith({themeModeKey: 'light'});
    expect(container.read(appThemeModeProvider), ThemeMode.light);
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
        .setMode(ThemeMode.light);

    expect(container.read(appThemeModeProvider), ThemeMode.light);
    // The *name*, not the index — an index would repaint every user's app the
    // day Flutter reorders the enum.
    expect(prefs.getString(themeModeKey), 'light');
  });

  test('a corrupt stored value falls back to dark, not a throw', () async {
    final container = await containerWith({themeModeKey: 'purple'});
    expect(container.read(appThemeModeProvider), ThemeMode.dark);
  });

  test('every ThemeMode round-trips through prefs', () async {
    for (final mode in ThemeMode.values) {
      final container = await containerWith({themeModeKey: mode.name});
      expect(container.read(appThemeModeProvider), mode, reason: mode.name);
    }
  });
}
