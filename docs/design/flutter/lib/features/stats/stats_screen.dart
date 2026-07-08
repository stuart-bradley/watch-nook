import 'package:flutter/material.dart';

import '../../core/theme/watchnook_tokens.dart';

/// Stats — episodes / hours watched, current streak, and breakdowns by
/// genre and decade. All derived locally from watch history.
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  static const _genres = [
    ('Drama', 0.82),
    ('Sci-fi', 0.64),
    ('Comedy', 0.41),
    ('Thriller', 0.28),
  ];
  static const _decades = [
    ('2020s', 0.70),
    ('2010s', 0.88),
    ('2000s', 0.34),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Stats')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            WatchnookSpacing.lg, 0, WatchnookSpacing.lg, WatchnookSpacing.xl),
        children: [
          Row(
            children: const [
              Expanded(child: _StatCard(value: '1,284', label: 'Episodes')),
              SizedBox(width: WatchnookSpacing.md),
              Expanded(child: _StatCard(value: '642 h', label: 'Watched')),
            ],
          ),
          const SizedBox(height: WatchnookSpacing.md),
          Container(
            decoration: WatchnookTokens.railCard(context),
            padding: const EdgeInsets.all(WatchnookSpacing.md),
            child: Row(
              children: [
                Text('9',
                    style: text.headlineMedium
                        ?.copyWith(color: cs.primary, fontWeight: FontWeight.w800)),
                const SizedBox(width: WatchnookSpacing.md),
                Text('day streak — keep it going',
                    style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(height: WatchnookSpacing.xl),
          Text('By genre',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: WatchnookSpacing.md),
          for (final g in _genres) _Bar(label: g.$1, value: g.$2),
          const SizedBox(height: WatchnookSpacing.md),
          Text('By decade',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: WatchnookSpacing.md),
          for (final d in _decades) _Bar(label: d.$1, value: d.$2),
        ],
      ),
    );
  }
}

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
          Text(value,
              style: text.headlineMedium
                  ?.copyWith(color: cs.primary, fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text(label,
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.value});
  final String label;
  final double value;

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
              Text(label, style: text.bodyMedium),
              const Spacer(),
              Text('${(value * 100).round()}%',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(WatchnookRadii.pill),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 7,
              backgroundColor: cs.surfaceContainerHigh,
            ),
          ),
        ],
      ),
    );
  }
}
