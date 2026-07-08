import 'package:flutter/material.dart';

import '../../core/theme/watchnook_tokens.dart';
import '../../core/widgets/poster_placeholder.dart';

/// Library — filterable grid of tracked titles.
///
/// Renders entirely from local data (offline-first). Fast filtering via a
/// horizontal chip rail; posters use the 2:3 rail-card grid. Wire the mock
/// `setState` filtering to Riverpod in production.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _filters = [
    'All',
    'TV',
    'Films',
    'Watching',
    'Watchlist',
    'Completed',
    'On-hold',
    'Dropped',
  ];

  static const _titles = [
    _LibraryItem('Nightshade Bay', 'S2E4 · 3 left', 'TV'),
    _LibraryItem('The Long Orbit', 'S1E7 · airing', 'TV'),
    _LibraryItem('Paper Lanterns', 'Watchlist', 'Film'),
    _LibraryItem('Verdant', 'S3E1 · 9 left', 'TV'),
    _LibraryItem('Harbour Lights', 'S4E2 · 12 left', 'TV'),
    _LibraryItem('Slow Water', 'Completed', 'Film'),
  ];

  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
          const SizedBox(width: WatchnookSpacing.xs),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FilterRail(
            filters: _filters,
            selected: _selected,
            onSelected: (i) => setState(() => _selected = i),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const spacing = WatchnookSpacing.md;
                final cellWidth =
                    (constraints.maxWidth - WatchnookSpacing.lg * 2 - spacing) /
                        2;
                final extent =
                    cellWidth / WatchnookTokens.posterAspect + 46;
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    WatchnookSpacing.lg,
                    0,
                    WatchnookSpacing.lg,
                    WatchnookSpacing.lg,
                  ),
                  gridDelegate:
                      SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: WatchnookSpacing.lg,
                    mainAxisExtent: extent,
                  ),
                  itemCount: _titles.length,
                  itemBuilder: (context, i) => _PosterCard(item: _titles[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterRail extends StatelessWidget {
  const _FilterRail({
    required this.filters,
    required this.selected,
    required this.onSelected,
  });

  final List<String> filters;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: WatchnookSpacing.lg),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: WatchnookSpacing.sm),
        itemBuilder: (context, i) => Center(
          child: FilterChip(
            label: Text(filters[i]),
            selected: selected == i,
            onSelected: (_) => onSelected(i),
          ),
        ),
      ),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({required this.item});

  final _LibraryItem item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: WatchnookRadii.poster,
      onTap: () => Navigator.of(context).pushNamed('/detail'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: WatchnookTokens.posterAspect,
            child: PosterPlaceholder(tag: item.type),
          ),
          const SizedBox(height: WatchnookSpacing.sm),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            item.progress,
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _LibraryItem {
  const _LibraryItem(this.title, this.progress, this.type);
  final String title;
  final String progress;
  final String type;
}
