import 'package:flutter/material.dart';

import '../../core/theme/watchnook_tokens.dart';
import '../../core/widgets/poster_placeholder.dart';

/// Search & add — results with a quick add + inline status picker.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _Result {
  const _Result(this.title, this.year, this.type);
  final String title;
  final String year;
  final String type;
}

class _SearchScreenState extends State<SearchScreen> {
  static const _results = [
    _Result('The Long Orbit', '2023', 'TV'),
    _Result('Paper Lanterns', '2025', 'Film'),
    _Result('Nightshade Bay', '2022', 'TV'),
    _Result('Slow Water', '2019', 'Film'),
  ];

  final Set<int> _added = {};
  int? _picking; // index whose status picker is open

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                WatchnookSpacing.lg, 0, WatchnookSpacing.lg, WatchnookSpacing.md),
            child: SearchBar(
              leading: const Icon(Icons.search),
              hintText: 'Films & TV…',
              elevation: const WidgetStatePropertyAll(0),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                  WatchnookSpacing.lg, 0, WatchnookSpacing.lg, WatchnookSpacing.xl),
              itemCount: _results.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: WatchnookSpacing.sm),
              itemBuilder: (context, i) => _ResultCard(
                result: _results[i],
                added: _added.contains(i),
                picking: _picking == i,
                onAdd: () => setState(() => _picking = i),
                onPick: () => setState(() {
                  _added.add(i);
                  _picking = null;
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.added,
    required this.picking,
    required this.onAdd,
    required this.onPick,
  });

  final _Result result;
  final bool added;
  final bool picking;
  final VoidCallback onAdd;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: WatchnookTokens.railCard(context),
      padding: const EdgeInsets.all(9),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                  width: 40, height: 60, child: PosterPlaceholder(radius: WatchnookRadii.thumb)),
              const SizedBox(width: WatchnookSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(result.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('${result.year} · ${result.type}',
                        style: text.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: WatchnookSpacing.sm),
              if (added)
                _IconBox(
                    icon: Icons.check,
                    color: cs.primary,
                    bg: cs.primary.withOpacity(0.22),
                    onTap: () {})
              else
                _IconBox(
                    icon: Icons.add,
                    color: cs.onSurface,
                    border: cs.outline,
                    onTap: onAdd),
            ],
          ),
          if (picking) ...[
            const SizedBox(height: WatchnookSpacing.sm),
            Row(
              children: [
                for (final s in const ['Watchlist', 'Watching', 'Completed'])
                  Padding(
                    padding: const EdgeInsets.only(right: WatchnookSpacing.sm),
                    child: ActionChip(label: Text(s), onPressed: onPick),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox(
      {required this.icon,
      required this.color,
      this.bg,
      this.border,
      required this.onTap});
  final IconData icon;
  final Color color;
  final Color? bg;
  final Color? border;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: border != null ? Border.all(color: border!) : null,
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
