import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';
import 'package:watch_nook/features/up_next/presentation/up_next_screen.dart';

/// #21 at the widget layer. `upcomingThisWeekProvider` is overridden (never the
/// real DB/network) — the DB-backed `trackedShowsProvider` underneath it is a
/// live Drift `.watch()` stream, which never quiesces under `flutter_test`'s
/// fake async and would hang `pumpAndSettle` (see CLAUDE.md).
///
/// Adversarial: the offline path must render a recoverable error state, not a
/// blank screen or a thrown exception.
void main() {
  UpcomingEntry entry({
    required String show,
    required DateTime airDate,
    int itemId = 1,
    int episode = 5,
    String? title,
  }) => (
    itemId: itemId,
    showTitle: show,
    upcoming: UpcomingEpisode(
      episode: EpisodeInfo(
        seasonNumber: 2,
        episodeNumber: episode,
        title: title,
      ),
      airDate: airDate,
    ),
  );

  Future<void> pumpWith(
    WidgetTester tester,
    Future<List<UpcomingEntry>> Function(Ref) upcoming,
  ) => tester.pumpWidget(
    ProviderScope(
      overrides: [upcomingThisWeekProvider.overrideWith(upcoming)],
      child: const MaterialApp(home: Scaffold(body: UpNextScreen())),
    ),
  );

  testWidgets('groups this week under day headers and shows the aired '
      'coordinate (acceptance)', (tester) async {
    await pumpWith(
      tester,
      (ref) async => [
        entry(
          show: 'Severance',
          airDate: DateTime(2026, 7, 9),
          title: 'Cold Harbor',
        ),
        entry(show: 'Andor', airDate: DateTime(2026, 7, 12), itemId: 2),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('S2E5 · Cold Harbor'), findsOneWidget);
    expect(find.text('Andor'), findsOneWidget);
    expect(find.text('S2E5'), findsOneWidget);
    // One header per air day.
    expect(find.textContaining('July 9'), findsOneWidget);
    expect(find.textContaining('July 12'), findsOneWidget);
  });

  testWidgets('nothing airing → empty state, not a blank screen', (
    tester,
  ) async {
    await pumpWith(tester, (ref) async => const []);
    await tester.pumpAndSettle();

    expect(find.text('No episodes for your shows this week.'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('a failed (offline) fetch renders a retryable error state', (
    tester,
  ) async {
    await pumpWith(
      tester,
      (ref) => Future<List<UpcomingEntry>>.error(StateError('offline')),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load upcoming episodes."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
