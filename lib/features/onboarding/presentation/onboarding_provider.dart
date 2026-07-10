import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';

part 'onboarding_provider.g.dart';

/// Public because `main()` sets it directly after an auto-backup restore (#32):
/// a restored user already has a library and must never see first-run.
const onboardingSeenKey = 'onboarding_seen';

/// Whether the user has completed first-run onboarding. The router redirect
/// gates `/onboarding` on this flag alone (no library provider until M2).
@Riverpod(keepAlive: true)
class OnboardingSeen extends _$OnboardingSeen {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(onboardingSeenKey) ?? false;
  }

  /// Marks onboarding as seen and persists the flag. The router's
  /// refreshListenable reacts to the state change and redirects home.
  Future<void> markSeen() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(onboardingSeenKey, true);
    state = true;
  }

  /// Clears the flag → the app returns to first-run. Used by the GDPR
  /// delete-all so a wipe feels like a fresh install; the router redirect
  /// reacts and sends the user back to `/onboarding`.
  Future<void> reset() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(onboardingSeenKey, false);
    state = false;
  }
}
