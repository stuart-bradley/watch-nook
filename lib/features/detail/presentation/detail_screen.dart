import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/library_identity.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/remote_image.dart';
import 'package:watch_nook/core/widgets/track_status_ui.dart';
import 'package:watch_nook/features/detail/data/add_to_library.dart';
import 'package:watch_nook/features/detail/data/bulk_mark.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/detail/data/detail_target.dart';

/// Title detail (#18, US-6): backdrop, overview, the user's rating, the
/// seasons→episodes list, and the per-source attribution footer.
///
/// **Two entry points, one screen.**
/// - `/title/:id` ([itemId]) — a **tracked** row: status dropdown, rating,
///   watch actions, per-episode toggles.
/// - `/preview` ([result]) — an **untracked** search hit: the same backdrop,
///   overview and seasons/episodes, but *no write controls at all* — only an
///   "Add to library" button. There is no library row to write against yet, so
///   every mark/rate/status control is absent, not merely disabled.
///
/// Neither given renders the not-found notice (a restored deep link to
/// `/preview`, whose `extra` doesn't survive the trip).
///
/// Metadata comes from `titleDetailsProvider` (SWR, cache-first), so the screen
/// renders offline from cache and a failed revalidation never blanks it. The
/// per-episode watched toggle and the movie mark/rewatch buttons (#19) write
/// through `LibraryDao`, which owns the idempotent-toggle invariant.
class DetailScreen extends ConsumerWidget {
  /// Creates the detail screen for the tracked `LibraryItems` row [itemId].
  const DetailScreen({this.itemId, this.result, super.key});

  /// The `LibraryItems.id` from the route — null when previewing a search hit.
  final int? itemId;

  /// The untracked search hit being previewed — null for a tracked title.
  final MediaSearchResult? result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemId = this.itemId;
    final result = this.result;

    if (itemId == null) {
      return Scaffold(
        appBar: AppBar(title: Text(result?.title ?? '')),
        body: result == null
            ? const _Notice("Couldn't open this title.")
            : _Body(result: result),
      );
    }

    final item = ref.watch(libraryItemProvider(itemId));
    return Scaffold(
      appBar: AppBar(title: Text(item.value?.title ?? '')),
      body: item.when(
        // Marking an episode watched re-emits this row; keep the loaded body
        // during the reload instead of flashing the full-screen spinner.
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const _Notice("Couldn't open this title."),
        data: (row) => row == null
            ? const _Notice('This title is no longer in your library.')
            : _Body(item: row),
      ),
    );
  }
}

/// The screen body in either mode. Exactly one of [item] (tracked) / [result]
/// (preview) is non-null; `item == null` is the single switch every write
/// control below reads as "not tracked yet — offer nothing to write".
class _Body extends ConsumerWidget {
  const _Body({this.item, this.result});

  final LibraryItem? item;
  final MediaSearchResult? result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entry = this.item;
    final result = this.result;

    // Which title, from which backend, and is it tracked — answered once, by
    // [detailTargetOf], rather than re-derived down the build method.
    final activeKind = ref.watch(activeMetadataKindProvider);
    final target = detailTargetOf(
      item: entry,
      result: result,
      active: activeKind,
    );
    // The hit itself, when this is a preview — the only case with one.
    final previewHit = switch (target) {
      PreviewTitle(:final result) => result,
      _ => null,
    };
    final mediaType = target.mediaType;
    if (mediaType == null) return const _Notice("Couldn't open this title.");

    // A [StrandedTitle] or an id-less preview has no reference and so fetches
    // nothing: it renders from what the row or the hit already carries.
    // ponytail: conditional watch — no reference, no provider to watch.
    final fetchRef = target.fetchRef;
    final async = fetchRef == null
        ? null
        : ref.watch(titleDetailsProvider(mediaType, fetchRef));
    final details = async?.value;
    final coldCache = async != null && !async.hasValue;
    final seasons = details?.seasons ?? const <SeasonInfo>[];

