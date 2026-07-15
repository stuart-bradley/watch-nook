import 'package:cached_network_image/cached_network_image.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/empty_state.dart';
import 'package:watch_nook/core/widgets/poster_placeholder.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';

/// Up Next tab (#21, R4) — two answers to "what now?", on one page:
///
/// - **Ready to watch** — the watch queue: the next unwatched *aired* episode
///   for every tracked show that has one, each with a tick to mark it watched
///   without leaving the tab. Ticking advances the row live (the board
///   recomputes from the library stream).
/// - **This week / Later** — every tracked show's next *scheduled* episode,
///   soonest first. Nothing here is tickable: it hasn't aired.
///
/// Renders its three states, never a blank crash when a show's (cache-first)
/// fetch fails offline.
class UpNextScreen extends ConsumerWidget {
  const UpNextScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(upNextBoardProvider)
        .when(
          // Ticking an episode writes to the library, which re-emits
          // [libraryItemsProvider] and *reloads* this board. Keep the current
          // queue on screen during that reload instead of flashing the
          // full-screen spinner (the default `skipLoadingOnReload: false`) —
          // that flash is the "flicker" the tab used to show. First load (no
          // previous value) still shows the spinner.
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => EmptyState(
            icon: Icons.cloud_off,
            headline: "Couldn't load your queue.",
            body: "You're offline, or the metadata service is unreachable.",
            actions: [
              TextButton(
                onPressed: () => ref.invalidate(upNextBoardProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
          data: (board) => board.queue.isEmpty && board.upcoming.isEmpty
              ? const _NothingUpNext()
              : _Board(board: board),
        );
  }
}

/// An empty queue has two causes with opposite advice: a user tracking no shows
/// needs to add one; a user tracking many is caught up. Distinguished off
/// the live library — until it resolves, "caught up" is the safe default (it is
/// the less-wrong thing to tell someone with a full library).
class _NothingUpNext extends ConsumerWidget {
  const _NothingUpNext();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(libraryItemsProvider).value;
    // Backend-agnostic on purpose: the empty-state copy only needs "is there a
    // TV show to be caught up on?", not the active-backend id filter the queue
    // itself applies. Keeps this off remote config (and thus test-friendly).
    final hasShows =
        items != null &&
        items.any(
          (i) =>
              i.mediaType == MediaType.tv &&
              i.trackStatus != TrackStatus.dropped,
        );
    if (items != null && !hasShows) {
      return const EmptyState(
        icon: Icons.tv_off_outlined,
        headline: 'No shows tracked yet',
        body:
            'Add a TV show to your library and its next episode turns up here.',
      );
    }
    // Deliberately does NOT claim "nothing is scheduled". Upcoming is built
    // from `showsForQueue`, which excludes `watchlist` — but `hasShows` counts
    // a watchlist show as tracked. A user whose library is one watchlist show
    // premiering on Friday reaches here, and that claim would be false.
    return const EmptyState(
      icon: Icons.check_circle_outline,
      headline: "You're all caught up",
      body: 'Every tracked show is watched up to its latest aired episode.',
    );
  }
}

/// The page: what you can watch now, then what you're waiting for.
///
/// A section header appears only when its section has rows — except "Ready to
/// watch", which keeps its header and says so inline when the queue is empty
/// but episodes are scheduled. (Both empty is handled upstream by
/// [_NothingUpNext], so at least one section always has content here.)
class _Board extends StatelessWidget {
  const _Board({required this.board});

  final UpNextBoard board;

  @override
  Widget build(BuildContext context) {
    // The board's own clock read, NOT a fresh `clock.now()`: grouping and
    // labelling must agree with the filter that built `upcoming`. See
    // [UpNextBoard].
    final now = board.now;
    final thisWeek = <UpcomingEntry>[];
    final later = <UpcomingEntry>[];
    for (final entry in board.upcoming) {
      (isThisWeek(daysUntil(now, entry.airDate)) ? thisWeek : later).add(entry);
    }

    return CustomScrollView(
      slivers: [
        const _SectionHeader('Ready to watch'),
        if (board.queue.isEmpty)
          // The same message as the full-page empty state, but inline: the page
          // is NOT empty (episodes are scheduled below), there is just nothing
          // aired left to watch. The two never co-render — they are the arms of
          // the ternary in [UpNextScreen].
          const SliverToBoxAdapter(child: _Caption("You're all caught up."))
        else
          _QueueList(entries: board.queue),
        ..._upcomingSection('This week', thisWeek, now),
        ..._upcomingSection('Later', later, now),
      ],
    );
  }

  List<Widget> _upcomingSection(
    String title,
    List<UpcomingEntry> entries,
    DateTime now,
  ) => entries.isEmpty
      ? const []
      : [
          _SectionHeader(title),
          SliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, i) =>
                _UpcomingTile(entry: entries[i], now: now),
          ),
        ];
}

/// The watch queue as an **animated** list. Ticking a row either *advances* it
/// (same show, next aired episode) or *drops* it (caught up). Each library
/// write hands us a whole new immutable [UpNextBoard], so we diff the incoming
/// queue against the rows on screen and drive a [SliverAnimatedList]: an
/// advancing row stays put and its episode label cross-fades (inside
/// [_QueueTile]); a dropped row slides/collapses out and the rows below glide
/// up to fill the gap.
///
/// Not applied to Upcoming — those rows don't mutate on a tick (unaired), so
/// there is nothing to animate there.
///
/// One case isn't animated out: when a tick empties the queue *and* nothing is
/// upcoming, [_Board] swaps this list for the caught-up caption (a different
/// widget), so the final row hard-cuts to the empty state. Animating
/// list→empty-state is fiddly and low value; the 2+-row case is fully animated.
class _QueueList extends StatefulWidget {
  const _QueueList({required this.entries});

