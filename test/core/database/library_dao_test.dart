import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  LibraryItemsCompanion aShow({
    String title = 'Severance',
    int? tmdbId = 95396,
  }) {
    final now = DateTime(2026);
    return LibraryItemsCompanion.insert(
      mediaType: MediaType.tv,
      recordedSource: MetadataSourceKind.tmdb,
      title: title,
      trackStatus: TrackStatus.watching,
      addedAt: now,
      updatedAt: now,
      tmdbId: Value(tmdbId),
    );
  }

  group('LibraryDao round-trip', () {
    test('insert → getAll reads the row back with defaults applied', () async {
      final id = await db.libraryDao.insertItem(aShow());

      final all = await db.libraryDao.getAll();
      expect(all, hasLength(1));
      final item = all.single;
      expect(item.id, id);
      expect(item.title, 'Severance');
      expect(item.mediaType, MediaType.tv);
      expect(item.recordedSource, MetadataSourceKind.tmdb);
      expect(item.trackStatus, TrackStatus.watching);
      // Defaults land, not nulls.
      expect(item.watchedCount, 0);
      expect(item.relinkFailed, isFalse);
    });

    test('watchAll emits the current library', () async {
      await db.libraryDao.insertItem(aShow());
      final items = await db.libraryDao.watchAll().first;
      expect(items.map((i) => i.title), ['Severance']);
    });
  });

  group('schema & integrity (migration scaffold)', () {
    test('opens at schemaVersion 1 and passes integrity_check', () async {
      expect(db.schemaVersion, 1);
      // Forces onCreate + beforeOpen to run, then verifies the file is sound.
      final result = await db.customSelect('PRAGMA integrity_check').get();
      expect(result.single.data.values.first, 'ok');
    });

    test(
      'beforeOpen enables foreign_keys (not just declares the pragma)',
      () async {
        // Any query opens the connection and runs beforeOpen.
        final rows = await db.customSelect('PRAGMA foreign_keys').get();
        expect(rows.single.data.values.first, 1);
      },
    );
  });

  group('foreign-key enforcement (invariant regression guard)', () {
    test(
      'a WatchEvent referencing a missing LibraryItem is rejected',
      () async {
        // Proves foreign_keys = ON is actually active, not merely set in
        // beforeOpen — a dangling FK must throw, not silently insert.
        expect(
          () => db
              .into(db.watchEvents)
              .insert(WatchEventsCompanion.insert(libraryItemId: 999999)),
          throwsA(isA<SqliteException>()),
        );
      },
    );

    test('deleting a LibraryItem cascades to its WatchEvents', () async {
      final id = await db.libraryDao.insertItem(aShow());
      await db
          .into(db.watchEvents)
          .insert(
            WatchEventsCompanion.insert(
              libraryItemId: id,
              seasonNumber: const Value(1),
              episodeNumber: const Value(1),
            ),
          );
      expect(await db.select(db.watchEvents).get(), hasLength(1));

      await (db.delete(db.libraryItems)..where((t) => t.id.equals(id))).go();

      expect(await db.select(db.watchEvents).get(), isEmpty);
    });

    test('the (mediaType, tmdbId) unique index rejects a duplicate', () async {
      await db.libraryDao.insertItem(aShow());
      expect(
        () => db.libraryDao.insertItem(aShow(title: 'Severance (dupe)')),
        throwsA(isA<SqliteException>()),
      );
      // But two rows with a NULL tmdbId are allowed (NULLs are distinct).
      await db.libraryDao.insertItem(aShow(title: 'Manual A', tmdbId: null));
      await db.libraryDao.insertItem(aShow(title: 'Manual B', tmdbId: null));
      expect(await db.libraryDao.getAll(), hasLength(3));
    });
  });
}
