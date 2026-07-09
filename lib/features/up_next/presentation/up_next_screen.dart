import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/empty_state.dart';
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
          error: (error, _) => EmptyState(
            icon: Icons.cloud_off,
            headline: "Couldn't load upcoming episodes.",
            body: "You're offline, or the metadata service is unreachable.",
            actions: [
              TextButton(
                onPressed: () => ref.invalidate(upcomingThisWeekProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
          data: (entries) => entries.isEmpty
              ? const _NothingUpNext()
              : _DayList(byDay: groupByAirDay(entries)),
        );
  }
}

/// An empty Up Next has two causes and they call for opposite advice: a user
/// tracking no shows needs to add one, while a user tracking twelve just has a
/// quiet week (#35, US-13).
///
/// `trackedShowsProvider` is the same stream `upcomingThisWeek` already
/// awaited, so watching it here costs nothing. Until it resolves, the
/// quiet-week copy is the safe default — telling someone with a full library
/// that they track no shows is the worse of the two wrong answers.
class _NothingUpNext extends ConsumerWidget {
  const _NothingUpNext();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracked = ref.watch(trackedShowsProvider).value;
    if (tracked != null && tracked.isEmpty) {
      return const EmptyState(
        icon: Icons.tv_off_outlined,
        headline: 'No shows tracked yet',
        body:
            'Add a TV show to your library and its next episodes turn up '
            'here.',
      );
    }
    return const EmptyState(
      icon: Icons.upcoming_outlined,
      headline: 'Nothing airing this week',
      body: 'None of your tracked shows has an episode in the next seven days.',
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