    // A search hit we already track is NOT a preview — it's that row's detail
    // page, and must never offer to add what's already in the library (US-3).
    // Search resolves this at tap time, but from the raw hit; TMDB's `search`
    // carries no `imdbId`, so an imdb-keyed import can slip through and only
    // become matchable once the details land. Re-resolve here with the enriched
    // identity — `identityOf` is the same builder `addToLibrary` uses, so the
    // two cannot disagree about whether this title is tracked.
    final trackedId = switch (target) {
      PreviewTitle(:final result) =>
        ref.watch(trackedItemProvider(identityOf(result, details))).value?.id,
      _ => null,
    };
    // Re-read the resolved row through the **live** provider, not the one-shot
    // lookup above: from here on this is an ordinary tracked detail screen, and
    // its controls must repaint off the row like any other (a watch write
    // recomputes `watchedCount`).
    final item = switch (target) {
      TrackedTitle(:final item) || StrandedTitle(:final item) => item,
      _ =>
        trackedId == null
            ? null
            : ref.watch(libraryItemProvider(trackedId)).value,
    };

    return ListView(
      children: [
        RemoteImage.backdrop(artwork: _backdrop(details, activeKind)),
        if (coldCache && async.isLoading) const LinearProgressIndicator(),
        Padding(
          padding: const EdgeInsets.all(WatchnookSpacing.screen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(
                title: details?.title ?? item?.title ?? previewHit?.title ?? '',
                year: details?.year ?? item?.year ?? previewHit?.year,
                mediaType: mediaType,
                showStatus: details?.showStatus ?? item?.showStatus,
              ),
              const SizedBox(height: WatchnookSpacing.md),
              // The one adaptive line: tracked titles get the controls that
              // manage them; an untracked one gets the single action that makes
              // it trackable.
              if (item case final tracked?)
                Wrap(
                  spacing: WatchnookSpacing.sm,
                  runSpacing: WatchnookSpacing.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _StatusDropdown(item: tracked),
                    _RatingRow(item: tracked),
                  ],
                )
              else if (previewHit case final hit?)
                _AddButton(result: hit),
              if (item != null && item.mediaType == MediaType.movie) ...[
                const SizedBox(height: WatchnookSpacing.md),
                _MovieWatchActions(item: item),
              ],
              if (coldCache && async.hasError) ...[
                const SizedBox(height: WatchnookSpacing.md),
                const _Notice("Couldn't load details. You're offline."),
              ],
              if (details?.overview case final overview?
                  when overview.isNotEmpty) ...[
                const SizedBox(height: WatchnookSpacing.md),
                Text(overview, style: theme.textTheme.bodyMedium),
              ],
              if (details?.nextEpisode case final next?) ...[
                const SizedBox(height: WatchnookSpacing.md),
                _NextEpisode(episode: next),
              ],
            ],
          ),
        ),
        // Seasons come from the details fetch; a movie has none. "Mark show
        // watched" is the *section action* for the list below it — it used to
        // sit up with the status control, where it read as the only thing you
        // could do with a title.
        if (fetchRef != null && seasons.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WatchnookSpacing.screen,
              0,
              WatchnookSpacing.screen,
              WatchnookSpacing.sm,
            ),
            // Wrap, not Row+Expanded: on a 360dp phone the label and a button
            // this wide don't share a line, and an Expanded label would be
            // squeezed to ~20dp and wrap one letter per line. This drops the
            // button to its own line instead.
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: WatchnookSpacing.sm,
              runSpacing: WatchnookSpacing.xs,
              children: [
                Text('Seasons', style: theme.textTheme.titleMedium),
                // Specials-only shows have nothing to bulk-mark (the bulk
                // helpers exclude season 0), so the button would mark nothing.
                if (item != null && seasons.any((s) => s.seasonNumber > 0))
                  _BulkButton(
                    icon: Icons.done_all,
                    label: 'Mark show watched',
                    itemId: item.id,
                    showRef: fetchRef,
                    seasons: _seasonNumbers(details!),
                  ),
              ],
            ),
          ),
        // Seasons only exist once details have loaded, which cannot happen
        // without a reference — so the guard is a formality the type system
        // needs, not a case that occurs.
        if (fetchRef != null)
          for (final season in seasons)
            _SeasonTile(
              itemId: item?.id,
              showRef: fetchRef,
              season: season,
              allSeasons: _seasonNumbers(details!),
            ),
        // Attribution lives in Settings → About, not on every detail page.
      ],
    );
  }
}

