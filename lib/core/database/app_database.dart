import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';

part 'app_database.g.dart';

/// The Drift database for Watchnook.
///
/// v1 ships the two **user-owned** tables (ADR-3). The disposable cache tables
/// (`CachedMedia`/`CachedEpisodes`) land at schema v2 with #13 (M1); every
/// schema change bumps [schemaVersion] and adds a `MigrationStrategy` step.
@DriftDatabase(tables: [LibraryItems, WatchEvents], daos: [LibraryDao])
class AppDatabase extends _$AppDatabase {
  /// Creates an [AppDatabase] backed by the default on-device SQLite file.
  AppDatabase() : super(_openConnection());

  /// Creates an [AppDatabase] over a custom [QueryExecutor] — used by tests
  /// with `NativeDatabase.memory()`; never the real file.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    beforeOpen: (details) async {
      // FK actions (the WatchEvents → LibraryItems cascade) are inert without
      // this; enabling it also makes a dangling FK insert fail loudly.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  static QueryExecutor _openConnection() => driftDatabase(name: 'watchnook');
}
