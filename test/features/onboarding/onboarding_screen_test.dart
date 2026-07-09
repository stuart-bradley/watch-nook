import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/features/import/presentation/import_screen.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_screen.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';
import 'package:watch_nook/main.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Future<SharedPreferences> firstRun() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return SharedPreferences.getInstance();
  }

  Widget app(SharedPreferences prefs) => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      // The redirect lands on the DB-backed library grid; stub it empty so
      // these routing tests don't hang on a live Drift `.watch()` stream (see
      // library_screen_test for the why).
      libraryGridProvider.overrideWith(
        (ref, filter) => Stream.value(const <LibraryItem>[]),
      ),
    ],
    child: const WatchnookApp(),
  );

  testWidgets('first run shows onboarding; Get started navigates home and '
      'persists the flag', (tester) async {
    final prefs = await firstRun();

    await tester.pumpWidget(app(prefs));
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

  testWidgets('the value props tell the user what the app is', (tester) async {
    await tester.pumpWidget(app(await firstRun()));
    await tester.pumpAndSettle();

    expect(find.text('Track everything'), findsOneWidget);
    expect(find.text('Works offline'), findsOneWidget);
    expect(find.text('Yours alone'), findsOneWidget);
  });

  // #35: someone arriving from TV Time has an export in their downloads folder.
  // The secondary action must do *both* things — mark onboarding seen (or the
  // redirect bounces them back to the gate) and open the importer.
  testWidgets('"I have data to import" marks seen and opens the importer', (
    tester,
  ) async {
    final prefs = await firstRun();

    await tester.pumpWidget(app(prefs));
    await tester.pumpAndSettle();

    await tester.tap(find.text('I have data to import'));
    await tester.pumpAndSettle();

    expect(find.byType(ImportScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(prefs.getBool('onboarding_seen'), isTrue);
  });
}