/// Title + a "2022 · TV · Returning Series" caption. Falls back to the stored
/// row (or the search hit) when details haven't loaded, so it renders offline.
///
/// The track status is deliberately **not** in the caption: the status dropdown
/// below states it, and a title's category shouldn't read as a fact about the
/// show alongside its year.
class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.year,
    required this.mediaType,
    required this.showStatus,
  });

  final String title;
  final int? year;
  final MediaType mediaType;
  final String? showStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = mediaType == MediaType.movie ? 'Film' : 'TV';
    final caption = <String>[
      if (year != null) '$year',
      kind,
      ?showStatus,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: WatchnookSpacing.xs),
        Text(
          caption,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The **user's** rating (`LibraryItems.rating`, 0–10) — the only rating in the
/// data model; neither backend's score is snapshotted. Tapping opens a picker
/// so the column set by `updateRating` is actually reachable.
class _RatingRow extends ConsumerWidget {
  const _RatingRow({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rating = item.rating;
    return ActionChip(
      avatar: Icon(rating == null ? Icons.star_border : Icons.star),
      label: Text(rating == null ? 'Rate' : '$rating/10'),
      onPressed: () => unawaited(_pickRating(context, ref, item)),
    );
  }
}

Future<void> _pickRating(
  BuildContext context,
  WidgetRef ref,
  LibraryItem item,
) async {
  // -1 distinguishes "cleared" from "dismissed" (null) — a rating of 0 is real.
  final picked = await showModalBottomSheet<int>(
    context: context,
    builder: (context) => SafeArea(
      child: Wrap(
        children: [
          for (var i = 10; i >= 1; i--)
            ListTile(
              leading: const Icon(Icons.star),
              title: Text('$i/10'),
              onTap: () => Navigator.pop(context, i),
            ),
          ListTile(
            leading: const Icon(Icons.star_border),
            title: const Text('Clear rating'),
            onTap: () => Navigator.pop(context, -1),
          ),
        ],
      ),
    ),
  );
  if (picked == null) return;
  await ref
      .read(libraryDaoProvider)
      .updateRating(item.id, picked == -1 ? null : picked, now: clock.now());
}

/// The show's track status (`LibraryItems.trackStatus`) — a labelled Material 3
/// [DropdownMenu], not a chip. It replaced an `ActionChip` pill that read as a
/// badge: nothing about it said "this is how you move a title between
/// Watchlist, Watching, On hold…".
class _StatusDropdown extends ConsumerWidget {
  const _StatusDropdown({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DropdownMenu<TrackStatus>(
      initialSelection: item.trackStatus,
      label: const Text('Status'),
      leadingIcon: Icon(item.trackStatus.icon),
      // It's a selector, not a combobox — never raise the keyboard, and don't
      // let a stray keystroke filter the five statuses.
      requestFocusOnTap: false,
      onSelected: (status) {
        if (status == null) return;
        unawaited(
          ref
              .read(libraryDaoProvider)
              .updateStatus(item.id, status, now: clock.now()),
        );
      },
      dropdownMenuEntries: [
        for (final status in TrackStatus.values)
          DropdownMenuEntry(
            value: status,
            label: status.label,
            leadingIcon: Icon(status.icon),
          ),
      ],
    );
  }
}

/// The preview mode's one action (US-2): read the details, *then* decide. Picks
/// a status, adds via the shared [addToLibrary] (which snapshots the stats
/// fields and dedupes), and replaces this route with the tracked one — so Back
/// returns to search, not to an "Add" page for a title that's now in the
/// library.
class _AddButton extends ConsumerWidget {
  const _AddButton({required this.result});

  final MediaSearchResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilledButton.icon(
    icon: const Icon(Icons.add),
    label: const Text('Add to library'),
    onPressed: () => unawaited(_addTitle(context, ref, result)),
  );
}

Future<void> _addTitle(
  BuildContext context,
  WidgetRef ref,
  MediaSearchResult result,
) async {
  final status = await showTrackStatusPicker(context);
  if (status == null || !context.mounted) return;

  // Captured before the await, so no `BuildContext` crosses the async gap.
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  try {
    final (:item, :created) = await addToLibrary(
      repo: ref.read(metadataProvider),
      sourceKind: ref.read(activeMetadataKindProvider),
      dao: ref.read(libraryDaoProvider),
      result: result,
      status: status,
    );
    // No invalidation needed: `trackedItemProvider` is live off the library, so
    // the search list underneath re-badges this row on the write itself. (It
    // used to `ref.invalidate` here — which throws a StateError if the preview
    // was popped mid-add, and the catch below would then have reported a
    // *successful* add as "Couldn't add this title.")
    unawaited(router.pushReplacement('/title/${item.id}'));
    messenger.showSnackBar(
      SnackBar(
        // Re-adding a tracked title is a no-op — the dedupe returns that row
        // untouched, so the picked status was NOT applied. Saying "Added … to
        // Watching" here would be a lie about the user's own data.
        content: Text(
          created
              ? 'Added "${item.title}" to ${status.label}'
              : '"${item.title}" is already in your library',
        ),
      ),
    );
  } on Object catch (e, s) {
    debugPrint('wn-error: add title failed: $e\n$s');
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't add this title.")),
    );
  }
}

/// A movie's watched toggle + rewatch log (#19, US-2/US-4). Watched-ness is the
/// denormalized `watchedCount` on the live row — no cross-domain join, and a
/// rewatch (which never raises the count) leaves the button as it was.
class _MovieWatchActions extends ConsumerWidget {
  const _MovieWatchActions({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dao = ref.watch(libraryDaoProvider);
    final watched = item.watchedCount > 0;
    return Wrap(
      spacing: WatchnookSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          icon: Icon(watched ? Icons.check_circle : Icons.check_circle_outline),
          label: Text(watched ? 'Watched' : 'Mark watched'),
          onPressed: () => unawaited(
            watched
                ? dao.unwatch(item.id)
                : dao.markWatched(
                    item.id,
                    watchedAt: clock.now(),
                    runtimeMinutes: item.runtimeMinutes,
                  ),
          ),
        ),
        if (watched)
          TextButton.icon(
            icon: const Icon(Icons.replay),
            label: const Text('Log rewatch'),
            onPressed: () => unawaited(
              dao.logRewatch(
                item.id,
                watchedAt: clock.now(),
                runtimeMinutes: item.runtimeMinutes,
              ),
            ),
          ),
      ],
    );
  }
}

class _NextEpisode extends StatelessWidget {
  const _NextEpisode({required this.episode});

  final EpisodeInfo episode;

  @override
  Widget build(BuildContext context) {
    final airDate = episode.airDate;
    final parts = <String>[
      'Next: S${episode.seasonNumber}E${episode.episodeNumber}',
      if (episode.title != null) episode.title!,
      if (airDate != null) _isoDate(airDate),
    ];
    return Row(
      children: [
        const Icon(Icons.schedule, size: 16),
        const SizedBox(width: WatchnookSpacing.sm),
        Expanded(child: Text(parts.join(' · '))),
      ],
    );
  }
}

/// One collapsible season. `ExpansionTile` doesn't build its children while
/// collapsed, so the episode fetch happens on expand — one season at a time.
///
/// The bulk control lives on the **bar**, not inside the expanded body: marking
/// season 3 shouldn't mean expanding season 3 first. The expand chevron moves
/// to the leading edge (`controlAffinity`) to free `trailing` for it.
class _SeasonTile extends ConsumerWidget {
  const _SeasonTile({
    required this.itemId,
    required this.showRef,
    required this.season,
    required this.allSeasons,
  });

  /// The tracked row, or null in preview mode — where there is nothing to mark.
  final int? itemId;

  final SourceRef showRef;
  final SeasonInfo season;

  /// Every season number of the show — "watch up to here" spans the seasons
  /// before this one, so the episode rows need more than their own season.
  final List<int> allSeasons;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemId = this.itemId;
    final name = season.name ?? 'Season ${season.seasonNumber}';

    // Same provider instance `_SeasonEpisodes` watches (family-keyed on the
    // item), so the progress count costs no extra query.
    final watched = itemId == null
        ? const <(int, int)>{}
        : ref.watch(watchedEpisodesProvider(itemId)).value ??
              const <(int, int)>{};
    final watchedHere = watched
        .where((c) => c.$1 == season.seasonNumber)
        .length;
    final complete =
        season.episodeCount > 0 && watchedHere >= season.episodeCount;

    // Specials (season 0) have no bulk action — they're excluded from
    // aired-order progress, so the button would mark nothing.
    final bulkable = itemId != null && season.seasonNumber > 0;

    return ExpansionTile(
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(name),
      subtitle: Text(
        itemId == null
            ? '${season.episodeCount} episodes'
            : '$watchedHere/${season.episodeCount} watched',
      ),
      trailing: !bulkable
          ? null
          : IconButton(
              icon: const Icon(Icons.done_all),
              tooltip: complete ? 'Season watched' : 'Mark season watched',
              // Marking is idempotent, but a disabled button says "already
              // done" without costing a tap to find out.
              onPressed: complete
                  ? null
                  : () => unawaited(
                      _runBulk(
                        context,
                        ref,
                        itemId: itemId,
                        showRef: showRef,
                        seasons: [season.seasonNumber],
                      ),
                    ),
            ),
      children: [
        _SeasonEpisodes(
          itemId: itemId,
          showRef: showRef,
          seasonNumber: season.seasonNumber,
          allSeasons: allSeasons,
        ),
      ],
    );
  }
}

