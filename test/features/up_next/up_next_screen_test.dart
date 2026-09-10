import 'dart:async';

import 'package:clock/clock.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/library/unverified_position.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_source.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/core/widgets/empty_state.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';
import 'package:watch_nook/features/up_next/presentation/up_next_screen.dart';

import '../../support/library_fixtures.dart' as seed;

/// #21 + R4 at the widget layer — the watch queue AND upcoming, on one page.
/// `upNextBoardProvider` and the live `libraryItemsProvider` are overridden
/// (never the real DB/network): the real library stream is a live Drift
/// `.watch()` that never quiesces under fake async and would hang
/// `pumpAndSettle` (ARCHITECTURE.md).
///
/// Adversarial: the offline path renders a recoverable error, not a blank
/// screen; the tick marks the exact coordinate; the two empty states differ;
/// and **an unaired episode is never tickable**.

/// A Tuesday, so the weekday labels below are stable.
final _now = DateTime(2026, 7, 14);

LibraryItem _libItem({int id = 1, TrackStatus status = TrackStatus.watching}) =>
    LibraryItem(
      id: id,
      mediaType: MediaType.tv,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Item $id',
      trackStatus: status,
      tmdbId: 100 + id,
      watchedCount: 0,
      addedAt: DateTime(2026),
      updatedAt: DateTime(2026),
      relinkFailed: false,
    );

/// [CachingMetadataSource.cachedShowDetails] over a fixed map. An id it lacks
/// is omitted, as a cold cache would omit it.
class _FakeRepo implements CachingMetadataSource {
  _FakeRepo(this.byId);

  final Map<int, MediaDetails> byId;

  @override
  Future<Map<int, MediaDetails>> cachedShowDetails(
    Iterable<SourceRef> shows,
  ) async => {for (final show in shows) show.id: ?byId[show.id]};

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  QueueEntry entry({
    int itemId = 1,
    String show = 'Severance',
    int season = 2,
    int episode = 5,
    bool unverified = false,
  }) => (
    itemId: itemId,
    showTitle: show,
    poster: null, // null → placeholder, so the poster never hits network
    season: season,
    episode: episode,
    unverified: unverified,
  );

  UpcomingEntry soon({
    required DateTime airDate,
    required String show,
    int itemId = 1,
    int season = 3,
    int episode = 1,
    String? title,
  }) => (
    itemId: itemId,
    showTitle: show,
    poster: null,
    season: season,
    episode: episode,
    episodeTitle: title,
    airDate: airDate,
  );

