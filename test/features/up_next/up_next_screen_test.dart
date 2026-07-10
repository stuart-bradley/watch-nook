import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';
import 'package:watch_nook/features/up_next/presentation/up_next_screen.dart';

/// #21 at the widget layer — the watch queue. `watchQueueProvider` and the live
/// `libraryItemsProvider` are overridden (never the real DB/network): the real
/// library stream is a live Drift `.watch()` that never quiesces under fake
/// async and would hang `pumpAndSettle` (CLAUDE.md).
///
/// Adversarial: the offline path renders a recoverable error, not a blank
/// screen; the tick marks the exact coordinate; the two empty states differ.

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

void main() {
  QueueEntry entry({
    int itemId = 1,
    String show = 'Severance',
    int season = 2,
    int episode = 5,
  }) => (
    itemId: itemId,
    showTitle: show,
    posterPath: null, // null → placeholder, so the poster never hits network
    season: season,
    episode: episode,
  );

  Future<void> pumpWith(
    WidgetTester tester,
    Future<List<QueueEntry>> Function(Ref) queue, {
    List<LibraryItem> items = const [],
    AppDatabase? db,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        watchQueueProvider.overrideWith(queue),
        libraryItemsProvider.overrideWith((ref) => Stream.value(items)),
        activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
        if (db != null) appDatabaseProvider.overrideWithValue(db),
      ],
      child: const MaterialApp(home: Scaffold(body: UpNextScreen())),
    ),
  );

  testWidgets('renders a queue card per show with its next episode', (
    tester,
  ) async {
    await pumpWith(
      tester,
      (ref) async => [
        entry(show: 'One Piece', season: 1, episode: 14),
        entry(show: 'Taskmaster', itemId: 2),
      ],
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

  testWidgets('the tick marks exactly that coordinate watched', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await db.libraryDao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'One Piece',
        trackStatus: TrackStatus.watching,
        addedAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tmdbId: const Value(37854),
      ),
    );

    await pumpWith(
      tester,
      (ref) async => [
        entry(itemId: id, show: 'One Piece', season: 1, episode: 14),
      ],
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

  testWidgets('caught up (empty queue, shows tracked) → the caught-up state', (
    tester,
  ) async {
    await pumpWith(
      tester,
      (ref) async => const [],
      items: [_libItem()], // a tracked show, but nothing to watch
    );
    await tester.pumpAndSettle();

    expect(find.text("You're all caught up"), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('no tracked shows → the add-a-show empty state', (tester) async {
    await pumpWith(tester, (ref) async => const []);
    await tester.pumpAndSettle();

    expect(find.text('No shows tracked yet'), findsOneWidget);
    expect(find.text("You're all caught up"), findsNothing);
  });

  testWidgets('a failed (offline) fetch renders a retryable error state', (
    tester,
  ) async {
    await pumpWith(
      tester,
      (ref) => Future<List<QueueEntry>>.error(StateError('offline')),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load your queue."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