/// Fires a bulk mark (#20) and reports the outcome. `seasons`/`upTo` are handed
/// straight to [bulkMarkWatched], which excludes specials and is idempotent.
class _BulkButton extends ConsumerWidget {
  const _BulkButton({
    required this.icon,
    required this.label,
    required this.itemId,
    required this.showRef,
    required this.seasons,
  });

  final IconData icon;
  final String label;
  final int itemId;
  final SourceRef showRef;
  final List<int> seasons;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OutlinedButton.icon(
    icon: Icon(icon),
    label: Text(label),
    onPressed: () => unawaited(
      _runBulk(
        context,
        ref,
        itemId: itemId,
        showRef: showRef,
        seasons: seasons,
      ),
    ),
  );
}

/// Runs a bulk mark and surfaces the result in a snack bar. The messenger is
/// captured **before** the await, so no `BuildContext` crosses the async gap.
/// A cold cache with no network throws out of [bulkMarkWatched] having written
/// nothing — the user sees the offline notice, not a half-marked season.
Future<void> _runBulk(
  BuildContext context,
  WidgetRef ref, {
  required int itemId,
  required SourceRef showRef,
  required List<int> seasons,
  (int, int)? upTo,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await bulkMarkWatched(
      dao: ref.read(libraryDaoProvider),
      repo: ref.read(metadataProvider),
      itemId: itemId,
      showRef: showRef,
      seasons: seasons,
      upTo: upTo,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          switch (result) {
            // Nothing marked has TWO causes. Telling someone who just tapped an
            // unaired season — whose own row reads "0/10 watched" — that it is
            // "already watched" is a flat lie, and it hides the under-mark that
            // `hasAired` deliberately chooses (see its doc: under-marking is
            // only the safe failure because the user can SEE it). The test is
            // whether anything had aired at all, NOT whether anything was
            // skipped: a show you are caught up on with a season still to come
            // skips plenty and is also genuinely already watched.
            (marked: 0, airedCandidates: 0) => 'Nothing has aired yet.',
            (marked: 0, airedCandidates: _) => 'Already watched.',
            (marked: 1, airedCandidates: _) => 'Marked 1 episode watched.',
            (marked: final n, airedCandidates: _) =>
              'Marked $n episodes watched.',
          },
        ),
      ),
    );
  } on Object catch (e, s) {
    // The snack bar below is a DIAGNOSIS, and it is the wrong one whenever the
    // throw came from anywhere but the network. A malformed fixture reads as
    // "you're offline" — which is exactly how a `FormatException` in the E2E's
    // episode dates cost hours in #79. Log the real error so the E2E's logcat
    // dump can name it; the user-facing copy stays the common case.
    debugPrint('wn-error: bulk mark failed: $e\n$s');
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't load episodes. You're offline.")),
    );
  }
}

