import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';
import 'package:watch_nook/main.dart';

void main() {
  // Mirror main(): never fetch fonts over the network in a test.
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('a returning user boots straight to the Watchnook home', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'onboarding_seen': true,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          // The app now boots on Up Next; stub its data (and the library grid)
          // with synchronous empties so this boot/routing test doesn't hang on a
          // live Drift `.watch()` stream (see library_screen_test for the why).
          libraryGridProvider.overrideWith(
            (ref, filter) => Stream.value(const <LibraryItem>[]),
          ),
          trackedShowsProvider.overrideWith(
            (ref) => Stream.value(const <TrackedShow>[]),
          ),
          upcomingThisWeekProvider.overrideWith(
            (ref) async => const <UpcomingEntry>[],
          ),
        ],
        child: const WatchnookApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Seen onboarding → router lands on home, not the onboarding gate.
    expect(find.widgetWithText(AppBar, 'Watchnook'), findsOneWidget);
    expect(find.text('Get started'), findsNothing);

    // Adversarial: debug banner off, and the app drives a router — leaving both
    // `home:` and `routerConfig:` wired at once throws at build.
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.debugShowCheckedModeBanner, isFalse);
    expect(app.routerConfig, isNotNull);
    expect(app.home, isNull);
  });
}
