import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_provider.dart';

/// What Watchnook is, in three lines — this replaces the prose paragraph that
/// used to say the same thing less scannably.
/// ponytail: one page, not a swipeable carousel. There is no fourth thing to
/// say, and a carousel is a page indicator plus a controller plus a test.
const _valueProps = <(IconData, String, String)>[
  (
    Icons.playlist_add_check,
    'Track everything',
    'Shows episode by episode, films one tap at a time.',
  ),
  (
    Icons.cloud_off_outlined,
    'Works offline',
    'Your library lives on this phone, not on a server.',
  ),
  (
    Icons.lock_outline,
    'Yours alone',
    'No account, no cloud, no ads. Export it whenever you like.',
  ),
];

/// First-run onboarding (#35, US-13). "Get started" marks onboarding seen and
/// the router redirect sends the user home; the secondary action does the same
/// and then opens the importer, because someone arriving from TV Time already
/// has an export in their downloads folder and nothing else to do first.
///
/// A user restored from Android Auto Backup never sees this screen — `main()`
/// pre-sets the flag before first paint (#32).
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
              const SizedBox(height: WatchnookSpacing.xl),
              for (final (icon, title, body) in _valueProps)
                _ValueProp(icon: icon, title: title, body: body),
              const Spacer(),
              FilledButton(
                onPressed: () => unawaited(_start(ref)),
                child: const Text('Get started'),
              ),
              TextButton(
                onPressed: () => unawaited(_startWithImport(context, ref)),
                child: const Text('I have data to import'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ValueProp extends StatelessWidget {
  const _ValueProp({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: WatchnookSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: WatchnookSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Marks onboarding seen; the router's `refreshListenable` redirects home.
Future<void> _start(WidgetRef ref) =>
    ref.read(onboardingSeenProvider.notifier).markSeen();

/// Marks onboarding seen, *then* pushes the importer on top of the home route
/// the redirect just landed on — so backing out of the import lands in the
/// library, not back at the first-run gate.
Future<void> _startWithImport(BuildContext context, WidgetRef ref) async {
  await _start(ref);
  if (!context.mounted) return;
  unawaited(context.push('/import'));
}
