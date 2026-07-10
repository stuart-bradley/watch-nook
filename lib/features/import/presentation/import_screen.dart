import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/import_export/import/merge_applier.dart';
import 'package:watch_nook/core/import_export/import/resolver.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/poster_placeholder.dart';
import 'package:watch_nook/features/import/data/import_providers.dart';
import 'package:watch_nook/features/import/domain/import_state.dart';

/// Import an export from TV Time, Trakt, IMDb or Letterboxd (#28, US-10/US-12).
/// Route `/import`.
///
/// The screen is a `switch` over [ImportState] — one state, one body. Ambiguous
/// titles are confirmed here before anything is written; leaving the screen
/// mid-confirmation writes nothing (the applier hasn't run).
class ImportScreen extends ConsumerWidget {
  /// Creates an [ImportScreen].
  const ImportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(importControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Import')),
      body: SafeArea(
        child: switch (state) {
          ImportIdle() => const _Idle(),
          ImportRunning() => _Running(state),
          ImportConfirming() => _Confirm(state),
          ImportDone() => _Done(state),
          ImportFailed() => _Failed(state),
        },
      ),
    );
  }
}

class _Idle extends ConsumerWidget {
  const _Idle();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Centered(
    children: [
      const Icon(Icons.file_upload_outlined, size: 56),
      const SizedBox(height: 16),
      Text(
        'Bring your history across',
        style: Theme.of(context).textTheme.titleLarge,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      const Text(
        'Pick an export from TV Time, Trakt, IMDb or Letterboxd. '
        'Importing merges with what you already have — nothing is overwritten.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        icon: const Icon(Icons.folder_open),
        label: const Text('Choose file'),
        onPressed: () => unawaited(
          ref.read(importControllerProvider.notifier).pickAndImport(),
        ),
      ),
    ],
  );
}

class _Running extends StatelessWidget {
  const _Running(this.state);

  final ImportRunning state;

  @override
  Widget build(BuildContext context) {
    final total = state.total;
    return _Centered(
      children: [
        LinearProgressIndicator(
          value: total == 0 ? null : state.done / total,
        ),
        const SizedBox(height: 16),
        Text(state.phase.label),
        if (total > 0) ...[
          const SizedBox(height: 4),
          Text(
            '${state.done} of $total',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// The confirmation queue. One card per unmatched title, each offering the
/// resolver's top candidates plus **Skip** — the escape hatch that matters,
/// because a wrong auto-match files someone's watch history under the wrong
/// show and there is no undo.
class _Confirm extends ConsumerStatefulWidget {
  const _Confirm(this.state);

  final ImportConfirming state;

  @override
  ConsumerState<_Confirm> createState() => _ConfirmState();
}

class _ConfirmState extends ConsumerState<_Confirm> {
  // Owned by the state so the scrollbar and list share one controller, and the
  // always-visible thumb doubles as a "how far through the queue" indicator.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final chosen = state.choices.values.whereType<MediaSearchResult>().length;
    final auto = state.autoResolved.length;
    final total = state.pending.length;
    final decided = state.choices.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_titles(auto, '')} matched automatically.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                total == 1
                    ? 'Review 1 title — pick a match or skip.'
                    : 'Reviewed $decided of $total — pick a match or skip.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: total,
              itemBuilder: (context, i) => _AmbiguousCard(
                ambiguous: state.pending[i],
                choice: state.choices[i],
                decided: state.choices.containsKey(i),
                onChoose: (candidate) => ref
                    .read(importControllerProvider.notifier)
                    .choose(i, candidate),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: () => unawaited(
              ref.read(importControllerProvider.notifier).applyConfirmed(),
            ),
            child: Text(_titles(auto + chosen, 'Import ')),
          ),
        ),
      ],
    );
  }
}

String _titles(int n, String prefix) =>
    '$prefix$n ${n == 1 ? 'title' : 'titles'}';

class _AmbiguousCard extends StatelessWidget {
  const _AmbiguousCard({
    required this.ambiguous,
    required this.choice,
    required this.decided,
    required this.onChoose,
  });

  final Ambiguous ambiguous;
  final MediaSearchResult? choice;
  final bool decided;
  final ValueChanged<MediaSearchResult?> onChoose;