/// Aired-order season numbers of a show's details, specials included (the bulk
/// helpers do the season-0 filtering, in one place).
List<int> _seasonNumbers(MediaDetails details) =>
    details.seasons.map((s) => s.seasonNumber).toList();

class _SeasonEpisodes extends ConsumerWidget {
  const _SeasonEpisodes({
    required this.itemId,
    required this.showRef,
    required this.seasonNumber,
    required this.allSeasons,
  });

  /// Null in preview mode — the episode rows then carry no watch controls.
  final int? itemId;

  final SourceRef showRef;
  final int seasonNumber;
  final List<int> allSeasons;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemId = this.itemId;
    final episodes = ref.watch(
      seasonEpisodesProvider(showRef, seasonNumber),
    );
    // Before the first emission nothing is known to be watched — an unwatched
    // toggle that marks is the safe default (marking is idempotent; unwatching
    // is destructive).
    final watched = itemId == null
        ? const <(int, int)>{}
        : ref.watch(watchedEpisodesProvider(itemId)).value ??
              const <(int, int)>{};
    return episodes.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(WatchnookSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const _Notice("Couldn't load episodes."),
      data: (rows) => Column(
        children: [
          for (final e in rows)
            ListTile(
              dense: true,
              leading: Text('E${e.episodeNumber}'),
              title: Text(e.title ?? 'Episode ${e.episodeNumber}'),
              subtitle: e.airDate == null ? null : Text(_isoDate(e.airDate!)),
              // "Watch up to here" (#20): everything aired-order ≤ this
              // episode, across the earlier seasons too.
              onLongPress: itemId == null || e.seasonNumber <= 0
                  ? null
                  : () => unawaited(
                      _runBulk(
                        context,
                        ref,
                        itemId: itemId,
                        showRef: showRef,
                        seasons: allSeasons,
                        upTo: (e.seasonNumber, e.episodeNumber),
                      ),
                    ),
              trailing: itemId == null
                  ? null
                  : _EpisodeToggle(
                      itemId: itemId,
                      episode: e,
                      watched: watched.contains((
                        e.seasonNumber,
                        e.episodeNumber,
                      )),
                    ),
            ),
        ],
      ),
    );
  }
}

