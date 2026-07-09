// The CSV literals below concatenate mid-column (`...2049,` + `https://...`),
// where the lint's suggested whitespace would corrupt the field it splits.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/imdb_importer.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/letterboxd_importer.dart';
import 'package:watch_nook/core/import_export/import/merge_applier.dart';
import 'package:watch_nook/core/import_export/import/resolver.dart';

/// #27 / US-10 — the Letterboxd importer, against the four-file export.
///
/// Adversarial angles, each a regression someone would otherwise ship:
/// - `watched.csv` and `watchlist.csv` have **identical headers**, so a header
///   sniff files everything you have seen under "means to watch" (or the
///   reverse); yet the *filename* cannot pick the source, because IMDb ships a
///   `watchlist.csv` too — only the `Letterboxd URI` header separates them;
/// - the slug's trailing number reads as a year, so **Blade Runner 2049** —
///   released 2017 — imports as a 2049 film and never resolves;
/// - the diary's rewatch row is a second first-watch, doubling watch counts,
///   or the diary's rating (5.0 at that sitting) overwrites the film's current
///   rating from `ratings.csv` (4.5);
/// - `watched.csv`'s `Date` (when it was *marked*) overwrites the diary's
///   `Watched Date` (when it was *seen*), and the applier keeps only the first;
/// - a film logged in the diary **only as a rewatch** has no first-watch, so a
///   status derived from watch history files it under `watchlist`;
/// - `Rating = great` and a truncated row are structurally valid CSV: an
///   `as`-cast turns them into a `TypeError`, which `on Exception` never
///   catches (CLAUDE.md), and neither may cost the file;
/// - Letterboxd carries no ids, so its films must land on the **same** library
///   item as the IMDb/Trakt fixtures rather than forking a duplicate.

ImportArchive _fixtures(List<String> paths) => ImportArchive({
  for (final path in paths)
    path.split('/').last: Uint8List.fromList(File(path).readAsBytesSync()),
});

ImportArchive _csv(Map<String, String> files) => ImportArchive({
  for (final entry in files.entries)
    entry.key: Uint8List.fromList(utf8.encode(entry.value)),
});

ImportArchive _fixture(String path) => _fixtures([path]);

ImportRecord _byTitle(ParseResult parsed, String title) =>
    parsed.records.firstWhere((r) => r.title == title);

const _dir = 'test/fixtures/letterboxd';
const _export = [
  '$_dir/watched.csv',
  '$_dir/ratings.csv',
  '$_dir/diary.csv',
  '$_dir/watchlist.csv',
];

/// `watched.csv`'s header — which `watchlist.csv` shares, letter for letter.
const _watchedHeader = 'Date,Name,Year,Letterboxd URI';
const _ratingsHeader = 'Date,Name,Year,Letterboxd URI,Rating';
const _diaryHeader =
    'Date,Name,Year,Letterboxd URI,Rating,Rewatch,Tags,Watched Date';

