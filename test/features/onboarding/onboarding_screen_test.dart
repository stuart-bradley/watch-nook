import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';
import 'package:watch_nook/main.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('first run shows onboarding; Get started navigates home and '
      'persists the flag', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          // After "Get started" the redirect lands on the DB-backed library
          // grid; stub it empty so this routing test doesn't hang on a live
          // Drift `.watch()` stream (see library_screen_test for the why).
          libraryGridProvider.overrideWith(
            (ref, filter) => Stream.value(const <LibraryItem>[]),
          ),
        ],
        child: const WatchnookApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Fresh install → the onboarding gate.
    expect(find.text('Get started'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Watchnook'), findsNothing);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    // markSeen → refreshListenable → redirect home; the gate is gone.
    expect(find.widgetWithText(AppBar, 'Watchnook'), findsOneWidget);
    expect(find.text('Get started'), findsNothing);

    // Adversarial: the flag is actually persisted, so a relaunch skips
    // onboarding (not just a transient in-memory state flip).
    expect(prefs.getBool('onboarding_seen'), isTrue);
  });
}
