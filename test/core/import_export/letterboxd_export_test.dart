import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/export/import_export_service.dart';
import 'package:watch_nook/core/import_export/import/csv_utils.dart';

void main() {
  late AppDatabase db;
  late LibraryDao dao;
  late ImportExportService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = LibraryDao(db);
    service = ImportExportService(dao);
  });
  tearDown(() => db.close());

  final added = DateTime(2026, 3, 4, 5, 6, 7);

  Future<int> seedMovie({
    String title = 'Parasite',
    int? rating,
    int? year = 2019,
  }) => dao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.movie,
      recordedSource: MetadataSourceKind.tmdb,
      title: title,
      trackStatus: TrackStatus.completed,
      addedAt: added,
      updatedAt: added,
      tmdbId: const Value(496243),
      imdbId: const Value('tt6751668'),
      year: Value(year),
      rating: Value(rating),
    ),
  );

  Future<void> seedWatch(int itemId, {DateTime? at, bool isRewatch = false}) =>
      dao.insertWatchEvent(
        WatchEventsCompanion.insert(
          libraryItemId: itemId,
          watchedAt: Value(at),
          isRewatch: Value(isRewatch),
        ),
      );

  /// Data rows only, in emission order.
  Future<List<Map<String, String>>> rows() async =>
      parseCsv(await service.exportLetterboxdCsv()).rows;

  test(
    'header is byte-exact; a rewatched film emits a row per viewing',
    () async {
      final id = await seedMovie();
      await seedWatch(id, at: DateTime(2020, 2, 9));
      await seedWatch(id, at: DateTime(2021, 5, 17), isRewatch: true);
      await seedWatch(id, at: DateTime(2022, 12, 25), isRewatch: true);

      final csv = await service.exportLetterboxdCsv();
      expect(
        csv.split('\r\n').first,
        'Name,Year,Rating,Rewatch,WatchedDate,tmdbID,imdbID',
      );

      final parsed = parseCsv(csv).rows;
      expect(parsed.map((r) => r['Rewatch']), ['No', 'Yes', 'Yes']);
      expect(parsed.map((r) => r['WatchedDate']), [
        '2020-02-09',
        '2021-05-17',
        '2022-12-25',
      ]);
      expect(parsed.first['tmdbID'], '496243');
      expect(parsed.first['imdbID'], 'tt6751668');
      expect(parsed.first['Year'], '2019');
    },
  );

  // 1–10 in the DB, 0.5–5.0 on Letterboxd. `0` is unrated, not zero stars:
  // Letterboxd's scale floors at 0.5 and its importer rejects anything below.
  for (final (stored, expected) in [
    (9, '4.5'),
    (10, '5.0'),
    (1, '0.5'),
    (null, ''),
    (0, ''),
  ]) {
    test('rating $stored exports as "$expected"', () async {
      final id = await seedMovie(rating: stored);
      await seedWatch(id, at: DateTime(2020, 2, 9));
      expect((await rows()).single['Rating'], expected);
    });
  }

  test("a rating round-trips back through the importer's scale", () async {
    final id = await seedMovie(rating: 7);
    await seedWatch(id, at: DateTime(2020, 2, 9));
    final stars = double.parse((await rows()).single['Rating']!);
    expect((stars * 2).round(), 7);
  });

  test('TV shows never appear', () async {
    final showId = await dao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Severance',
        trackStatus: TrackStatus.watching,
        addedAt: added,
        updatedAt: added,
      ),
    );
    await dao.insertWatchEvent(
      WatchEventsCompanion.insert(
        libraryItemId: showId,
        seasonNumber: const Value(1),
        episodeNumber: const Value(1),
        watchedAt: Value(DateTime(2025, 1, 17)),
      ),
    );
    expect(await rows(), isEmpty);
  });

  test('a watchlist film (no watches, no rating) is omitted', () async {
    await seedMovie();
    expect(await rows(), isEmpty);
  });

  test('a rated, unwatched film emits one dateless first-watch row', () async {
    await seedMovie(rating: 8);
    final row = (await rows()).single;
    expect(row['Rating'], '4.0');
    expect(row['Rewatch'], 'No');
    expect(row['WatchedDate'], '');
  });

  test('a dateless watch emits an empty WatchedDate, not the epoch', () async {
    final id = await seedMovie();
    await seedWatch(id);
    expect((await rows()).single['WatchedDate'], '');
  });

  test('a comma and a double-quote in a title survive parseCsv', () async {
    final id = await seedMovie(title: 'Dune, Part Two "Extended"');
    await seedWatch(id, at: DateTime(2024, 3, 17));
    expect((await rows()).single['Name'], 'Dune, Part Two "Extended"');
  });

  test('a film with no year emits an empty Year, not "null"', () async {
    final id = await seedMovie(year: null);
    await seedWatch(id, at: DateTime(2020, 2, 9));
    expect((await rows()).single['Year'], '');
  });
}