void main() {
  late ParseResult full;

  setUpAll(() => full = LetterboxdImporter.parse(_fixtures(_export)));

  group('canRead', () {
    test('accepts every file of the export, alone or together', () {
      for (final path in _export) {
        expect(
          LetterboxdImporter.canRead(_fixture(path)),
          isTrue,
          reason: path,
        );
      }
      expect(LetterboxdImporter.canRead(_fixtures(_export)), isTrue);
    });

    test("rejects IMDb's identically-named ratings.csv and watchlist.csv", () {
      // Same basenames, different source. Only the `Letterboxd URI` header
      // tells them apart; a filename sniff would eat IMDb's export whole.
      for (final path in const [
        'test/fixtures/imdb_ratings.csv',
        'test/fixtures/imdb_watchlist.csv',
      ]) {
        expect(
          LetterboxdImporter.canRead(_fixture(path)),
          isFalse,
          reason: path,
        );
        expect(LetterboxdImporter.parse(_fixture(path)).records, isEmpty);
      }
    });

    test('rejects a TV Time CSV and a Trakt JSON', () {
      expect(
        LetterboxdImporter.canRead(
          _fixture('test/fixtures/tvtime/followed_tv_show.csv'),
        ),
        isFalse,
      );
      expect(
        LetterboxdImporter.canRead(
          _fixture('test/fixtures/trakt/trakt-export.json'),
        ),
        isFalse,
      );
    });

    test('rejects a header-only export', () {
      expect(
        LetterboxdImporter.canRead(_csv({'watched.csv': _watchedHeader})),
        isFalse,
      );
    });
  });

  group('the whole export', () {
    test('merges the four files into one record per film', () {
      // 6 watched + 3 watchlisted; ratings and diary only mention watched ones.
      expect(full.records, hasLength(9));
      expect(full.skippedRows, 0);
      expect(
        full.records.every((r) => r.mediaType == MediaType.movie),
        isTrue,
      );
    });

    test('half-star ratings double onto the 1–10 scale', () {
      expect(_byTitle(full, 'Parasite').rating, 10); // 5.0
      expect(_byTitle(full, 'The Social Network').rating, 9); // 4.5
      expect(_byTitle(full, 'Inception').rating, 8); // 4.0
      expect(_byTitle(full, 'Parasite').ratedAt, DateTime.parse('2020-01-15'));
    });

    test('a watched, unrated film is completed with one dated watch', () {
      final eeaao = _byTitle(full, 'Everything Everywhere All at Once');
      expect(eeaao.rating, isNull);
      expect(eeaao.trackStatus, TrackStatus.completed);
      expect(eeaao.watches, hasLength(1));
      expect(eeaao.watches.single.isRewatch, isFalse);
      expect(eeaao.watches.single.coordinate, (null, null));
    });

    test('watchlisted films carry no watch, rating or status', () {
      for (final title in const ['Blade Runner 2049', 'Dune', 'Oppenheimer']) {
        final film = _byTitle(full, title);
        expect(film.watches, isEmpty, reason: title);
        expect(film.rating, isNull, reason: title);
        expect(film.hasFirstWatch, isFalse, reason: title);
        // Null lets the applier default it to `watchlist`.
        expect(film.trackStatus, isNull, reason: title);
      }
    });

    test('the diary rewatch appends, it does not double the first watch', () {
      final matrix = _byTitle(full, 'The Matrix');
      expect(matrix.watches, hasLength(2));
      expect(matrix.hasFirstWatch, isTrue);

      final first = matrix.watches.firstWhere((w) => !w.isRewatch);
      expect(first.watchedAt, DateTime.parse('2014-01-01'));

      final rewatch = matrix.watches.firstWhere((w) => w.isRewatch);
      expect(rewatch.watchedAt, DateTime.parse('2022-11-20'));
      expect(rewatch.coordinate, (null, null));
    });

    test("ratings.csv wins the rating the diary's rewatch disagrees with", () {
      // The diary says 5.0 at the 2022 sitting; `ratings.csv` is the film's
      // *current* rating, 4.5. Taking the diary's would silently re-rate it.
      expect(_byTitle(full, 'The Matrix').rating, 9);
    });

    test('a quoted comma in Tags does not shift Watched Date or Rewatch', () {
      // `"sci-fi, classic"` shifts every later column by one if the CSV is
      // split naively — `Rewatch` would read `sci-fi` and `Watched Date` the
      // tag list, silently losing the rewatch and the date.
      final matrix = _byTitle(full, 'The Matrix');
      expect(matrix.watches.where((w) => w.isRewatch), hasLength(1));
      expect(matrix.year, 1999);
    });
  });

  group('watched.csv vs watchlist.csv (identical headers)', () {
    test('the basename, not the header, decides seen from means-to-see', () {
      const row = '2023-01-10,Dune,2021,https://letterboxd.com/film/dune-2021/';
      final parsed = LetterboxdImporter.parse(
        _csv({
          'watchlist.csv': '$_watchedHeader\n$row',
          'watched.csv':
              '$_watchedHeader\n'
              '2022-06-01,Arrival,2016,https://letterboxd.com/film/arrival/',
        }),
      );

      expect(_byTitle(parsed, 'Dune').watches, isEmpty);
      expect(_byTitle(parsed, 'Dune').trackStatus, isNull);
      expect(_byTitle(parsed, 'Arrival').watches, hasLength(1));
      expect(_byTitle(parsed, 'Arrival').trackStatus, TrackStatus.completed);
    });

    test('a nested zip path still resolves the basename', () {
      final parsed = LetterboxdImporter.parse(
        _csv({
          'letterboxd-stuart-2024-01-01-utc/watchlist.csv':
              '$_watchedHeader\n'
              '2023-01-10,Dune,2021,https://letterboxd.com/film/dune-2021/',
        }),
      );

      expect(parsed.records.single.watches, isEmpty);
    });
  });

  group('the Letterboxd URI', () {
    test('merges rows the four files spell differently', () {
      // The slug is the only stable identity in the export: same film, two
      // titles. Keying on title+year forks it into two library items.
      final parsed = LetterboxdImporter.parse(
        _csv({
          'watched.csv':
              '$_watchedHeader\n'
              '2020-01-15,Parasite,2019,https://letterboxd.com/film/parasite-2019/',
          'ratings.csv':
              '$_ratingsHeader\n'
              '2020-02-01,기생충,2019,https://letterboxd.com/film/parasite-2019/,5.0',
        }),
      );

      expect(parsed.records, hasLength(1));
      expect(parsed.records.single.rating, 10);
    });

    test('a slug year fills in a missing Year column', () {
      final parsed = LetterboxdImporter.parse(
        _csv({
          'watched.csv':
              '$_watchedHeader\n'
              '2023-02-15,Dune,,https://letterboxd.com/film/dune-2021/',
        }),
      );

      expect(parsed.records.single.year, 2021);
    });

    test('a number that is part of the title is not a year', () {
      // `blade-runner-2049` is a 2017 film. Reading the trailing number as a
      // year makes every title-with-a-number unresolvable — and the `Year`
      // column, when present, must win regardless.
      expect(_byTitle(full, 'Blade Runner 2049').year, 2017);

      final parsed = LetterboxdImporter.parse(
        _csv({
          'watchlist.csv':
              '$_watchedHeader\n'
              '2023-01-10,Blade Runner 2049,,'
              'https://letterboxd.com/film/blade-runner-2049/',
        }),
      );
      expect(parsed.records.single.year, isNull);
    });

    test('a film with no parseable URI still imports on title+year', () {
      final parsed = LetterboxdImporter.parse(
        _csv({
          'watched.csv':
              '$_watchedHeader\n'
              '2022-06-01,Arrival,2016,\n'
              '2022-06-02,Sicario,2015,not a url',
        }),
      );

      expect(parsed.records, hasLength(2));
      expect(_byTitle(parsed, 'Arrival').year, 2016);
      expect(_byTitle(parsed, 'Sicario').year, 2015);
    });
  });

  group('diary.csv semantics', () {
    test("the diary's Watched Date outranks watched.csv's marked-on Date", () {
      // watched.csv's `Date` is when the film was *marked*; the diary knows
      // when it was *seen*. The applier keeps only the first non-rewatch watch,
      // so the wrong one here is the one the user gets — whichever file the
      // archive happens to yield first.
      const uri = 'https://letterboxd.com/film/arrival/';
      for (final order in const [
        ['watched.csv', 'diary.csv'],
        ['diary.csv', 'watched.csv'],
      ]) {
        final parsed = LetterboxdImporter.parse(
          ImportArchive({
            for (final file in order)
              file: Uint8List.fromList(
                utf8.encode(
                  file == 'watched.csv'
                      ? '$_watchedHeader\n2024-05-05,Arrival,2016,$uri'
                      : '$_diaryHeader\n'
                            '2016-11-20,Arrival,2016,$uri,4.5,No,,2016-11-20',
                ),
              ),
          }),
        );

        final arrival = parsed.records.single;
        final first = arrival.watches.firstWhere((w) => !w.isRewatch);
        expect(
          first.watchedAt,
          DateTime.parse('2016-11-20'),
          reason: order.join(' then '),
        );
      }
    });

    test('a rewatch-only diary is completed, not watchlist', () {
      // The first viewing predates the diary. `hasFirstWatch` is false, so a
      // status derived from watch history files a film seen twice as unwatched.
      final parsed = LetterboxdImporter.parse(
        _csv({
          'diary.csv':
              '$_diaryHeader\n'
              '2022-11-20,The Matrix,1999,'
              'https://letterboxd.com/film/the-matrix/,5.0,Yes,,2022-11-20',
        }),
      );

      final matrix = parsed.records.single;
      expect(matrix.trackStatus, TrackStatus.completed);
      expect(matrix.hasFirstWatch, isFalse);
      expect(matrix.watches.single.isRewatch, isTrue);
      // The diary is the only rating on offer here, so it fills the hole.
      expect(matrix.rating, 10);
    });

    test('two rewatches stay two rows', () {
      const row =
          '2022-11-20,The Matrix,1999,'
          'https://letterboxd.com/film/the-matrix/,5.0,Yes,,2022-11-20';
      final parsed = LetterboxdImporter.parse(
        _csv({'diary.csv': '$_diaryHeader\n$row\n$row'}),
      );

      expect(parsed.records.single.watches, hasLength(2));
    });
  });

  group('malformed export (degrades, never throws)', () {
    late ParseResult parsed;

    setUpAll(
      () => parsed = LetterboxdImporter.parse(
        _fixture('test/fixtures/malformed/letterboxd_ratings.csv'),
      ),
    );

    test('a truncated row costs the row, not the file', () {
      expect(parsed.records.map((r) => r.title), ['Parasite', 'The Matrix']);
      expect(parsed.skippedRows, 1);
    });

    test('a non-numeric Rating drops the rating, not the watch', () {
      final matrix = _byTitle(parsed, 'The Matrix');
      expect(matrix.rating, isNull);
      // `great` is still someone saying they saw it.
      expect(matrix.trackStatus, TrackStatus.completed);
      expect(matrix.watches, hasLength(1));
    });

    test('an out-of-scale Rating is no rating', () {
      // Letterboxd's scale is 0.5–5.0. A `9` here is an IMDb rating in a
      // Letterboxd column; doubling it to 18 would corrupt the DB's 0–10 range.
      final parsed = LetterboxdImporter.parse(
        _csv({
          'ratings.csv':
              '$_ratingsHeader\n'
              '2020-01-15,Parasite,2019,https://x/film/parasite-2019/,9\n'
              '2020-01-15,Dune,2021,https://x/film/dune-2021/,0',
        }),
      );

      expect(parsed.records.every((r) => r.rating == null), isTrue);
      expect(parsed.records.every((r) => r.hasFirstWatch), isTrue);
    });

    test('an unparseable Date leaves the watch undated', () {
      final parsed = LetterboxdImporter.parse(
        _csv({
          'ratings.csv':
              '$_ratingsHeader\n'
              'not-a-date,Dune,2021,https://x/film/dune-2021/,4.0',
        }),
      );

      final dune = parsed.records.single;
      expect(dune.ratedAt, isNull);
      expect(dune.watches.single.watchedAt, isNull);
      expect(dune.trackStatus, TrackStatus.completed);
      expect(dune.rating, 8);
    });

    test('a blank Name is skipped and counted', () {
      final parsed = LetterboxdImporter.parse(
        _csv({
          'watched.csv':
              '$_watchedHeader\n'
              '2022-06-01,,2016,https://letterboxd.com/film/arrival/\n'
              '2022-06-02,Sicario,2015,https://letterboxd.com/film/sicario/',
        }),
      );

      expect(parsed.records.map((r) => r.title), ['Sicario']);
      expect(parsed.skippedRows, 1);
    });
  });

  group('cross-source dedupe (US-11)', () {
    late AppDatabase db;
    late LibraryDao dao;
    late MergeApplier applier;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      dao = LibraryDao(db);
      applier = MergeApplier(dao: dao, sourceKind: MetadataSourceKind.tmdb);
    });
    tearDown(() => db.close());

    test('an IMDb film and its id-less Letterboxd row are one item', () async {
      // Letterboxd carries no ids, so it lands on `findByIdentity`'s title+year
      // rung. If that misses, every film the user already imported from IMDb
      // forks a second library item with no history.
      await applier.apply([
        for (final record in ImdbImporter.parse(
          _fixture('test/fixtures/imdb_ratings.csv'),
        ).records)
          Auto(record),
      ]);
      final before = await db.select(db.libraryItems).get();

      final summary = await applier.apply([
        for (final record in full.records) Auto(record),
      ]);

      final after = await db.select(db.libraryItems).get();
      final titles = after.map((i) => i.title).toList();
      expect(titles.where((t) => t == 'Parasite'), hasLength(1));
      expect(titles.where((t) => t == 'The Social Network'), hasLength(1));
      // Only the films IMDb never mentioned are new.
      expect(after, hasLength(before.length + summary.itemsAdded));

      final parasite = after.firstWhere((i) => i.title == 'Parasite');
      expect(parasite.imdbId, 'tt6751668'); // IMDb's id survives the merge
      expect(parasite.rating, 10);
    });

    test('re-importing the same export adds nothing', () async {
      final records = [for (final record in full.records) Auto(record)];
      await applier.apply(records);
      final items = await db.select(db.libraryItems).get();
      final events = await db.select(db.watchEvents).get();

      final again = await applier.apply(records);

      expect(again.itemsAdded, 0);
      expect(again.watchEventsAdded, 0);
      expect(again.rewatchesAdded, 0);
      expect(await db.select(db.libraryItems).get(), hasLength(items.length));
      expect(await db.select(db.watchEvents).get(), hasLength(events.length));
    });
  });
}
