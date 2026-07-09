import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/media_cache_dao.dart';
import 'package:watch_nook/core/database/tables.dart';

part 'app_database.g.dart';

/// The Drift database for Watchnook.
///
/// v1 ships the two **user-owned** tables (ADR-3). v2 (#13) adds the disposable
/// cache tables (`CachedMedia`/`CachedEpisodes`) — see the cache-domain
/// invariant in `tables.dart`. Every schema change bumps [schemaVersion] and
/// adds a `MigrationStrategy` step.
@DriftDatabase(
  tables: [LibraryItems, WatchEvents, CachedMedia, CachedEpisodes],
  daos: [LibraryDao, MediaCacheDao],
)
class AppDatabase extends _$AppDatabase {
  /// Creates an [AppDatabase] backed by the default on-device SQLite file.
  AppDatabase() : super(_openConnection());

  /// Creates an [AppDatabase] over a custom [QueryExecutor] — used by tests
  /// with `NativeDatabase.memory()`; never the real file.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      // v1 → v2 (#13): additively create the two disposable cache tables. No
      // user data is touched — the user-owned tables are unchanged.
      if (from < 2) {
        await m.createTable(cachedMedia);
        await m.createTable(cachedEpisodes);
      }
    },
    beforeOpen: (details) async {
      // FK actions (the WatchEvents → LibraryItems cascade) are inert without
      // this; enabling it also makes a dangling FK insert fail loudly.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  static QueryExecutor _openConnection() => driftDatabase(name: 'watchnook');
}
