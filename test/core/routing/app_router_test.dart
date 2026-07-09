import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/routing/app_router.dart';

void main() {
  group('onboardingRedirect', () {
    test('a never-onboarded user away from onboarding is sent there', () {
      expect(onboardingRedirect(seen: false, location: '/'), '/onboarding');
    });

    // Adversarial: the redirect must not fire again once already at the gate,
    // or the router loops forever.
    test('a never-onboarded user already at the gate is left alone', () {
      expect(onboardingRedirect(seen: false, location: '/onboarding'), isNull);
    });

    test('a returning user is bounced off the onboarding gate to home', () {
      expect(onboardingRedirect(seen: true, location: '/onboarding'), '/');
    });

    test('a returning user anywhere else is left alone', () {
      expect(onboardingRedirect(seen: true, location: '/'), isNull);
    });
  });
}
