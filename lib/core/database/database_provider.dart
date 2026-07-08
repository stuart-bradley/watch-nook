import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/media_cache_dao.dart';

part 'database_provider.g.dart';

/// The singleton [AppDatabase]. `keepAlive` so the connection outlives any one
/// screen; disposed (closed) only when the whole provider container tears down.
///
/// Note (CLAUDE.md convention): providers exposing a Drift-generated **row**
/// type (e.g. an M2 `Stream<List<LibraryItem>>`) must be a plain
/// `StreamProvider`/`FutureProvider`, not `@riverpod` — the generator throws on
/// types from another library's generated part. DAOs are fine here.
@Riverpod(keepAlive: true)
AppDatabase appDatabase(Ref ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
}

/// The [LibraryDao] for the singleton database.
@Riverpod(keepAlive: true)
LibraryDao libraryDao(Ref ref) => ref.watch(appDatabaseProvider).libraryDao;

/// The [MediaCacheDao] for the singleton database — backs the SWR metadata
/// cache (`CachingMetadataRepository`, #13). `keepAlive` to match the DB.
@Riverpod(keepAlive: true)
MediaCacheDao mediaCacheDao(Ref ref) =>
    ref.watch(appDatabaseProvider).mediaCacheDao;
