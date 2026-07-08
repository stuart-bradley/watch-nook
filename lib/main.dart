import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/routing/app_router.dart';
import 'package:watch_nook/core/theme/watchnook_theme.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Offline-first invariant: never let google_fonts fetch a family over the
  // network at runtime — the only network calls Watchnook makes are the
  // metadata API. Without a bundled asset the platform font renders instead.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Local disk I/O, not network — an acceptable await before runApp (the
  // boot-loop invariant targets throwing restore/parse/migration paths, which
  // land in M4; the M4 restore should also pre-set the onboarding flag here).
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const WatchnookApp(),
    ),
  );
}

/// Root widget. Fixed Honey theme, dark-leaning by default (the delivered
/// design intent); Material You / dynamic colour is a later polish issue.
class WatchnookApp extends ConsumerWidget {
  const WatchnookApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Watchnook',
      debugShowCheckedModeBanner: false,
      theme: WatchnookTheme.light,
      darkTheme: WatchnookTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
