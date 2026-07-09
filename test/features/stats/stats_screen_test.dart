import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';
import 'package:watch_nook/features/stats/presentation/stats_providers.dart';
import 'package:watch_nook/features/stats/presentation/stats_screen.dart';

/// #34 widget layer. `statsProvider` is overridden with a **synchronous**
/// `Stream.value` — a live Drift `.watch()` never quiesces under fake-async and
/// `pumpAndSettle` would hang for its whole timeout (CLAUDE.md testing note).
///
/// Adversarial framing:
/// - an empty history renders a bare `0 h` card, so a first-run user thinks the
///   app is broken instead of being told to go watch something;
/// - the honesty footnote is always on (or never on), rather than exactly when
///   a fact is actually missing;
/// - a breakdown with no buckets still renders its heading.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  /// A fresh `key` per pump: re-pumping into the same `ProviderScope` element
  /// reuses its container, so a second call with a different override would
  /// keep serving the first snapshot.
  Future<void> pump(WidgetTester tester, StatsSnapshot stats) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          statsProvider.overrideWith((ref) => Stream.value(stats)),
        ],
        child: const MaterialApp(home: Scaffold(body: StatsScreen())),
      ),
    );
    await tester.pumpAndSettle();
  }

  const populated = StatsSnapshot(
    episodesWatched: 1284,
    moviesWatched: 42,
    rewatches: 7,
    timeWatched: Duration(hours: 642),
    streakDays: 9,
    byGenre: [StatBucket('Drama', 820), StatBucket('Sci-Fi', 640)],
    byDecade: [StatBucket('2020s', 700), StatBucket('2010s', 880)],
    hasMissingData: false,
  );

  testWidgets('the headline cards, streak and breakdowns render', (
    tester,
  ) async {
    await pump(tester, populated);

    expect(find.text('1,284'), findsOneWidget);
    expect(find.text('Episodes'), findsOneWidget);
    expect(find.text('642 h'), findsOneWidget);
    expect(find.text('Watched'), findsOneWidget);

    expect(find.text('42 films · 7 rewatches'), findsOneWidget);

    expect(find.text('9'), findsOneWidget);
    expect(find.text('day streak — keep it going'), findsOneWidget);

    expect(find.text('By genre'), findsOneWidget);
    expect(find.text('Drama'), findsOneWidget);
    expect(find.text('820'), findsOneWidget);
    expect(find.text('Sci-Fi'), findsOneWidget);

    expect(find.text('By decade'), findsOneWidget);
    expect(find.text('2020s'), findsOneWidget);
    expect(find.text('2010s'), findsOneWidget);
  });

  testWidgets('bars are normalized against the biggest bucket', (tester) async {
    await pump(tester, populated);

    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .toList();

    // Genre bars first (820/820, 640/820), then decade (700/880, 880/880).
    expect(bars, hasLength(4));
    expect(bars[0].value, 1.0);
    expect(bars[1].value, closeTo(640 / 820, 1e-9));
    expect(bars[2].value, closeTo(700 / 880, 1e-9));
    expect(bars[3].value, 1.0);
  });

  testWidgets('an empty history shows the empty state, not a 0 h card', (
    tester,
  ) async {
    await pump(tester, StatsSnapshot.empty);

    expect(find.text('No stats yet'), findsOneWidget);
    expect(
      find.text('Mark something watched and your history shows up here.'),
      findsOneWidget,
    );
    expect(find.text('0 h'), findsNothing);
    expect(find.text('Episodes'), findsNothing);
  });

  testWidgets('the footnote appears only when a fact is missing', (
    tester,
  ) async {
    const footnote = 'Some titles have no runtime or genre data.';

    await pump(tester, populated);
    expect(find.text(footnote), findsNothing);

    await pump(tester, _copyWithMissing(populated));
    expect(find.text(footnote), findsOneWidget);
  });

  testWidgets('a breakdown with no buckets renders no heading', (tester) async {
    // The imported-library shape: counts, but no genres (see
    // stats_after_import_test.dart).
    const imported = StatsSnapshot(
      episodesWatched: 3,
      moviesWatched: 0,
      rewatches: 0,
      timeWatched: Duration.zero,
      streakDays: 0,
      byGenre: [],
      byDecade: [StatBucket('2010s', 3)],
      hasMissingData: true,
    );
    await pump(tester, imported);

    expect(find.text('By genre'), findsNothing);
    expect(find.text('By decade'), findsOneWidget);
    expect(find.text('0 h'), findsOneWidget);
    expect(find.text('day streak — watch something today'), findsOneWidget);
  });
}

StatsSnapshot _copyWithMissing(StatsSnapshot stats) => StatsSnapshot(
  episodesWatched: stats.episodesWatched,
  moviesWatched: stats.moviesWatched,
  rewatches: stats.rewatches,
  timeWatched: stats.timeWatched,
  streakDays: stats.streakDays,
  byGenre: stats.byGenre,
  byDecade: stats.byDecade,
  hasMissingData: true,
);
