import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/export/auto_backup_service.dart';
import 'package:watch_nook/core/import_export/export/import_export_service.dart';

/// Fails the way a serializer fails: after the caller committed to backing up,
/// before a single byte is on disk.
class _ThrowingService extends ImportExportService {
  const _ThrowingService(super.dao);

  @override
  Future<String> exportJson() async => throw const FileSystemException('boom');
}

/// Counts serializations so single-flight is observable (a coalesced call must
/// not re-read the DB).
class _CountingService extends ImportExportService {
  _CountingService(super.dao);

  int calls = 0;

  @override
  Future<String> exportJson() async {
    calls++;
    return super.exportJson();
  }
}

void main() {
  late AppDatabase db;
  late LibraryDao dao;
  late ImportExportService service;
  late Directory dir;
  late AutoBackupService backup;

  final added = DateTime(2026, 3, 4, 5, 6, 7);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = LibraryDao(db);
    service = ImportExportService(dao);
    dir = await Directory.systemTemp.createTemp('watchnook_backup_test');
    backup = AutoBackupService(service: service, dao: dao, directory: dir);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  var nextTmdbId = 693134;
  Future<int> seed({String title = 'Dune'}) => dao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.movie,
      recordedSource: MetadataSourceKind.tmdb,
      title: title,
      trackStatus: TrackStatus.completed,
      addedAt: added,
      updatedAt: added,
      tmdbId: Value(nextTmdbId++), // unique: (source, tmdbId) is constrained
    ),
  );

  List<FileSystemEntity> contents() => dir.listSync();

  test('restores a fresh install from the backup file', () async {
    await seed(title: 'Arrival');
    await dao.markWatched(await dao.getAll().then((i) => i.first.id));
    await backup.snapshot();

    await dao.deleteAllUserData();
    expect(await dao.hasAnyItems(), isFalse);

    expect(await backup.restoreIfEmpty(), isTrue);
    final items = await dao.getAll();
    expect(items, hasLength(1));
    expect(items.single.title, 'Arrival');
    expect(items.single.watchedCount, 1);
    expect(await dao.watchEventsFor(items.single.id), hasLength(1));
  });

  test('never wipes a non-empty library', () async {
    await seed(title: 'Backed up');
    await backup.snapshot();

    await dao.deleteAllUserData();
    await seed(title: 'Already here');

    expect(await backup.restoreIfEmpty(), isFalse);
    expect((await dao.getAll()).single.title, 'Already here');
  });

  test('no backup file is a no-op, not a throw', () async {
    expect(await backup.restoreIfEmpty(), isFalse);
    expect(await dao.hasAnyItems(), isFalse);
  });

  test('a failed snapshot leaves the previous backup byte-identical', () async {
    await seed(title: 'Good');
    await backup.snapshot();
    final before = await backup.file.readAsString();

    final broken = AutoBackupService(
      service: _ThrowingService(dao),
      dao: dao,
      directory: dir,
    );
    await expectLater(broken.snapshot(), throwsA(isA<FileSystemException>()));

    expect(await backup.file.readAsString(), before);
    // A serialize that throws must not even create the temp sibling.
    expect(contents(), hasLength(1));
  });

  test('a snapshot publishes exactly one file, and it parses', () async {
    await seed();
    await backup.snapshot();

    expect(contents().map((e) => e.path), [backup.file.path]);
    final decoded = jsonDecode(await backup.file.readAsString());
    expect((decoded as Map)['version'], ImportExportService.formatVersion);
  });

  test('concurrent snapshots coalesce, and the latch releases', () async {
    await seed();
    final counting = _CountingService(dao);
    final coalescing = AutoBackupService(
      service: counting,
      dao: dao,
      directory: dir,
    );

    await Future.wait([coalescing.snapshot(), coalescing.snapshot()]);

    expect(counting.calls, 1, reason: 'second caller joins the first flight');
    expect(contents().map((e) => e.path), [coalescing.file.path]);

    // The in-flight future MUST be nulled on completion. Leave it set and every
    // later snapshot() returns the already-completed future — backups stop
    // forever, silently. Only an independent, later call can see that.
    await seed(title: 'Added after the first flight');
    await coalescing.snapshot();
    expect(counting.calls, 2);
    expect(
      await backup.file.readAsString(),
      contains('Added after the first flight'),
    );
  });

  test(
    'a corrupt backup cannot boot-loop, and does not poison snapshot',
    () async {
      await backup.file.parent.create(recursive: true);
      await backup.file.writeAsString('{{{');
      await expectLater(
        backup.restoreIfEmpty(),
        throwsA(isA<FormatException>()),
        reason: 'main() catches this on Object; it must not be swallowed here',
      );
      expect(await dao.hasAnyItems(), isFalse);

      // Structurally valid, wrongly typed: rejected quietly, DB untouched.
      await backup.file.writeAsString('{"version": 1, "items": "not a list"}');
      expect(await backup.restoreIfEmpty(), isFalse);
      expect(await dao.hasAnyItems(), isFalse);

      // Unknown version: rejected WITHOUT restoring, so onboarding still shows.
      await backup.file.writeAsString('{"version": 99, "items": []}');
      expect(await backup.restoreIfEmpty(), isFalse);

      // And the service is not poisoned — the next backup still lands.
      await seed();
      await backup.snapshot();
      expect(await backup.file.readAsString(), contains('Dune'));
    },
  );

  test('restore never resurrects the disposable cache', () async {
    await seed();
    await db
        .into(db.cachedMedia)
        .insert(
          CachedMediaCompanion.insert(
            source: MetadataSourceKind.tmdb,
            mediaType: MediaType.movie,
            sourceId: 693134,
            payload: '{}',
            fetchedAt: added,
            title: 'Dune',
          ),
        );

    await backup.snapshot();
    expect(
      await backup.file.readAsString(),
      isNot(contains('fetchedAt')),
      reason: 'ADR-3: cache tables never enter the backup file',
    );

    await dao.deleteAllUserData();
    await db.delete(db.cachedMedia).go();

    expect(await backup.restoreIfEmpty(), isTrue);
    expect(await db.select(db.cachedMedia).get(), isEmpty);
  });
}
