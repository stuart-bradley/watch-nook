import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` lives in the misc barrel, not the main one.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';
import 'package:watch_nook/features/search/presentation/search_screen.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';
import 'package:watch_nook/features/stats/presentation/stats_providers.dart';
import 'package:watch_nook/features/stats/presentation/stats_screen.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';
import 'package:watch_nook/features/up_next/presentation/up_next_screen.dart';

/// #35 / US-13: every screen that can be empty says something *specific*.
///
/// Adversarial framing: the easy bug is one shared "Nothing here yet" string
/// reused everywhere. That reads fine on a fresh install and is a lie in every
/// other case — it tells a user with 300 titles that their library is empty
/// because a filter matched nothing, and a user tracking twelve shows that they
/// track none. So each test below asserts the **distinguishing** copy, and the
/// two library cases and two Up Next cases are asserted to differ from each
/// other.
///
/// Every DB-backed provider is overridden with a synchronous stream — a live
/// Drift `.watch()` never quiesces under fake-async and would hang
/// `pumpAndSettle` for its full 10-minute timeout (CLAUDE.md).
class _ThrowingSource implements MetadataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('an empty state must not reach the metadata source');
}

/// The one screen that legitimately *does* call the source. It finds nothing.
class _BarrenSource implements MetadataSource {
  @override
  Future<List<MediaSearchResult>> search(String query, {MediaKind? kind}) async
      => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  /// Every empty state renders an [EmptyState]; asserting on its headline keeps
  /// these tests about the *copy*, which is the thing that regresses.
  Future<void> pump(
    WidgetTester tester,
    Widget child,
    List<Override> overrides, {
    MetadataSource? source,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Default: reaching the network from an empty state is a bug.
          activeMetadataSourceProvider.overrideWithValue(
            source ?? _ThrowingSource(),
          ),
          ...overrides,
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('library grid', () {
    Future<void> pumpGrid(WidgetTester tester) => pump(
      tester,
      const LibraryScreen(),
      [
        libraryGridProvider.overrideWith(
          (ref, filter) => Stream.value(const <LibraryItem>[]),
        ),
      ],
    );

    testWidgets('an empty library invites a search or an import', (
      tester,
    ) async {
      await pumpGrid(tester);

      expect(find.text('Your library is empty'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Search'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Import'), findsOneWidget);
    });

    testWidgets('an empty *filter result* says something else entirely', (
      tester,
    ) async {
      await pumpGrid(tester);
      expect(find.text('Your library is empty'), findsOneWidget);

      // Narrow to a type nothing matches — same empty list, different cause.
      await tester.tap(find.text('Films'));
      await tester.pumpAndSettle();

      // The regression this whole split exists to catch: one shared string.
      expect(find.text('Nothing matches this filter'), findsOneWidget);
      expect(find.text('Your library is empty'), findsNothing);
      // Nothing to search for — the CTAs belong to the empty *library*.
      expect(find.widgetWithText(FilledButton, 'Search'), findsNothing);
    });
  });

  group('up next', () {
    Future<void> pumpUpNext(
      WidgetTester tester, {
      required List<TrackedShow> tracked,
    }) => pump(
      tester,
      const UpNextScreen(),
      [
        trackedShowsProvider.overrideWith((ref) => Stream.value(tracked)),
        upcomingThisWeekProvider.overrideWith(
          (ref) async => const <UpcomingEntry>[],
        ),
      ],
    );

    testWidgets('a user tracking no shows is told to add one', (tester) async {
      await pumpUpNext(tester, tracked: const []);

      expect(find.text('No shows tracked yet'), findsOneWidget);
      expect(find.text('Nothing airing this week'), findsNothing);
    });

    // Same empty list, opposite advice. Sharing one string here would tell a
    // user tracking twelve shows that they track none.
    testWidgets('a user tracking shows with nothing airing gets other copy', (
      tester,
    ) async {
      await pumpUpNext(
        tester,
        tracked: const [(sourceId: 1, itemId: 1, title: 'Severance')],
      );

      expect(find.text('Nothing airing this week'), findsOneWidget);
      expect(find.text('No shows tracked yet'), findsNothing);
    });

    // Before the tracked set resolves we cannot know which case we are in.
    // Guessing "you track no shows" at a user with a full library is the worse
    // mistake, so the neutral copy is the default.
    testWidgets('an unresolved tracked set falls back to the neutral copy', (
      tester,
    ) async {
      await pump(
        tester,
        const UpNextScreen(),
        [
          trackedShowsProvider.overrideWith(
            (ref) => const Stream<List<TrackedShow>>.empty(),
          ),
          upcomingThisWeekProvider.overrideWith(
            (ref) async => const <UpcomingEntry>[],
          ),
        ],
      );
      expect(find.text('Nothing airing this week'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('no query prompts for one; a fruitless query names it', (
      tester,
    ) async {
      await pump(tester, const SearchScreen(), [], source: _BarrenSource());
      expect(find.text('Search for a film or show to track.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzzqqq');
      // Past the 350ms debounce.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('No results'), findsOneWidget);
      expect(find.textContaining('zzzqqq'), findsWidgets);
    });
  });

  group('stats', () {
    testWidgets('no watch events shows the empty state, not a "0 h" card', (
      tester,
    ) async {
      await pump(
        tester,
        const StatsScreen(),
        [
          statsProvider.overrideWith(
            (ref) => Stream.value(StatsSnapshot.empty),
          ),
        ],
      );
      expect(find.text('No stats yet'), findsOneWidget);
    });
  });
}
