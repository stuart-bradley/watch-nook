import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/detail/presentation/detail_screen.dart';
import 'package:watch_nook/features/import/presentation/import_screen.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_provider.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_screen.dart';
import 'package:watch_nook/features/search/presentation/search_screen.dart';
import 'package:watch_nook/features/settings/presentation/settings_screen.dart';
import 'package:watch_nook/features/stats/presentation/stats_screen.dart';
import 'package:watch_nook/features/up_next/presentation/up_next_screen.dart';

part 'app_router.g.dart';

/// App routes. The bottom-nav shell (AD-5) is the root — an `Up Next` tab
/// (`/up-next`, #21) **first** (the watch queue is the most-used view, so the
/// app opens here), then a `Library` tab (`/`, the grid #17) and a `Stats` tab
/// (`/stats`, #34). Onboarding is the first-run gate; search and settings are
/// pushed routes reachable from the shell app bar.
///
/// The branch order and the [NavigationBar] destinations are index-aligned —
/// reorder both together or the wrong screen shows under the wrong tab.
/// Exposed so a test can mount the router at a chosen location.
final List<RouteBase> appRoutes = <RouteBase>[
  StatefulShellRoute.indexedStack(
    builder: (context, state, navigationShell) =>
        _ShellScaffold(navigationShell: navigationShell),
    branches: [
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/up-next',
            builder: (context, state) => const UpNextScreen(),
          ),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const LibraryScreen(),
          ),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/stats',
            builder: (context, state) => const StatsScreen(),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: '/onboarding',
    builder: (context, state) => const OnboardingScreen(),
  ),
  GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
  GoRoute(
    path: '/settings',
    builder: (context, state) => const SettingsScreen(),
  ),
  // Reachable from Settings → Import, and from the first-run onboarding page.
  GoRoute(path: '/import', builder: (context, state) => const ImportScreen()),
  GoRoute(
    // `id` is a `LibraryItems` row id — this route is the **tracked** detail
    // screen. A non-numeric or unknown id renders the "not in your library"
    // state rather than throwing.
    path: '/title/:id',
    builder: (context, state) => DetailScreen(
      itemId: int.tryParse(state.pathParameters['id'] ?? '') ?? -1,
    ),
  ),
  GoRoute(
    // The **untracked** detail screen: search pushes a hit here so you can read
    // a title before adding it. The hit rides in `extra` (it renders instantly
    // from the search fields while the details fetch streams in), which is
    // push-only by design — it does not survive a deep link or a process
    // restore. `is`, not `as`: a bare cast on a missing/foreign `extra` throws
    // a `TypeError`; this degrades to the screen's not-found notice instead.
    path: '/preview',
    builder: (context, state) {
      final extra = state.extra;
      return DetailScreen(
        result: extra is MediaSearchResult ? extra : null,
      );
    },
  ),
];

/// The bottom-nav shell (AD-5): a shared app bar (title + Search and Settings
/// actions) over the active tab, with a [NavigationBar] switching between
/// Library, Up Next and Stats. Navigation goes through `navigationShell`
/// (go_router) — no direct `Navigator.push`.
class _ShellScaffold extends StatelessWidget {
  const _ShellScaffold({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Per-screen title, index-aligned with the NavigationDestination order
        // below (Up Next=0, Library=1, Stats=2) — matches the prototype, which
        // titles each screen rather than showing a single static app name.
        title: Text(
          const ['Up Next', 'Library', 'Stats'][navigationShell.currentIndex],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        // goBranch keeps each tab's own navigation stack (indexed-stack).
        onDestinationSelected: (i) => navigationShell.goBranch(
          i,
          initialLocation: i == navigationShell.currentIndex,
        ),
        // Index-aligned with the branch order above.
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.upcoming_outlined),
            selectedIcon: Icon(Icons.upcoming),
            label: 'Up Next',
          ),
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            selectedIcon: Icon(Icons.video_library),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Stats',
          ),
        ],
      ),
    );
  }
}

/// Pure first-run redirect decision, gated on the onboarding flag **alone** (no
/// library provider until M2). Extracted from the provider so the branch logic
/// — including the no-redirect-loop case — is unit-tested without mounting a
/// router.
///
/// M4: a backup restore should pre-set the flag (`markSeen`) before first paint
/// so a restored user skips onboarding.
String? onboardingRedirect({required bool seen, required String location}) {
  final atOnboarding = location == '/onboarding';
  if (!seen && !atOnboarding) return '/onboarding';
  // Finishing onboarding lands on Up Next — the app's home tab.
  if (seen && atOnboarding) return '/up-next';
  return null;
}

/// The app's router. The redirect gates first-run onboarding; everything else
/// lives in [appRoutes]. Exposed as a provider so the redirect can read the
/// onboarding flag, and re-runs when the flag flips (finishing onboarding
/// navigates home).
@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  final refresh = _OnboardingRefresh(ref);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    // Boot on Up Next (the watch queue), not Library.
    initialLocation: '/up-next',
    routes: appRoutes,
    refreshListenable: refresh,
    redirect: (context, state) => onboardingRedirect(
      seen: ref.read(onboardingSeenProvider),
      location: state.matchedLocation,
    ),
  );
}

/// Re-runs the router redirect when onboarding completion changes — so
/// finishing onboarding navigates away from `/onboarding`.
class _OnboardingRefresh extends ChangeNotifier {
  _OnboardingRefresh(Ref ref) {
    ref.listen(onboardingSeenProvider, (_, _) => notifyListeners());
  }
}
