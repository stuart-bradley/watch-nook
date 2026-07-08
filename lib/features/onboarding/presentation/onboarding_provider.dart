import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';

part 'onboarding_provider.g.dart';

const _key = 'onboarding_seen';

/// Whether the user has completed first-run onboarding. The router redirect
/// gates `/onboarding` on this flag alone (no library provider until M2).
@Riverpod(keepAlive: true)
class OnboardingSeen extends _$OnboardingSeen {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(_key) ?? false;
  }

  /// Marks onboarding as seen and persists the flag. The router's
  /// refreshListenable reacts to the state change and redirects home.
  Future<void> markSeen() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(_key, true);
    state = true;
  }
}
