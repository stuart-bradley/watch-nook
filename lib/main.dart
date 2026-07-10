import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/import_export/export/export_providers.dart';
import 'package:watch_nook/core/routing/app_router.dart';
import 'package:watch_nook/core/theme/watchnook_theme.dart';
import 'package:watch_nook/features/library/data/tracked_show_sync.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_provider.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';
import 'package:watch_nook/features/settings/data/theme_mode_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Offline-first invariant: never let google_fonts fetch a family over the
  // network at runtime — the only network calls Watchnook makes are the
  // metadata API. Without a bundled asset the platform font renders instead.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Local disk I/O, not network — an acceptable await before runApp.
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );

  // Fresh-install restore from Android Auto Backup (#32, US-11). Awaited — the
  // library grid must not paint empty and then repopulate — but wrapped in
  // `on Object` because a corrupt backup file persists on disk: an unguarded
  // throw here would abort before runApp on *every* launch (boot loop).
  try {
    final backup = await container.read(autoBackupServiceProvider.future);
    if (await backup.restoreIfEmpty()) {
      // A restored user has a full library and must not be shown first-run.
      await prefs.setBool(onboardingSeenKey, true);
    }
  } on Object catch (e, s) {
    debugPrint('backup restore skipped: $e\n$s');
  }

  // ADR-2 / "remote config never blocks boot": first paint uses the synchronous
  // current() (cached-prefs → baked-in). The network refresh is fire-and-forget
  // and self-guarded (`on Object`), so it can never throw onto the boot path.
  unawaited(container.read(remoteConfigServiceProvider).refresh());

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const WatchnookApp(),
    ),
  );

  // Daily tracked-show metadata refresh (Epic B, periodic). Keeps episode
  // counts, show status and next-air dates current so the user never has to hit
  // Settings → Refresh. After runApp, fire-and-forget and self-guarded — an
  // offline launch or a sync failure must never touch the boot path — and
  // throttled to once a day so a launch-heavy day isn't a TMDB-call-heavy one.
  unawaited(_dailyLibrarySync(container, prefs));
}

/// Runs [TrackedShowSync] at most once a day, stamping the run under
/// [lastLibrarySyncKey]. The sync is per-show fault-tolerant and cache-first,
/// so a warm library is near-free; only a genuine throw skips the stamp, so it
/// retries next launch rather than hammering every launch.
Future<void> _dailyLibrarySync(
  ProviderContainer container,
  SharedPreferences prefs,
) async {
  try {
    final raw = prefs.getInt(lastLibrarySyncKey);
    final last = raw == null ? null : DateTime.fromMillisecondsSinceEpoch(raw);
    if (!shouldDailySync(DateTime.now(), last)) return;
    await container.read(trackedShowSyncProvider).refresh();
    await prefs.setInt(
      lastLibrarySyncKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  } on Object catch (e, s) {
    debugPrint('daily library sync skipped: $e\n$s');
  }
}

/// Root widget. The Honey theme in light and dark; which one shows is the
/// user's Settings choice (#35), defaulting to dark — the delivered design
/// intent. Picking **Dynamic** (#51) sources the palette from the wallpaper on
/// Android 12+ ([DynamicColorBuilder]), falling back to Honey elsewhere.
///
/// Stateful only to own the [AppLifecycleListener] that snapshots the backup
/// file on pause (#32) — Android Auto Backup uploads whatever is on disk when
/// it feels like it, so the file has to be current before we leave the
/// foreground.
class WatchnookApp extends ConsumerStatefulWidget {
  const WatchnookApp({super.key});

  @override
  ConsumerState<WatchnookApp> createState() => _WatchnookAppState();
}

class _WatchnookAppState extends ConsumerState<WatchnookApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onPause: () => unawaited(_snapshot()));
  }

  /// Fire-and-forget: a failed backup must never crash the app, and `onPause`
  /// cannot await.
  Future<void> _snapshot() async {
    try {
      final backup = await ref.read(autoBackupServiceProvider.future);
      await backup.snapshot();
    } on Object catch (e, s) {
      debugPrint('backup snapshot failed: $e\n$s');
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(appThemeModeProvider);
    // Material You (#51): DynamicColorBuilder yields the wallpaper schemes on
    // Android 12+ (null elsewhere / in tests); resolve() honours them only when
    // Dynamic is chosen and both are present, else falls back to Honey.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final (light, dark) = WatchnookTheme.resolve(
          useDynamicColor: appearance.usesDynamicColor,
          lightDynamic: lightDynamic,
          darkDynamic: darkDynamic,
        );
        return MaterialApp.router(
          title: 'Watchnook',
          debugShowCheckedModeBanner: false,
          theme: light,
          darkTheme: dark,
          themeMode: appearance.themeMode,
          routerConfig: ref.watch(appRouterProvider),
        );
      },
    );
  }
}
