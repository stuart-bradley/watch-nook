import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

part 'library_dao.g.dart';

/// Thin data access for [LibraryItems] (+ read of its [WatchEvents]). Basic
/// reads/writes only — denormalized progress maintenance and the grid query
/// land with #15 (M2); watched semantics with #19/#20. Exposes just enough of
/// [WatchEvents] for the backend-switch reconciliation (#14) to read a title's
/// watched coordinates; the full watch-write DAO lands with #19.
@DriftAccessor(tables: [LibraryItems, WatchEvents])
class LibraryDao extends DatabaseAccessor<AppDatabase> with _$LibraryDaoMixin {
  /// Creates a [LibraryDao].
  LibraryDao(super.attachedDatabase);

  /// Insert a library item, returning the generated id.
  Future<int> insertItem(LibraryItemsCompanion entry) =>
      into(libraryItems).insert(entry);

  /// Get every library item.
  Future<List<LibraryItem>> getAll() => select(libraryItems).get();

  /// Watch every library item (repaints on any write).
  Stream<List<LibraryItem>> watchAll() => select(libraryItems).watch();

  /// Patch one item by id. Used by the backend-switch service to relink ids /
  /// set `relinkFailed` without rewriting the whole row.
  Future<void> updateItem(int id, LibraryItemsCompanion patch) =>
      (update(libraryItems)..where((t) => t.id.equals(id))).write(patch);

  /// Every [WatchEvents] row for one item — the backend-switch reconciliation
  /// reads these to check watched coordinates line up on the new backend.
  Future<List<WatchEvent>> watchEventsFor(int libraryItemId) => (select(
    watchEvents,
  )..where((t) => t.libraryItemId.equals(libraryItemId))).get();
}
