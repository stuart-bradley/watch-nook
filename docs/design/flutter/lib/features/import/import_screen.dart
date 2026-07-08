import 'package:flutter/material.dart';

import '../../core/theme/watchnook_tokens.dart';
import '../../core/widgets/poster_placeholder.dart';

/// Import — pick an export, watch progress, then resolve fuzzy matches one
/// by one (accept / replace / skip). Mock progress + list via [setState].
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _Match {
  const _Match(this.entry, this.candidate);
  final String entry;
  final String candidate;
}

class _ImportScreenState extends State<ImportScreen> {
  static const _sources = ['TV Time', 'Letterboxd', 'IMDb', 'Trakt'];
  final _matches = <_Match>[
    const _Match('Nightshade', 'Nightshade Bay · 2022'),
    const _Match('Orbit (Long)', 'The Long Orbit · 2023'),
    const _Match('paperlanterns', 'Paper Lanterns · 2025'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Import')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            WatchnookSpacing.lg, 0, WatchnookSpacing.lg, WatchnookSpacing.xl),
        children: [
          Text('From a TV Time, Letterboxd, IMDb or Trakt export.',
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: WatchnookSpacing.md),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: WatchnookSpacing.sm,
            mainAxisSpacing: WatchnookSpacing.sm,
            childAspectRatio: 1.9,
            children: [for (final s in _sources) _SourceCard(name: s)],
          ),
          const SizedBox(height: WatchnookSpacing.lg),
          Row(
            children: [
              Text('Matching titles…',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const Spacer(),
              Text('128 / 342',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: WatchnookSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(WatchnookRadii.pill),
            child: LinearProgressIndicator(
              value: 0.37,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHigh,
            ),
          ),
          const SizedBox(height: WatchnookSpacing.lg),
          Text('Review matches',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: WatchnookSpacing.md),
          for (var i = 0; i < _matches.length; i++) ...[
            _MatchCard(
              match: _matches[i],
              onResolve: () => setState(() => _matches.removeAt(i)),
            ),
            const SizedBox(height: WatchnookSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: WatchnookRadii.card,
      onTap: () {},
      child: Container(
        decoration: WatchnookTokens.railCard(context),
        padding: const EdgeInsets.all(WatchnookSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(name,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('Choose export…',
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, required this.onResolve});
  final _Match match;
  final VoidCallback onResolve;

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
                  width: 38, height: 57, child: PosterPlaceholder(radius: WatchnookRadii.thumb)),
              const SizedBox(width: WatchnookSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('YOUR ENTRY',
                        style: text.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant, letterSpacing: 0.6)),
                    Text(match.entry,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('Match: ${match.candidate}',
                        style: text.bodySmall?.copyWith(color: cs.primary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: WatchnookSpacing.sm),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onResolve,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Accept'),
                ),
              ),
              const SizedBox(width: WatchnookSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: const Text('Replace'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(40)),
                ),
              ),
              const SizedBox(width: WatchnookSpacing.sm),
              IconButton(
                onPressed: onResolve,
                icon: const Icon(Icons.close),
                tooltip: 'Skip',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
