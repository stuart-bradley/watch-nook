import 'package:flutter/material.dart';

import '../../core/theme/watchnook_tokens.dart';
import '../../core/widgets/poster_placeholder.dart';

/// Up next — this week's airing episodes and upcoming releases for tracked
/// titles, grouped by day. Offline-first: built from cached air dates.
class UpNextScreen extends StatelessWidget {
  const UpNextScreen({super.key});

  static const _days = [
    _Day('Today', 'Tue 8 Jul', [
      _UpNextItem('Nightshade Bay', 'S2E5 · Ashes', '21:00', 'TV'),
      _UpNextItem('The Long Orbit', 'S1E8 · Drift', '22:30', 'TV'),
    ]),
    _Day('Tomorrow', 'Wed 9 Jul', [
      _UpNextItem('Harbour Lights', 'S4E2 · Undertow', '20:00', 'TV'),
    ]),
    _Day('Fri 11 Jul', null, [
      _UpNextItem('Paper Lanterns', 'In cinemas', 'Release', 'Film'),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Up next'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
          const SizedBox(width: WatchnookSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          WatchnookSpacing.lg,
          WatchnookSpacing.xs,
          WatchnookSpacing.lg,
          WatchnookSpacing.xl,
        ),
        children: [
          for (final day in _days) ...[
            _DayHeader(day: day),
            for (final item in day.items) ...[
              _UpNextCard(item: item),
              const SizedBox(height: WatchnookSpacing.sm),
            ],
            const SizedBox(height: WatchnookSpacing.md),
          ],
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});

  final _Day day;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        top: WatchnookSpacing.sm,
        bottom: WatchnookSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            day.label,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (day.date != null) ...[
            const SizedBox(width: WatchnookSpacing.sm),
            Text(
              day.date!,
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _UpNextCard extends StatelessWidget {
  const _UpNextCard({required this.item});

  final _UpNextItem item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: WatchnookTokens.railCard(context),
      padding: const EdgeInsets.all(9),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 66,
            child: PosterPlaceholder(radius: WatchnookRadii.thumb),
          ),
          const SizedBox(width: WatchnookSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: WatchnookSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.when,
                style: text.labelMedium?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Icon(
                item.type == 'Film' ? Icons.movie_outlined : Icons.tv_outlined,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Day {
  const _Day(this.label, this.date, this.items);
  final String label;
  final String? date;
  final List<_UpNextItem> items;
}

class _UpNextItem {
  const _UpNextItem(this.title, this.subtitle, this.when, this.type);
  final String title;
  final String subtitle;
  final String when;
  final String type;
}
