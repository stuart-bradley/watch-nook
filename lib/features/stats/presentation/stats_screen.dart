import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/empty_state.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';
import 'package:watch_nook/features/stats/presentation/stats_providers.dart';

/// Stats tab (#34, US-12): episodes and hours watched, the current streak, and
/// breakdowns by genre and decade — all folded from the user-owned tables, so
/// every figure renders offline and survives a cache eviction.
///
/// Ported from the delivered design (`docs/design/flutter/lib/features/stats/`),
/// minus its `Scaffold`/`AppBar`: this is a body inside the nav shell (AD-5).
class StatsScreen extends ConsumerWidget {
  /// Creates a [StatsScreen].
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(statsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => const EmptyState(
            icon: Icons.error_outline,
            headline: "Couldn't load your stats.",
          ),
          data: (stats) => stats.isEmpty
              ? const EmptyState(
                  icon: Icons.insights_outlined,
                  headline: 'No stats yet',
                  body:
                      'Mark something watched and your history shows up here.',
                )
              : _StatsBody(stats: stats),
        );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.stats});

  final StatsSnapshot stats;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final decimal = MaterialLocalizations.of(context).formatDecimal;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        WatchnookSpacing.lg,
        WatchnookSpacing.lg,
        WatchnookSpacing.lg,
        WatchnookSpacing.xl,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                value: decimal(stats.episodesWatched),
                label: 'Episodes',
              ),
            ),
            const SizedBox(width: WatchnookSpacing.md),
            Expanded(
              child: _StatCard(
                value: '${decimal(stats.timeWatched.inHours)} h',
                label: 'Watched',
              ),
            ),
          ],
        ),
        const SizedBox(height: WatchnookSpacing.sm),
        Text(
          '${_plural(stats.moviesWatched, 'film')} · '
          '${_plural(stats.rewatches, 'rewatch', 'rewatches')}',
          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: WatchnookSpacing.md),
        Container(
          decoration: WatchnookTokens.railCard(context),
          padding: const EdgeInsets.all(WatchnookSpacing.md),
          child: Row(
            children: [
              Text(
                '${stats.streakDays}',
                style: text.headlineMedium?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: WatchnookSpacing.md),
              Expanded(
                child: Text(
                  stats.streakDays == 0
                      ? 'day streak — watch something today'
                      : 'day streak — keep it going',
                  style: text.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (stats.hasMissingData) ...[
          const SizedBox(height: WatchnookSpacing.md),
          // Honesty, not a backfill: an imported history knows *what* you
          // watched, never how long it ran, and a title added while offline
          // carries neither runtime nor genres. Deliberately doesn't say
          // "imported" — that would be a lie in the offline case.
          // ponytail: a footnote. Enriching the data is its own issue.
          Text(
            'Some titles have no runtime or genre data.',
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: WatchnookSpacing.xl),
        ..._section(context, 'By genre', stats.byGenre),
        ..._section(context, 'By decade', stats.byDecade),
      ],
    );
  }

  /// A heading plus its bars, normalized against the biggest bucket. An empty
  /// breakdown renders nothing at all rather than an empty heading.
  List<Widget> _section(
    BuildContext context,
    String title,
    List<StatBucket> buckets,
  ) {
    if (buckets.isEmpty) return const [];
    final text = Theme.of(context).textTheme;
    final max = buckets.map((b) => b.count).reduce((a, b) => a > b ? a : b);
    return [
      Text(
        title,
        style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: WatchnookSpacing.md),
      for (final bucket in buckets)
        _Bar(
          label: bucket.label,
          count: bucket.count,
          // `max` is the largest count, so it is > 0 whenever a bucket exists.
          fraction: bucket.count / max,
        ),
      const SizedBox(height: WatchnookSpacing.md),
    ];
  }
}

String _plural(int n, String singular, [String? plural]) =>
    '$n ${n == 1 ? singular : plural ?? '${singular}s'}';

class _StatCard extends StatelessWidget {
  const _StatCard({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: WatchnookTokens.railCard(context),
      padding: const EdgeInsets.all(WatchnookSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: text.headlineMedium?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// One breakdown row: label, its **count**, and a bar scaled to the biggest
/// bucket. The delivered mockup printed a percentage here; a percent-of-the-
/// largest-bucket is a number nobody can act on, whereas "62" is the answer to
/// what the user actually asked.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.label,
    required this.count,
    required this.fraction,
  });

  final String label;
  final int count;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: WatchnookSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: text.bodyMedium)),
              Text(
                MaterialLocalizations.of(context).formatDecimal(count),
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(WatchnookRadii.pill),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 7,
              backgroundColor: cs.surfaceContainerHigh,
            ),
          ),
        ],
      ),
    );
  }
}
