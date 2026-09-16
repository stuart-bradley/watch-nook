import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/library/unverified_position.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';

import '../../support/library_fixtures.dart' as seed;

/// #17 acceptance at the widget layer: the grid filters by status/type and
/// renders progress **offline**. Adversarial: the source provider is a source
/// that throws on any call, so a passing test proves the grid never reaches for
/// metadata — it reads the denormalized columns alone (US-13).
class _ThrowingSource implements MetadataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('offline: the grid must not call the metadata source');
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final now = DateTime(2026);

  // 7 watched ending at S2E4 — the same progress the grid used to be handed
  // directly, but now derived by `recomputeDenormalized` from real markWatched
  // writes, so the fixture can't drift from what the app would actually store.
  Future<void> seedShow() => seed.seedShow(
    db,
    now: now,
    episodeCountTotal: 10,
    watched: const [(1, 1), (1, 2), (1, 3), (2, 1), (2, 2), (2, 3), (2, 4)],
  );

  Future<void> seedMovie() => seed.seedMovie(db, now: now, watched: true);

  /// The same show and the same progress, but Unverified.
  Future<void> seedUnverifiedShow() => seed.seedShow(
    db,
    now: now,
    episodeCountTotal: 10,
    relinkFailed: true,
    watched: const [(1, 1), (1, 2), (1, 3), (2, 1), (2, 2), (2, 3), (2, 4)],
  );

  // The grid is fed a **synchronous snapshot** of real `LibraryItem` rows, not
  // the live DAO stream. That keeps the widget test deterministic and leaves no
  // dangling Drift `.watch()` subscription/timer (a live stream never quiesces
  // under fake-async, so `pumpAndSettle` would hang on the loading spinner for
  // its full 10-minute timeout). The DAO's real SQL filtering + `.watch()`
  // repaint is covered in `library_dao_test`; here the override re-filters the
  // same snapshot the DAO would, so a chip tap still drives the real
  // `_status`/`_type` → family-key → filtered-render path end to end.
  Widget harness(List<LibraryItem> items) => ProviderScope(
    overrides: [
      activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
      activeMetadataSourceProvider.overrideWithValue(_ThrowingSource()),
      libraryGridProvider.overrideWith((ref, filter) {
        // Mirror the real provider's status mapping (incl. the derived
        // Up-to-date refinement) over the snapshot.
        bool statusMatch(LibraryItem i) => switch (filter.status) {
          LibraryStatusFilter.all => true,
          LibraryStatusFilter.upToDate => isUpToDate(i),
          LibraryStatusFilter.watching =>
            i.trackStatus == TrackStatus.watching && !isUpToDate(i),
          LibraryStatusFilter.completed =>
            i.trackStatus == TrackStatus.completed && !isUpToDate(i),
          LibraryStatusFilter.watchlist =>
            i.trackStatus == TrackStatus.watchlist,
          LibraryStatusFilter.onHold => i.trackStatus == TrackStatus.onHold,
          LibraryStatusFilter.dropped => i.trackStatus == TrackStatus.dropped,
        };
        return Stream.value([
          for (final item in items)
            if (statusMatch(item) &&
                (filter.type == null || item.mediaType == filter.type))
              item,
        ]);
      }),
    ],
    child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
  );

  testWidgets('renders progress from denormalized fields offline', (
    tester,
  ) async {
    await seedShow();
    await tester.pumpWidget(harness(await db.libraryDao.getAll()));
    await tester.pumpAndSettle();

    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('S2E4 · 3 left'), findsOneWidget);
  });

  // The third surface. The rule and its wording are tested at
  // unverified_position.dart and the caption string at
  // library_progress_label_test; the only thing left that neither can see is
  // whether the grid WIDGET renders that caption's output — the wiring step.
  // (The same gap on the Up Next side was a real finding, so it is not
  // hypothetical here.)
  //
  // Proved to fail first: dropping markUnverifiedPosition from
  // libraryProgressLabel reddens the first expectation.
  testWidgets('an Unverified position is marked in the grid caption', (
    tester,
  ) async {
    await seedUnverifiedShow();
    await tester.pumpWidget(harness(await db.libraryDao.getAll()));
    await tester.pumpAndSettle();

    final marked = markUnverifiedPosition('S2E4', unverified: true);
    expect(find.text('$marked · 3 left'), findsOneWidget);
    expect(
      find.text('S2E4 · 3 left'),
      findsNothing,
      reason: 'the unmarked caption must not also be on screen',
    );
  });

  testWidgets('a healthy position is not marked', (tester) async {
    await seedShow();
    await tester.pumpWidget(harness(await db.libraryDao.getAll()));
    await tester.pumpAndSettle();

    expect(find.text('S2E4 · 3 left'), findsOneWidget);
  });

  testWidgets('the empty library shows a prompt, not a crash', (tester) async {
    await tester.pumpWidget(harness(const []));
    await tester.pumpAndSettle();
    expect(find.text('Your library is empty'), findsOneWidget);
  });

  testWidgets('the type filter narrows the grid stream', (tester) async {
    await seedShow();
    await seedMovie();
    await tester.pumpWidget(harness(await db.libraryDao.getAll()));
    await tester.pumpAndSettle();

    // All types → both visible.
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('Dune'), findsOneWidget);

    // Tap the TV chip → the movie drops out.
    await tester.tap(find.widgetWithText(ChoiceChip, 'TV'));
    await tester.pumpAndSettle();
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('Dune'), findsNothing);

    // Switch to Films → the show drops out.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Films'));
    await tester.pumpAndSettle();
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Severance'), findsNothing);
  });

  testWidgets('the status filter narrows the grid stream', (tester) async {
    await seedShow(); // watching
    await seedMovie(); // completed
    await tester.pumpWidget(harness(await db.libraryDao.getAll()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Completed'));
    await tester.pumpAndSettle();
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Severance'), findsNothing);
  });

  // The widget harness above overrides libraryGridProvider with a hand-mirrored
  // copy of the status mapping. These drive the REAL provider over a real DAO,
  // so a divergence in the derived Up-to-date refinement (e.g. dropping the
  // `!isUpToDate` exclusion that keeps caught-up shows out of Watching) is
  // actually caught.
  group('libraryGridProvider (real provider, not the widget override)', () {
    Future<void> seedCaughtUp({
      required String title,
      TrackStatus status = TrackStatus.watching,
    }) => seed.seedShow(
      db,
      title: title,
      // Distinct id per title, so addOrGetItem's dedupe won't merge them.
      tmdbId: title.hashCode,
      status: status,
      now: now,
      episodeCountTotal: 10,
      showStatus: 'Returning Series',
      watched: const [
        (1, 1),
        (1, 2),
        (1, 3),
        (1, 4),
        (1, 5),
        (1, 6),
        (1, 7),
        (1, 8),
        (1, 9),
        (1, 10),
      ],
    );

    Future<List<LibraryItem>> grid(
      ProviderContainer c,
      LibraryStatusFilter status,
    ) {
      final key = (status: status, type: null);
      addTearDown(c.listen(libraryGridProvider(key), (_, _) {}).close);
      return c.read(libraryGridProvider(key).future);
    }

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('a caught-up returning show is Up-to-date, excluded from '
        'Watching', () async {
      await seedCaughtUp(title: 'Shogun'); // watching, all aired, returning
      final c = container();

      expect(
        (await grid(c, LibraryStatusFilter.upToDate)).map((i) => i.title),
        ['Shogun'],
      );
      expect(
        await grid(c, LibraryStatusFilter.watching),
        isEmpty,
        reason: 'the !isUpToDate exclusion keeps it out of Watching',
      );
      expect(
        (await grid(c, LibraryStatusFilter.all)).map((i) => i.title),
        ['Shogun'],
        reason: 'still counted under All',
      );
    });

    test('a caught-up completed show is excluded from Completed', () async {
      await seedCaughtUp(title: 'Archived', status: TrackStatus.completed);
      final c = container();

      expect(
        await grid(c, LibraryStatusFilter.completed),
        isEmpty,
        reason: 'a returning caught-up show is Up-to-date, not Completed',
      );
      expect(
        (await grid(c, LibraryStatusFilter.upToDate)).map((i) => i.title),
        ['Archived'],
      );
    });
  });
}