  @override
  Widget build(BuildContext context) {
    final record = ambiguous.record;
    final year = record.year;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(record.title),
            subtitle: Text(
              year == null ? 'From your export' : 'From your export · $year',
            ),
          ),
          for (final candidate in ambiguous.candidates)
            _CandidateTile(
              candidate: candidate,
              selected: candidate == choice,
              onTap: () => onChoose(candidate),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: Icon(
                  decided && choice == null
                      ? Icons.check_circle
                      : Icons.block_outlined,
                ),
                label: Text(
                  ambiguous.candidates.isEmpty
                      ? 'Nothing to match — skip'
                      : 'Skip this title',
                ),
                onPressed: () => onChoose(null),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CandidateTile extends ConsumerWidget {
  const _CandidateTile({
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  final MediaSearchResult candidate;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final year = candidate.year;
    final kind = candidate.kind == MediaKind.movie ? 'Film' : 'TV';
    // Origin country disambiguates same-titled regional versions — the whole
    // reason these went to the queue (Taskmaster AU vs NZ vs GB, etc.).
    final country = candidate.originCountry.join('/');
    return ListTile(
      selected: selected,
      leading: _Poster(path: candidate.posterPath),
      title: Text(
        candidate.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (year != null) '$year',
          kind,
          if (country.isNotEmpty) country,
        ].join(' · '),
      ),
      trailing: selected ? const Icon(Icons.check_circle) : null,
      onTap: onTap,
    );
  }
}

class _Done extends ConsumerWidget {
  const _Done(this.state);

  final ImportDone state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ImportSummary(
      :itemsAdded,
      :itemsUpdated,
      :watchEventsAdded,
      :rewatchesAdded,
      :ambiguous,
    ) = state.summary;
    return _Centered(
      children: [
        const Icon(Icons.check_circle_outline, size: 56),
        const SizedBox(height: 16),
        Text('Import complete', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        _Stat('Titles added', itemsAdded),
        _Stat('Titles updated', itemsUpdated),
        _Stat('Episodes & films marked watched', watchEventsAdded),
        _Stat('Rewatches logged', rewatchesAdded),
        _Stat('Titles skipped', ambiguous),
        _Stat('Rows we could not read', state.rowsSkipped),
        const SizedBox(height: 24),
        FilledButton(
          // The primary next step: land on Up Next, not the system back button.
          onPressed: () => context.go('/up-next'),
          child: const Text('Continue'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => ref.read(importControllerProvider.notifier).reset(),
          child: const Text('Import another file'),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text('$label: $value'),
  );
}

class _Failed extends ConsumerWidget {
  const _Failed(this.state);

  final ImportFailed state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Centered(
    children: [
      const Icon(Icons.error_outline, size: 56),
      const SizedBox(height: 16),
      Text(state.message, textAlign: TextAlign.center),
      const SizedBox(height: 24),
      OutlinedButton(
        onPressed: () => ref.read(importControllerProvider.notifier).reset(),
        child: const Text('Try another file'),
      ),
    ],
  );
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      ),
    ),
  );
}

/// Candidate thumbnail — the same offline-safe poster the search results use.
class _Poster extends ConsumerWidget {
  const _Poster({required this.path});

  final String? path;

  // Matches the search row: the subtitle already carries the type.
  static const _placeholder = PosterPlaceholder(
    width: _posterWidth,
    height: _posterHeight,
    radius: WatchnookRadii.thumb,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = this.path;
    if (path == null) return _placeholder;
    final url = ref
        .read(activeMetadataSourceProvider)
        .imageUrl(path, ImageSize.small);
    return ClipRRect(
      borderRadius: WatchnookRadii.thumb,
      child: CachedNetworkImage(
        imageUrl: url,
        cacheManager: PosterCacheManager.instance,
        width: _posterWidth,
        height: _posterHeight,
        fit: BoxFit.cover,
        placeholder: (_, _) => _placeholder,
        errorWidget: (_, _, _) => _placeholder,
      ),
    );
  }
}

const double _posterWidth = 40;
const double _posterHeight = _posterWidth / WatchnookTokens.posterAspect;
