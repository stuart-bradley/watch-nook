import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_provider.dart';

/// First-run onboarding: a single welcome page. "Get started" marks onboarding
/// seen; the router redirect then sends the user home. No account, no sign-in.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(WatchnookSpacing.screen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Icon(
                Icons.movie_outlined,
                size: 64,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: WatchnookSpacing.xl),
              Text(
                'Welcome to Watchnook',
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: WatchnookSpacing.md),
              Text(
                'Track your shows and movies on your phone. No account, no '
                'cloud, no ads — everything stays with you.',
                style: theme.textTheme.bodyLarge,
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => unawaited(
                  ref.read(onboardingSeenProvider.notifier).markSeen(),
                ),
                child: const Text('Get started'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
