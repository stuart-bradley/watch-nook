import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

part 'library_dao.g.dart';

/// Thin data access for [LibraryItems]. Basic reads/writes only — denormalized
/// progress maintenance and the grid query land with #15 (M2); watched
/// semantics with #19/#20.
@DriftAccessor(tables: [LibraryItems])
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
}