  Future<void> pumpWith(
    WidgetTester tester,
    Future<UpNextBoard> Function(Ref) board, {
    List<LibraryItem> items = const [],
    AppDatabase? db,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        upNextBoardProvider.overrideWith(board),
        libraryItemsProvider.overrideWith((ref) => Stream.value(items)),
        activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
        if (db != null) appDatabaseProvider.overrideWithValue(db),
      ],
      child: const MaterialApp(home: Scaffold(body: UpNextScreen())),
    ),
  );

  // A controllable variant of [pumpWith]: `libraryItemsProvider` is backed by a
  // caller-owned StreamController, so a test can drive a *reload* (the tick's
  // library re-emit) — a fixed `Stream.value` can't. The board override watches
  // `libraryItemsProvider` and derives the queue from the live items.
  Future<void> pumpLive(
    WidgetTester tester, {
    required StreamController<List<LibraryItem>> items,
    required Future<UpNextBoard> Function(Ref) board,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        libraryItemsProvider.overrideWith((ref) => items.stream),
        upNextBoardProvider.overrideWith(board),
        activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
      ],
      child: const MaterialApp(home: Scaffold(body: UpNextScreen())),
    ),
  );

  testWidgets('renders a queue card per show with its next episode', (
    tester,
  ) async {
    await pumpWith(
      tester,
      (ref) async => (
        queue: [
          entry(show: 'One Piece', season: 1, episode: 14),
          entry(show: 'Taskmaster', itemId: 2),
        ],
        upcoming: <UpcomingEntry>[],
        now: _now,
      ),
      items: [_libItem(), _libItem(id: 2)],
    );
    await tester.pumpAndSettle();

    expect(find.text('One Piece'), findsOneWidget);
    expect(find.text('Next: S1E14'), findsOneWidget);
    expect(find.text('Taskmaster'), findsOneWidget);
    expect(find.text('Next: S2E5'), findsOneWidget);
    // Every card offers a mark-watched tick.
    expect(find.byTooltip('Mark watched'), findsNWidgets(2));
  });

  // The subtitle cross-fades via an AnimatedSwitcher (R2/US-3), whose default
  // layoutBuilder centres its child — which centred "Next: SxEy" under the
  // title, a regression shipped in the animation release. Assert the rendered
  // subtitle shares the title's left edge (start-aligned), whatever the impl.
  testWidgets('queue subtitle stays start-aligned under the title', (
    tester,
  ) async {
    await pumpWith(
      tester,
      (ref) async => (
        queue: [entry(show: 'One Piece', season: 1, episode: 14)],
        upcoming: <UpcomingEntry>[],
        now: _now,
      ),
      items: [_libItem()],
    );
    await tester.pumpAndSettle();

    final titleLeft = tester.getTopLeft(find.text('One Piece')).dx;
    final subtitleLeft = tester.getTopLeft(find.text('Next: S1E14')).dx;
    expect(subtitleLeft, moreOrLessEquals(titleLeft, epsilon: 1));
  });

  testWidgets('the tick marks exactly that coordinate watched', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = (await seed.seedShow(
      db,
      title: 'One Piece',
      tmdbId: 37854,
    )).id;

    await pumpWith(
      tester,
      (ref) async => (
        queue: [entry(itemId: id, show: 'One Piece', season: 1, episode: 14)],
        upcoming: <UpcomingEntry>[],
        now: _now,
      ),
      items: [_libItem(id: id)],
      db: db,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Mark watched'));
    await tester.pumpAndSettle();

    final events = await db.select(db.watchEvents).get();
    expect(
      events.any((e) => e.seasonNumber == 1 && e.episodeNumber == 14),
      isTrue,
      reason: 'the tick marked exactly the queued coordinate',
    );
  });

  // R1/US-1 — THE flicker guard. Ticking re-emits `libraryItemsProvider`, which
  // *reloads* `upNextBoardProvider`; the default `skipLoadingOnReload: false`
  // flashes the full-screen spinner over the queue during that reload — the
  // "flicker". This drives a REAL reload (a fixed-Future override can't reload,
  // so the guard would be un-provable) and holds it open on a gate so the
  // mid-reload frame is deterministic. It goes red if the fix is removed.
  testWidgets('a reload keeps the queue on screen instead of a spinner', (
    tester,
  ) async {
    final items = StreamController<List<LibraryItem>>();
    addTearDown(items.close);
    // First load resolves at once; the reload is held on a fresh gate so the
    // board sits in AsyncLoading(reloading) while we inspect the frame.
    var gate = Completer<void>()..complete();

    await pumpLive(
      tester,
      items: items,
      board: (ref) async {
        final libItems = await ref.watch(libraryItemsProvider.future);
        await gate.future;
        return (
          queue: [
            for (final it in libItems)
              entry(itemId: it.id, show: it.title, season: 1, episode: 1),
          ],
          upcoming: <UpcomingEntry>[],
          now: _now,
        );
      },
    );

    items.add([_libItem(), _libItem(id: 2)]);
    await tester.pumpAndSettle();
    expect(find.text('Item 1'), findsOneWidget);
    expect(find.text('Item 2'), findsOneWidget);

    // Trigger a reload (Item 1 caught up → it will drop) and hold it open.
    gate = Completer<void>();
    items.add([_libItem(id: 2)]);
    await tester.pump(); // deliver the re-emit; the board is now mid-reload
    await tester.pump(); // settle the rebuild into the reloading state

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'skipLoadingOnReload keeps the loaded queue — no spinner flash',
    );
    expect(
      find.text('Item 1'),
      findsOneWidget,
      reason: 'the previous queue stays on screen during the reload',
    );

    // Let the reload finish → the new queue swaps in seamlessly (proves the
    // reload really happened: without it, Item 1 would never leave).
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Item 1'), findsNothing);
    expect(find.text('Item 2'), findsOneWidget);
  });

  // R2/US-3 — an advancing show keeps its row; only the episode label changes
  // (it cross-fades). Driven through a real reload, as the tick is at runtime.
  testWidgets('advancing a show keeps its row and updates the label', (
    tester,
  ) async {
    final items = StreamController<List<LibraryItem>>();
    addTearDown(items.close);
    // The board reads each show's next episode from this mutable map, so a
    // re-emit after we "advance" a show yields the next coordinate. The gate
    // holds the advance reload open so we can inspect a deterministic
    // mid-animation frame (see below).
    var eps = <int, (int, int)>{1: (1, 14), 2: (2, 5)};
    var gate = Completer<void>()..complete();

    await pumpLive(
      tester,
      items: items,
      board: (ref) async {
        final libItems = await ref.watch(libraryItemsProvider.future);
        await gate.future;
        return (
          queue: [
            for (final it in libItems)
              entry(
                itemId: it.id,
                show: it.title,
                season: eps[it.id]!.$1,
                episode: eps[it.id]!.$2,
              ),
          ],
          upcoming: <UpcomingEntry>[],
          now: _now,
        );
      },
    );

    items.add([_libItem(), _libItem(id: 2)]);
    await tester.pumpAndSettle();
    expect(find.text('Next: S1E14'), findsOneWidget);

    // Advance show 1, holding the reload so the diff+animation start on a frame
    // we control.
    eps = {1: (1, 15), 2: (2, 5)};
    gate = Completer<void>();
    items.add([_libItem(), _libItem(id: 2)]);
    await tester.pump(); // board reloads, now awaiting the gate
    gate.complete();
    await tester.pump(); // gate resolves → the diff runs, animations begin
    await tester.pump(const Duration(milliseconds: 120)); // mid-animation

    // The behaviour under test: an advance updates the row IN PLACE — it never
    // inserts or removes — so there is exactly ONE 'Item 1' row throughout. A
    // regression that turned an advance into a remove+re-insert (the row
    // blinking out and back — the flicker this list exists to avoid) would
    // render TWO mid-animation: the exiting ghost and the entering row. The
    // settled text is identical either way, so this mid-animation count is what
    // actually guards "keeps its row"; a settle-only assertion can't.
    expect(
      find.text('Item 1'),
      findsOneWidget,
      reason: 'advance keeps a single row — no remove+re-insert blink',
    );

    await tester.pumpAndSettle();
    expect(find.text('Item 1'), findsOneWidget); // the row is still there
    expect(find.text('Next: S1E15'), findsOneWidget); // label advanced
    expect(find.text('Next: S1E14'), findsNothing);
  });

  // R2/US-4 — a caught-up show leaves the queue (slides/collapses out) while the
  // survivor remains. pumpAndSettle covers the exit animation.
  testWidgets('a caught-up show drops out and the survivor remains', (
    tester,
  ) async {
    final items = StreamController<List<LibraryItem>>();
    addTearDown(items.close);

    await pumpLive(
      tester,
      items: items,
      board: (ref) async {
        final libItems = await ref.watch(libraryItemsProvider.future);
        return (
          queue: [
            for (final it in libItems)
              entry(itemId: it.id, show: it.title, season: 1, episode: 1),
          ],
          upcoming: <UpcomingEntry>[],
          now: _now,
        );
      },
    );

    items.add([_libItem(), _libItem(id: 2)]);
    await tester.pumpAndSettle();
    expect(find.text('Item 1'), findsOneWidget);
    expect(find.text('Item 2'), findsOneWidget);

    // Show 1 is now caught up → it drops from the queue.
    items.add([_libItem(id: 2)]);
    await tester.pumpAndSettle(); // includes the collapse/fade-out animation

    expect(find.text('Item 1'), findsNothing);
    expect(find.text('Item 2'), findsOneWidget);
  });

  testWidgets(
    'caught up (nothing aired, nothing scheduled) → caught-up state',
    (
      tester,
    ) async {
      await pumpWith(
        tester,
        (ref) async =>
            (queue: <QueueEntry>[], upcoming: <UpcomingEntry>[], now: _now),
        items: [_libItem()], // a tracked show, but nothing to watch
      );
      await tester.pumpAndSettle();

      expect(find.text("You're all caught up"), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    },
  );

  testWidgets('no tracked shows → the add-a-show empty state', (tester) async {
    await pumpWith(
      tester,
      (ref) async =>
          (queue: <QueueEntry>[], upcoming: <UpcomingEntry>[], now: _now),
    );
    await tester.pumpAndSettle();

    expect(find.text('No shows tracked yet'), findsOneWidget);
    expect(find.text("You're all caught up"), findsNothing);
  });

  testWidgets('a failed (offline) fetch renders a retryable error state', (
    tester,
  ) async {
    await pumpWith(
      tester,
      (ref) => Future<UpNextBoard>.error(StateError('offline')),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load your queue."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('upcoming (R4)', () {
    testWidgets('groups scheduled episodes into This week and Later', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await pumpWith(
          tester,
          (ref) async => (
            queue: [entry(show: 'One Piece', season: 1, episode: 14)],
            upcoming: [
              soon(
                show: 'The Last of Us',
                itemId: 2,
                title: 'Convergence',
                airDate: _now, // today
              ),
              soon(
                show: 'The Bear',
                itemId: 3,
                airDate: DateTime(2026, 7, 17), // Friday, this week
              ),
              soon(
                show: 'Severance',
                itemId: 4,
                title: 'Cold Harbor',
                airDate: DateTime(2026, 12, 3), // later
              ),
            ],
            now: _now,
          ),
          items: [_libItem()],
        );
        await tester.pumpAndSettle();

        expect(find.text('Ready to watch'), findsOneWidget);
        expect(find.text('This week'), findsOneWidget);
        expect(find.text('Later'), findsOneWidget);

        // Dated relative inside the week, absolute beyond it.
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('Friday'), findsOneWidget);
        expect(find.text('3 Dec'), findsOneWidget);

        // An upcoming row carries the episode title the queue never had.
        expect(find.text('S3E1 · Convergence'), findsOneWidget);
        expect(find.text('S3E1 · Cold Harbor'), findsOneWidget);
      });
    });

    // THE guard for this feature. An unaired episode must never be tickable:
    // marking it would push lastWatchedSeason/lastWatchedEpisode past reality
    // and silently drop the genuinely-next episode out of the queue. The queue
    // row here has a tick; the two upcoming rows must not.
    testWidgets('an upcoming row offers NO mark-watched tick', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await pumpWith(
          tester,
          (ref) async => (
            queue: [entry(show: 'One Piece')],
            upcoming: [
              soon(show: 'The Bear', itemId: 2, airDate: DateTime(2026, 7, 17)),
              soon(
                show: 'Severance',
                itemId: 3,
                airDate: DateTime(2026, 12, 3),
              ),
            ],
            now: _now,
          ),
          items: [_libItem()],
        );
        await tester.pumpAndSettle();

        expect(find.byType(ListTile), findsNWidgets(3));
        expect(
          find.byTooltip('Mark watched'),
          findsOneWidget,
          reason: 'only the ONE aired queue row may be ticked',
        );
      });
    });

    // The headline case: caught up on everything aired, but a season is coming.
    // Today this user sees a bare "You're all caught up" and nothing else — the
    // whole reason for the feature. The page must NOT fall back to the
    // full-page empty state just because the queue is empty.
    testWidgets(
      'an empty queue with scheduled episodes is not the empty state',
      (
        tester,
      ) async {
        await withClock(Clock.fixed(_now), () async {
          await pumpWith(
            tester,
            (ref) async => (
              queue: <QueueEntry>[],
              upcoming: [
                soon(show: 'Severance', airDate: DateTime(2026, 12, 3)),
              ],
              now: _now,
            ),
            items: [_libItem()],
          );
          await tester.pumpAndSettle();

          expect(find.text('Severance'), findsOneWidget);
          expect(find.text('Later'), findsOneWidget);
          expect(find.text("You're all caught up."), findsOneWidget);
          // The INLINE caption, not the full-page empty state — which would
          // hide the upcoming rows entirely. (Its headline is the same words
          // without the full stop, so assert on the widget, not the string.)
          expect(find.byType(EmptyState), findsNothing);
        });
      },
    );

    // The board carries the instant it was computed, and the screen groups and
    // labels from THAT — never a fresh `clock.now()` at build time. Here the
    // ambient clock is a day AHEAD of the board's `now` (the tab left open
    // across midnight and rebuilt without the provider re-running). Reading the
    // ambient clock would make this episode -1 days away: it would fall out of
    // "This week" into "Later" and be labelled with a date in the past.
    testWidgets('groups from the board clock, not a fresh one', (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 7, 15)), () async {
        await pumpWith(
          tester,
          (ref) async => (
            queue: <QueueEntry>[],
            upcoming: [soon(show: 'Severance', airDate: _now)],
            now: _now, // computed yesterday, relative to the ambient clock
          ),
          items: [_libItem()],
        );
        await tester.pumpAndSettle();

        expect(find.text('This week'), findsOneWidget);
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('Later'), findsNothing);
      });
    });

    testWidgets('an empty group renders no header', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await pumpWith(
          tester,
          (ref) async => (
            queue: <QueueEntry>[],
            upcoming: [
              soon(show: 'Severance', airDate: DateTime(2026, 7, 15)),
            ], // tomorrow only
            now: _now,
          ),
          items: [_libItem()],
        );
        await tester.pumpAndSettle();

        expect(find.text('This week'), findsOneWidget);
        expect(find.text('Later'), findsNothing);
      });
    });
  });

  // Wiring coverage. The rule itself is tested at unverified_position.dart;
  // what is worth asserting here is that the screen most likely to make the
  // user act on a suspect coordinate actually renders the marker.
  //
  // Proved to fail first: pinning the queue tile's `unverified:` argument to
  // false (so the carried flag is ignored on the way to the label) reddens it.
  // Note the provider-level proof in up_next_providers_test does NOT reach
  // this — it builds entries directly — which is why it needs its own.
  group('an Unverified position is marked', () {
    testWidgets('the queue row carries it; a healthy row does not', (
      tester,
    ) async {
      await pumpWith(
        tester,
        (ref) async => (
          queue: [
            entry(show: 'Doubtful', season: 1, episode: 14, unverified: true),
            entry(show: 'Healthy', itemId: 2, season: 1, episode: 14),
          ],
          upcoming: <UpcomingEntry>[],
          now: _now,
        ),
        items: [_libItem(), _libItem(id: 2)],
      );
      await tester.pumpAndSettle();

      final marked = markUnverifiedPosition('S1E14', unverified: true);
      expect(find.text('Next: $marked'), findsOneWidget);
      expect(find.text('Next: S1E14'), findsOneWidget);
    });
  });

  // The marker describes the coordinate on its own row, and nothing else. A
  // queue coordinate is derived from the stored position ("the episode after
  // the last one watched"), so the doubt applies. An upcoming coordinate is the
  // active backend's own next-to-air episode, fetched fresh, and it has nothing
  // to do with the user's history. Marking it would be a false claim, made on
  // the screen the user trusts to say what airs next.
  //
  // Driven through the REAL board provider over a fake repository. That is the
  // only seam where "queue marked, upcoming unmarked" can be asserted in one
  // render and actually fail. A hand-built UpcomingEntry cannot carry a flag at
  // all, so a test that built one would have nothing to catch.
  //
  // The clock is fixed around the pump, because the board reads `clock.now()`.
  // The fixtures' July air dates are the proof that it bites: under real time
  // they are in the past and no upcoming row would render at all.
  //
  // The in-memory DB is only for seeding: `seedShow` derives each row's
  // position through the real watch writes, so no fixture invents one. The
  // library stream itself is NOT the live Drift watch (it never quiesces under
  // fake async); it is a fixed `Stream.value` of the seeded rows.
  //
  // Proved to fail first: run against the previous `upcomingFor`, which set
  // `unverified: hasUnverifiedPosition(item)` and passed it to the upcoming
  // tile's label. That marks Doubtful's S1E4, and this goes red.
  //
  // Unstarted is here for the OTHER wrong reading of the old spec, "mark every
  // Unverified show" (`relinkFailed && tv`, position or not). The old code
  // never took that reading, so Unstarted could not redden against it. Proved
  // separately: queue entries built with `relinkFailed && tv` mark Unstarted's
  // "Next: S1E1", and this goes red.
  testWidgets('an Unverified show: its queue row is marked, its upcoming row '
      'is not', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    MediaDetails scheduled(
      List<(int, int)> seasons,
      (int, int) next,
    ) => MediaDetails(
      kind: MediaKind.tv,
      title: 'A Show',
      genres: const [],
      seasons: [
        for (final (n, c) in seasons)
          SeasonInfo(seasonNumber: n, episodeCount: c),
      ],
      nextEpisode: EpisodeInfo(
        seasonNumber: next.$1,
        episodeNumber: next.$2,
        airDate: DateTime(2026, 7, 17), // Friday, inside the week
      ),
    );

    final items = [
      // Watched S1E1; S1E2–3 aired, S1E4 scheduled. In BOTH lists.
      await seed.seedShow(
        db,
        title: 'Doubtful',
        tmdbId: 1,
        relinkFailed: true,
        watched: const [(1, 1)],
      ),
      // Unverified but never started: no position, so nothing is marked.
      await seed.seedShow(
        db,
        title: 'Unstarted',
        tmdbId: 2,
        relinkFailed: true,
      ),
      // The control: the same shape, trusted.
      await seed.seedShow(
        db,
        title: 'Healthy',
        tmdbId: 3,
        watched: const [(2, 1)],
      ),
    ];
    final repo = _FakeRepo({
      1: scheduled([(1, 10)], (1, 4)),
      2: scheduled([(1, 10), (2, 10), (3, 10)], (3, 1)),
      3: scheduled([(1, 10), (2, 10)], (2, 5)),
    });

    await withClock(Clock.fixed(_now), () async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryItemsProvider.overrideWith((ref) => Stream.value(items)),
            activeMetadataBackendProvider.overrideWithValue(
              MetadataBackend.tmdb,
            ),
            metadataProvider.overrideWithValue(repo),
            appDatabaseProvider.overrideWithValue(db),
          ],
          child: const MaterialApp(home: Scaffold(body: UpNextScreen())),
        ),
      );
      await tester.pumpAndSettle();
    });

    String marked(String position) =>
        markUnverifiedPosition(position, unverified: true);

    // Doubtful, in both lists.
    expect(find.text('Next: ${marked('S1E2')}'), findsOneWidget);
    expect(find.text('S1E4'), findsOneWidget, reason: 'its upcoming row');
    // Unstarted: a queue row and an upcoming row, neither with a position.
    expect(find.text('Next: S1E1'), findsOneWidget);
    expect(find.text('S3E1'), findsOneWidget);
    // Healthy: both unmarked, as before.
    expect(find.text('Next: S2E2'), findsOneWidget);
    expect(find.text('S2E5'), findsOneWidget);

    expect(
      find.textContaining(marked('').trim()),
      findsOneWidget,
      reason: "the whole page carries ONE marker: Doubtful's queue row",
    );
  });
}
