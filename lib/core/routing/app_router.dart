import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/features/home/presentation/home_screen.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_provider.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_screen.dart';

part 'app_router.g.dart';

/// App routes. Home is the root; onboarding is the first-run gate. Exposed so a
/// test can mount the router at a chosen location.
final List<RouteBase> appRoutes = <RouteBase>[
  GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
  GoRoute(
    path: '/onboarding',
    builder: (context, state) => const OnboardingScreen(),
  ),
];

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
