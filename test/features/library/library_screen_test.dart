import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';

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

  Future<void> seedShow() => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.tv,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Severance',
      trackStatus: TrackStatus.watching,
      addedAt: now,
      updatedAt: now,
      watchedCount: const Value(7),
      lastWatchedSeason: const Value(2),
      lastWatchedEpisode: const Value(4),
      episodeCountTotal: const Value(10),
    ),
  );

  Future<void> seedMovie() => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.movie,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Dune',
      trackStatus: TrackStatus.completed,
      addedAt: now,
      updatedAt: now,
      watchedCount: const Value(1),
    ),
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
      activeMetadataSourceProvider.overrideWithValue(_ThrowingSource()),
      libraryGridProvider.overrideWith(
        (ref, filter) => Stream.value([
          for (final item in items)
            if ((filter.status == null || item.trackStatus == filter.status) &&
                (filter.type == null || item.mediaType == filter.type))
              item,
        ]),
      ),
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
}
