import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';

/// Up Next tab (#21, US-5): this week's episodes for tracked shows, grouped by
/// air day. Tracked-only filtering lives in [upcomingThisWeekProvider] — this
/// screen just renders its three states, and never a blank crash when the
/// (uncached) upcoming fetch fails offline.
class UpNextScreen extends ConsumerWidget {
  const UpNextScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(upcomingThisWeekProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _Centered(
            icon: Icons.cloud_off,
            message: "Couldn't load upcoming episodes.",
            onRetry: () => ref.invalidate(upcomingThisWeekProvider),
          ),
          data: (entries) => entries.isEmpty
              ? const _Centered(
                  icon: Icons.upcoming_outlined,
                  message: 'No episodes for your shows this week.',
                )
              : _DayList(byDay: groupByAirDay(entries)),
        );
  }
}

/// Day-headed list of upcoming episodes. Both the days and the rows within them
/// arrive chronologically ordered from [groupByAirDay].
class _DayList extends StatelessWidget {
  const _DayList({required this.byDay});

  final Map<DateTime, List<UpcomingEntry>> byDay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatDate = MaterialLocalizations.of(context).formatFullDate;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: WatchnookSpacing.sm),
      children: [
        for (final MapEntry(key: day, value: entries) in byDay.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WatchnookSpacing.screen,
              WatchnookSpacing.lg,
              WatchnookSpacing.screen,
              WatchnookSpacing.xs,
            ),
            child: Text(
              formatDate(day),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          for (final entry in entries) _EpisodeTile(entry: entry),
        ],
      ],
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.entry});

  final UpcomingEntry entry;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(entry.showTitle),
    subtitle: Text(episodeLabel(entry.upcoming.episode)),
    // Detail is a pushed route keyed by the library row id (AD-5) — no direct
    // `Navigator.push`.
    onTap: () => context.push('/title/${entry.itemId}'),
  );
}

class _Centered extends StatelessWidget {
  const _Centered({required this.icon, required this.message, this.onRetry});

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: WatchnookSpacing.md),
          Text(message),
          if (onRetry != null) ...[
            const SizedBox(height: WatchnookSpacing.md),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }
}
