import 'package:flutter/material.dart';

import '../../core/theme/watchnook_tokens.dart';
import '../../core/widgets/poster_placeholder.dart';

/// Title detail — backdrop, overview, per-episode watched toggles and the
/// fast bulk-marking the brief prioritises. Mock state via [setState];
/// production reads/writes the local DB through Riverpod.
class TitleDetailScreen extends StatefulWidget {
  const TitleDetailScreen({super.key});

  @override
  State<TitleDetailScreen> createState() => _TitleDetailScreenState();
}

class _Episode {
  const _Episode(this.code, this.title, this.date);
  final String code;
  final String title;
  final String date;
}

class _TitleDetailScreenState extends State<TitleDetailScreen> {
  static const _episodes = [
    _Episode('E1', 'Slack Water', '8 Jun'),
    _Episode('E2', 'Springs', '15 Jun'),
    _Episode('E3', 'Neap', '22 Jun'),
    _Episode('E4', 'Ebb', '29 Jun'),
    _Episode('E5', 'Ashes', 'airs tonight'),
    _Episode('E6', 'Tideline', '15 Jul'),
  ];

  final Set<int> _watched = {0, 1, 2, 3};
  int _season = 2;

  void _toggle(int i) => setState(() {
        _watched.contains(i) ? _watched.remove(i) : _watched.add(i);
      });

  void _markSeason() =>
      setState(() => _watched.addAll(List.generate(_episodes.length, (i) => i)));

  int get _nextUnwatched {
    for (var i = 0; i < _episodes.length; i++) {
      if (!_watched.contains(i)) return i;
    }
    return _episodes.length - 1;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final next = _episodes[_nextUnwatched];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _backdrop(cs)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              WatchnookSpacing.lg,
              0,
              WatchnookSpacing.lg,
              WatchnookSpacing.xl,
            ),
            sliver: SliverList.list(
              children: [
                _header(text, cs),
                const SizedBox(height: WatchnookSpacing.md),
                Text(
                  'A harbour town keeps its tides and its secrets. Two '
                  'detectives return to the bay that made them.',
                  style: text.bodyMedium
                      ?.copyWith(color: cs.onSurfaceVariant, height: 1.5),
                ),
                const SizedBox(height: WatchnookSpacing.lg),
                FilledButton(
                  onPressed: () => _toggle(_nextUnwatched),
                  child: Text('Mark ${_season}x${next.code.substring(1)} '
                      'watched'),
                ),
                const SizedBox(height: WatchnookSpacing.sm),
                OutlinedButton(
                  onPressed: () {},
                  child: const Text('Add to library'),
                ),
                _seasonBar(text),
                // Bulk-marking — the TV Time refugee's #1 need.
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _markSeason,
                        icon: const Icon(Icons.done_all, size: 18),
                        label: const Text('Mark season'),
                      ),
                    ),
                    const SizedBox(width: WatchnookSpacing.sm),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _markSeason,
                        icon: const Icon(Icons.playlist_add_check, size: 18),
                        label: const Text('Mark show'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: WatchnookSpacing.sm),
                for (var i = 0; i < _episodes.length; i++)
                  _episodeRow(i, text, cs),
                const SizedBox(height: WatchnookSpacing.md),
                Text('Next: S2E6 airs Tue 15 Jul',
                    style:
                        text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const _AttributionFooter(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _backdrop(ColorScheme cs) {
    return SizedBox(
      height: 150,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: cs.surfaceContainerHigh),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, cs.surface],
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 8,
            child: SafeArea(
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(TextTheme text, ColorScheme cs) {
    return Transform.translate(
      offset: const Offset(0, -44),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 76,
            height: 114,
            child: PosterPlaceholder(tag: 'TV'),
          ),
          const SizedBox(width: WatchnookSpacing.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Nightshade Bay', style: text.headlineSmall),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text('2022 · TV',
                          style: text.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                      const SizedBox(width: WatchnookSpacing.sm),
                      Icon(Icons.star_rounded, size: 15, color: cs.primary),
                      const SizedBox(width: 3),
                      Text('4.4',
                          style: text.bodySmall?.copyWith(color: cs.primary)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seasonBar(TextTheme text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: WatchnookSpacing.md),
      child: Row(
        children: [
          Text('Season $_season',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          for (final s in const [1, 2, 3])
            Padding(
              padding: const EdgeInsets.only(left: WatchnookSpacing.sm),
              child: ChoiceChip(
                label: Text('S$s'),
                selected: _season == s,
                onSelected: (_) => setState(() => _season = s),
              ),
            ),
        ],
      ),
    );
  }

  Widget _episodeRow(int i, TextTheme text, ColorScheme cs) {
    final e = _episodes[i];
    final done = _watched.contains(i);
    return InkWell(
      onTap: () => _toggle(i),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration:
            BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant))),
        child: Row(
          children: [
            _Check(done: done),
            const SizedBox(width: WatchnookSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${e.code} · ${e.title}',
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: done ? cs.onSurfaceVariant : cs.onSurface,
                      )),
                  const SizedBox(height: 1),
                  Text(e.date,
                      style: text.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.done});
  final bool done;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: done ? cs.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: done ? cs.primary : cs.onSurfaceVariant, width: 1.5),
      ),
      child: done
          ? Icon(Icons.check, size: 16, color: cs.onPrimary)
          : null,
    );
  }
}

class _AttributionFooter extends StatelessWidget {
  const _AttributionFooter();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: WatchnookSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: cs.outlineVariant),
          const SizedBox(height: WatchnookSpacing.sm),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: 'TMDB  ',
                style: text.labelMedium
                    ?.copyWith(color: cs.primary, fontWeight: FontWeight.w800),
              ),
              TextSpan(
                text: 'Metadata from The Movie Database, not endorsed by TMDB. '
                    'Series data from TheTVDB.',
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
