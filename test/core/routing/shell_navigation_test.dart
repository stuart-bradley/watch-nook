import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/routing/app_router.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';
import 'package:watch_nook/features/search/presentation/search_screen.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';
import 'package:watch_nook/features/stats/presentation/stats_providers.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';

/// #22 — the AD-5 nav shell, which every per-issue test mounts *past* (each one
/// pumps its screen directly). Here the real `appRoutes` are mounted so the
/// wiring between screens is exercised: the two shell tabs, the app-bar search
/// action, and the grid card's `/title/:id` push.
///
/// Adversarial framing:
/// - The card-tap test asserts on the **route's** id: `libraryItemProvider`
///   serves the row for id 7 and `null` for anything else, so a card that
///   pushes the wrong field (a tmdbId, an index) lands on the "no longer in
///   your library" notice and fails.
/// - Both DB-backed providers are overridden with synchronous streams — a live
///   Drift `.watch()` never quiesces under fake-async and would hang
///   `pumpAndSettle` (CLAUDE.md testing note).

/// The detail screen's mandatory attribution footer reads the active source, so
/// it must be stubbed or the real one boots remote config. Only `attribution()`
/// is reachable here: the routed row carries no source id, so nothing fetches.
class _StubSource implements MetadataSource {
  @override
  Attribution attribution() =>
      const Attribution(notice: 'Fake', linkUrl: 'https://example.org/');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  final now = DateTime(2026, 7, 9);

  // tmdbId is null (with `recordedSource` tmdb) so `detailSourceId` is null and
  // the detail screen fetches no metadata — this test is about routing only.
  // posterPath is null so no card image resolves a URL.
  final item = LibraryItem(
    id: 7,
    mediaType: MediaType.tv,
    recordedSource: MetadataSourceKind.tmdb,
    title: 'Severance',
    trackStatus: TrackStatus.watching,
    watchedCount: 0,
    addedAt: now,
    updatedAt: now,
    relinkFailed: false,
  );

  late GoRouter router;
  setUp(() => router = GoRouter(routes: appRoutes, initialLocation: '/'));
  tearDown(() => router.dispose());

  /// `state.uri` (the last match), not `currentConfiguration.uri` — an
  /// imperative `push` appends a match and leaves the configuration's uri at
  /// the shell branch it was pushed from.
  String location() => router.state.uri.toString();

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeMetadataSourceProvider.overrideWithValue(_StubSource()),
          libraryGridProvider.overrideWith(
            (ref, filter) => Stream.value([item]),
          ),
          upNextBoardProvider.overrideWith(
            (ref) async => (
              queue: <QueueEntry>[],
              upcoming: <UpcomingEntry>[],
              now: DateTime(2026, 7, 14),
            ),
          ),
          // Read by the Up Next empty state; the real one is a live Drift
          // `.watch()` stream and would hang `pumpAndSettle` (CLAUDE.md).
          libraryItemsProvider.overrideWith(
            (ref) => Stream.value(const <LibraryItem>[]),
          ),
          statsProvider.overrideWith(
            (ref) => Stream.value(StatsSnapshot.empty),
          ),
          libraryItemProvider.overrideWith(
            (ref, id) => Stream.value(id == item.id ? item : null),
          ),
          watchedEpisodesProvider.overrideWith(
            (ref, id) => Stream.value(const <(int, int)>{}),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  int selectedTab(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  testWidgets('the bottom nav switches between the three shell tabs', (
    tester,
  ) async {
    await pumpShell(tester);

    // Mounted at '/' (Library) — now the second tab; Up Next is first. The
    // shell titles each tab, so the app bar tracks the active branch.
    expect(selectedTab(tester), 1);
    expect(find.text('Severance'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Library'), findsOneWidget);

    await tester.tap(find.text('Up Next'));
    await tester.pumpAndSettle();

    expect(location(), '/up-next');
    expect(selectedTab(tester), 0);
    expect(find.text('No shows tracked yet'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Up Next'), findsOneWidget);

    await tester.tap(find.text('Stats'));
    await tester.pumpAndSettle();

    expect(location(), '/stats');
    expect(selectedTab(tester), 2);
    // The empty snapshot — this asserts the tab resolves, not what it computes.
    expect(find.text('No stats yet'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Stats'), findsOneWidget);

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();

    expect(location(), '/');
    expect(selectedTab(tester), 1);
    expect(find.text('Severance'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Library'), findsOneWidget);
  });

  testWidgets('the app-bar search action pushes the search route', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    expect(location(), '/search');
    expect(find.byType(SearchScreen), findsOneWidget);
    // Search is pushed *over* the shell, so the tab bar goes with it.
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets("tapping a grid card opens that row's detail route", (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    expect(location(), '/title/7');
    expect(find.widgetWithText(AppBar, 'Severance'), findsOneWidget);
    expect(find.text('This title is no longer in your library.'), findsNothing);
  });
}
