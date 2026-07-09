import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/features/detail/presentation/detail_screen.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_provider.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_screen.dart';
import 'package:watch_nook/features/search/presentation/search_screen.dart';
import 'package:watch_nook/features/up_next/presentation/up_next_screen.dart';

part 'app_router.g.dart';

/// App routes. The bottom-nav shell (AD-5) is the root — a `Library` tab (`/`,
/// the grid #17) and an `Up Next` tab (`/up-next`, #21). Onboarding is the
/// first-run gate; search is a pushed route reachable from the shell app bar.
/// Exposed so a test can mount the router at a chosen location.
final List<RouteBase> appRoutes = <RouteBase>[
  StatefulShellRoute.indexedStack(
    builder: (context, state, navigationShell) =>
        _ShellScaffold(navigationShell: navigationShell),
    branches: [
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
            path: '/up-next',
            builder: (context, state) => const UpNextScreen(),
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
    // `id` is a `LibraryItems` row id — detail is only reachable for a tracked
    // title. A non-numeric or unknown id renders the "not in your library"
    // state rather than throwing.
    path: '/title/:id',
    builder: (context, state) => DetailScreen(
      itemId: int.tryParse(state.pathParameters['id'] ?? '') ?? -1,
    ),
  ),
];

/// The bottom-nav shell (AD-5): a shared app bar (title + Search action) over
/// the active tab, with a [NavigationBar] switching between Library and Up
/// Next. Navigation goes through `navigationShell` (go_router) — no direct
/// `Navigator.push`.
class _ShellScaffold extends StatelessWidget {
  const _ShellScaffold({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watchnook'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => context.push('/search'),
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
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            selectedIcon: Icon(Icons.video_library),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.upcoming_outlined),
            selectedIcon: Icon(Icons.upcoming),
            label: 'Up Next',
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
  if (seen && atOnboarding) return '/';
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