  final List<QueueEntry> entries;

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> {
  final _listKey = GlobalKey<SliverAnimatedListState>();

  /// Mirrors exactly what [SliverAnimatedList] is showing — kept in lockstep
  /// with its `insert`/`removeItem` so indices always line up. Seeded from the
  /// first board; thereafter mutated in place only through [_sync].
  late final List<QueueEntry> _rows = List.of(widget.entries);

  static const _tileDuration = Duration(milliseconds: 300);

  /// Honour the OS "reduce motion" setting: fall back to an instant update.
  Duration get _duration =>
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
      ? Duration.zero
      : _tileDuration;

  @override
  void didUpdateWidget(_QueueList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(widget.entries);
  }

  /// Diff [_rows] → [next] and drive the animated list. The queue is sorted by
  /// title (`up_next_providers.dart`) and a tick never changes a title, so
  /// survivors never reorder: a tick is an in-place *advance* (same `itemId`,
  /// value differs) or a *removal* (`itemId` gone); a cache warm-up is an
  /// *insertion* at the show's slot. A remove-missing-then-insert-new pass over
  /// the two title-sorted lists is exact for these cases.
  //
  // ponytail: assumes stable relative order (a title-sorted queue). A genuine
  // reorder would surface as a remove + re-insert, not a move — acceptable
  // given titles don't change on a tick; revisit only if the sort key does.
  void _sync(List<QueueEntry> next) {
    final nextIds = {for (final e in next) e.itemId};

    // Pass 1 — removals, high index → low so the indices stay valid as we go.
    for (var i = _rows.length - 1; i >= 0; i--) {
      if (!nextIds.contains(_rows[i].itemId)) {
        final removed = _rows.removeAt(i);
        _listKey.currentState?.removeItem(
          i,
          (context, animation) => _tile(removed, animation),
          duration: _duration,
        );
      }
    }

    // Pass 2 — advances (same slot, new episode → rebuild + label cross-fade)
    // and insertions.
    for (var i = 0; i < next.length; i++) {
      if (i < _rows.length && _rows[i].itemId == next[i].itemId) {
        if (_rows[i] != next[i]) _rows[i] = next[i];
      } else {
        _rows.insert(i, next[i]);
        _listKey.currentState?.insertItem(i, duration: _duration);
      }
    }
  }

  /// The enter/exit motion: collapse + fade, shared by inserts, removals, and
  /// settled rows (whose animation is already complete, so they show fully).
  Widget _tile(QueueEntry entry, Animation<double> animation) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return SizeTransition(
      sizeFactor: curved,
      child: FadeTransition(
        opacity: curved,
        child: _QueueTile(entry: entry),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SliverAnimatedList(
    key: _listKey,
    initialItemCount: _rows.length,
    itemBuilder: (context, index, animation) => _tile(_rows[index], animation),
  );
}

/// Section heading. Same anatomy as Settings' `_SectionHeader` (titleSmall, in
/// `primary`) but deliberately **bolder** — these divide the page into two
/// different affordances (tickable vs not), where Settings' merely label groups
/// of rows. Not shared: the weight is the whole difference, and one widget with
/// a `bold` flag would be an abstraction that earns nothing.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          WatchnookSpacing.screen,
          WatchnookSpacing.xl,
          WatchnookSpacing.screen,
          WatchnookSpacing.sm,
        ),
        child: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// A muted line of copy standing in for an empty section.
class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WatchnookSpacing.screen,
        0,
        WatchnookSpacing.screen,
        WatchnookSpacing.sm,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A scheduled episode: same shape as a queue row, but the trailing tick is
/// replaced by when it airs.
///
/// **It has no "mark watched" control, and must not grow one.** The episode has
/// not aired; marking it would push `lastWatchedSeason`/`lastWatchedEpisode`
/// past reality and silently drop the real next episode out of the queue.
class _UpcomingTile extends StatelessWidget {
  const _UpcomingTile({required this.entry, required this.now});

  final UpcomingEntry entry;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: _Poster(path: entry.posterPath),
      title: Text(entry.showTitle),
      subtitle: Text(
        episodeLabel(entry.season, entry.episode, entry.episodeTitle),
      ),
      trailing: Text(
        airLabel(entry.airDate, now),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => context.push('/title/${entry.itemId}'),
    );
  }
}

class _QueueTile extends ConsumerWidget {
  const _QueueTile({required this.entry});

  final QueueEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = 'Next: ${episodeLabel(entry.season, entry.episode)}';
    return ListTile(
      leading: _Poster(path: entry.posterPath),
      title: Text(entry.showTitle),
      // When the show advances to its next episode the row stays put and only
      // this coordinate changes — cross-fade it. Keyed by the label so an
      // unrelated rebuild (same episode) doesn't animate.
      subtitle: AnimatedSwitcher(
        duration: (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        child: Text(label, key: ValueKey(label)),
      ),
      // Mark this exact episode watched from the queue; the library stream
      // re-emits and the queue advances this row to the next episode (or drops
      // it when caught up) — no reload needed.
      trailing: IconButton(
        icon: const Icon(Icons.check_circle_outline),
        tooltip: 'Mark watched',
        onPressed: () => ref
            .read(libraryDaoProvider)
            .markWatched(
              entry.itemId,
              season: entry.season,
              episode: entry.episode,
              watchedAt: clock.now(),
            ),
      ),
      // Detail is a pushed route keyed by the library row id (AD-5).
      onTap: () => context.push('/title/${entry.itemId}'),
    );
  }
}

/// Show thumbnail — the same offline-safe poster the search + import rows use.
class _Poster extends ConsumerWidget {
  const _Poster({required this.path});

  final String? path;

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