/// The per-episode watched toggle (#19, US-2). Mark is idempotent; unwatch
/// removes the episode's rewatches too. `runtimeMinutes` is snapshotted from
/// the episode at mark-time so stats never read the disposable cache.
class _EpisodeToggle extends ConsumerWidget {
  const _EpisodeToggle({
    required this.itemId,
    required this.episode,
    required this.watched,
  });

  final int itemId;
  final EpisodeInfo episode;
  final bool watched;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dao = ref.watch(libraryDaoProvider);
    return IconButton(
      icon: Icon(watched ? Icons.check_circle : Icons.check_circle_outline),
      tooltip: watched ? 'Mark unwatched' : 'Mark watched',
      onPressed: () => unawaited(
        watched
            ? dao.unwatch(
                itemId,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
              )
            : dao.markWatched(
                itemId,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
                watchedAt: clock.now(),
                runtimeMinutes: episode.runtimeMinutes,
              ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(WatchnookSpacing.lg),
    child: Text(message, textAlign: TextAlign.center),
  );
}

/// ISO-8601 date, no `intl` dependency for one label.
String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The detail backdrop, tagged with the backend that fetched it. Details only
/// ever come from the active source (a stranded row fetches nothing at all),
/// so this is that backend by construction.
ArtworkRef? _backdrop(MediaDetails? details, MetadataSourceKind kind) {
  final path = details?.backdropPath;
  return path == null ? null : ArtworkRef(kind, path);
}
