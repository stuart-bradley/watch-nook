// The CSV literals below concatenate mid-column (`...URL,` + `Title Type...`),
// where the lint's suggested whitespace would rename the column it splits.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/imdb_importer.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';

/// #26 — the IMDb importer, against the synthesized ratings + watchlist export.
///
/// Adversarial angles, each a regression someone would otherwise ship:
/// - IMDb and Letterboxd both name their exports `ratings.csv` /
///   `watchlist.csv`, so a filename sniff silently eats the wrong source's
///   file — the `Const` **header** has to decide;
/// - a rated show has no watch event, so anything that derives its status from
///   watch history files a show you finished under `watchlist`;
/// - IMDb exports **no episode rows**, so inventing coordinates for a rated
///   show fabricates watched flags the user never set;
/// - a title in both exports is one item, and the watchlist row must not
///   downgrade the rating's `completed`;
/// - `Title Type` covers `tvEpisode`/`short`/`videoGame`, which have no home
///   here — a blacklist lets the next new type in as a movie;
/// - `Your Rating = good` and a **missing `Const`** are structurally valid CSV:
///   an `as`-cast turns them into a `TypeError`, which `on Exception` never
///   catches (CLAUDE.md), and neither may cost the row.

ImportArchive _fixture(String path) => ImportArchive({
  path.split('/').last: Uint8List.fromList(File(path).readAsBytesSync()),
});

ImportArchive _csv(Map<String, String> files) => ImportArchive({
  for (final entry in files.entries)
    entry.key: Uint8List.fromList(utf8.encode(entry.value)),
});

ImportRecord _byTitle(ParseResult parsed, String title) =>
    parsed.records.firstWhere((r) => r.title == title);

/// The ratings header, so a synthetic case only has to spell out its rows.
const _ratingsHeader =
    'Const,Your Rating,Date Rated,Title,Original Title,URL,Title Type,'
    'IMDb Rating,Runtime (mins),Year,Genres,Num Votes,Release Date,Directors';

/// The watchlist header — note it carries no `Your Rating`.
const _watchlistHeader =
    'Position,Const,Created,Modified,Description,Title,Original Title,URL,'
    'Title Type,IMDb Rating,Runtime (mins),Year,Genres,Num Votes,'
    'Release Date,Directors';

void main() {
  late ParseResult ratings;
  late ParseResult watchlist;

  setUpAll(() {
    ratings = ImdbImporter.parse(_fixture('test/fixtures/imdb_ratings.csv'));
    watchlist = ImdbImporter.parse(
      _fixture('test/fixtures/imdb_watchlist.csv'),
    );
  });

  group('canRead', () {
    test('accepts both IMDb exports', () {
      expect(
        ImdbImporter.canRead(_fixture('test/fixtures/imdb_ratings.csv')),
        isTrue,
      );
      expect(
        ImdbImporter.canRead(_fixture('test/fixtures/imdb_watchlist.csv')),
        isTrue,
      );
    });

    test("rejects Letterboxd's identically-named ratings.csv", () {
      // The filename is the same; only the header tells them apart. A sniff on
      // the basename would read Letterboxd's export as IMDb's and drop it all.
      final archive = _fixture('test/fixtures/letterboxd/ratings.csv');
      expect(ImdbImporter.canRead(archive), isFalse);
      expect(ImdbImporter.parse(archive).records, isEmpty);
    });

    test('rejects a TV Time CSV and a Trakt JSON', () {
      expect(
        ImdbImporter.canRead(
          _fixture('test/fixtures/tvtime/followed_tv_show.csv'),
        ),
        isFalse,
      );
      expect(
        ImdbImporter.canRead(_fixture('test/fixtures/trakt/trakt-export.json')),
        isFalse,
      );
    });

    test('rejects a header-only export', () {
      final archive = _csv({'ratings.csv': _ratingsHeader});
      expect(ImdbImporter.canRead(archive), isFalse);
    });
  });

  group('ratings export', () {
    test('parses every supported row', () {
      expect(ratings.records, hasLength(9));
      expect(ratings.skippedRows, 0);
    });

    test('a rated movie is completed, watched once, on its rated date', () {
      final parasite = _byTitle(ratings, 'Parasite');
      expect(parasite.mediaType, MediaType.movie);
      expect(parasite.imdbId, 'tt6751668');
      expect(parasite.year, 2019);
      expect(parasite.rating, 10);
      expect(parasite.ratedAt, DateTime.parse('2020-01-15'));
      expect(parasite.trackStatus, TrackStatus.completed);
      expect(parasite.watches, hasLength(1));
      expect(parasite.watches.single.watchedAt, DateTime.parse('2020-01-15'));
      expect(parasite.watches.single.isRewatch, isFalse);
      expect(parasite.watches.single.coordinate, (null, null));
    });

    test('a rated show is completed but invents no episode events', () {
      // IMDb exports no episode history. A show marked `completed` with zero
      // watch events is correct; any coordinate here is fabricated.
      for (final title in const ['The Office', 'Breaking Bad', 'Chernobyl']) {
        final show = _byTitle(ratings, title);
        expect(show.mediaType, MediaType.tv, reason: title);
        expect(show.trackStatus, TrackStatus.completed, reason: title);
        expect(show.watches, isEmpty, reason: title);
        expect(show.hasFirstWatch, isFalse, reason: title);
      }
      expect(_byTitle(ratings, 'Chernobyl').rating, 10); // tvMiniSeries → tv
    });

    test('keeps the export title, not the original-language one', () {
      expect(_byTitle(ratings, 'Parasite').imdbId, 'tt6751668');
      expect(_byTitle(ratings, 'Spirited Away').year, 2001);
    });

    test('reads a quoted-comma Genres column without shifting fields', () {
      // `"Crime, Drama, Thriller"` shifts every later column by two if the CSV
      // is split naively — `Year` would read `2050000`.
      expect(_byTitle(ratings, 'Breaking Bad').year, 2008);
      expect(_byTitle(ratings, 'The Matrix').year, 1999);
    });
  });

  group('watchlist export', () {
    test('parses to unwatched, unrated, status-less records', () {
      expect(watchlist.records, hasLength(4));
      expect(watchlist.skippedRows, 0);
      for (final record in watchlist.records) {
        expect(record.watches, isEmpty, reason: record.title);
        expect(record.rating, isNull, reason: record.title);
        // Null lets the applier default it to `watchlist`.
        expect(record.trackStatus, isNull, reason: record.title);
      }
    });

    test('maps Title Type across both exports', () {
      expect(_byTitle(watchlist, 'Arcane').mediaType, MediaType.tv);
      expect(_byTitle(watchlist, 'Dune').imdbId, 'tt1160419');
      final blade = _byTitle(watchlist, 'Blade Runner 2049');
      expect(blade.mediaType, MediaType.movie);
    });
  });

  group('merging the two exports', () {
    test('a rated, watchlisted title is one completed record', () {
      final parsed = ImdbImporter.parse(
        _csv({
          'watchlist.csv':
              '$_watchlistHeader\n'
              '1,tt1375666,2023-01-10,2023-01-10,,Inception,Inception,'
              'https://x/,movie,8.8,148,2010,"Action, Sci-Fi",1,2010-07-16,x',
          'ratings.csv':
              '$_ratingsHeader\n'
              'tt1375666,9,2015-06-20,Inception,Inception,https://x/,movie,'
              '8.8,148,2010,"Action, Sci-Fi",1,2010-07-16,x',
        }),
      );

      expect(parsed.records, hasLength(1));
      final inception = parsed.records.single;
      expect(inception.rating, 9);
      // The watchlist row must not downgrade the rating's `completed`.
      expect(inception.trackStatus, TrackStatus.completed);
      expect(inception.watches, hasLength(1));
    });

    test('the same movie rated twice yields one watch event', () {
      const row =
          'tt1375666,9,2015-06-20,Inception,Inception,https://x/,movie,'
          '8.8,148,2010,Action,1,2010-07-16,x';
      final parsed = ImdbImporter.parse(
        _csv({'ratings.csv': '$_ratingsHeader\n$row\n$row'}),
      );

      expect(parsed.records, hasLength(1));
      expect(parsed.records.single.watches, hasLength(1));
    });

    test('a movie and a show sharing an id stay separate items', () {
      // IMDb ids are unique, but identity is `(mediaType, id)` everywhere else
      // in this pipeline; keying on the id alone would merge them.
      final parsed = ImdbImporter.parse(
        _csv({
          'ratings.csv':
              '$_ratingsHeader\n'
              'tt1,9,2015-06-20,Dune,Dune,https://x/,movie,8,148,2021,x,1,x,x\n'
              'tt1,9,2015-06-20,Dune,Dune,https://x/,tvSeries,8,1,2021,x,1,x,x',
        }),
      );

      expect(parsed.records, hasLength(2));
      expect(
        parsed.records.map((r) => r.mediaType),
        containsAll(MediaType.values),
      );
    });
  });

  group('Title Type whitelist', () {
    test('skips and counts the types this app cannot store', () {
      final parsed = ImdbImporter.parse(
        _csv({
          'ratings.csv':
              '$_ratingsHeader\n'
              'tt1,9,2015-06-20,Ozymandias,x,https://x/,tvEpisode,9,47,2013,x,1,x,x\n'
              'tt2,9,2015-06-20,Paperman,x,https://x/,short,8,6,2012,x,1,x,x\n'
              'tt3,9,2015-06-20,The Last of Us,x,https://x/,videoGame,9,1,2013,x,1,x,x\n'
              'tt4,9,2015-06-20,Dune,x,https://x/,movie,8,155,2021,x,1,x,x',
        }),
      );

      expect(parsed.records.map((r) => r.title), ['Dune']);
      expect(parsed.skippedRows, 3);
    });
  });

  group('malformed export (degrades, never throws)', () {
    late ParseResult parsed;

    setUpAll(
      () => parsed = ImdbImporter.parse(
        _fixture('test/fixtures/malformed/imdb_ratings.csv'),
      ),
    );

    test('keeps every row: a bad field costs the field, not the title', () {
      expect(parsed.records, hasLength(3));
      expect(parsed.skippedRows, 0);
    });

    test('a non-numeric Your Rating drops the rating, not the watch', () {
      final matrix = _byTitle(parsed, 'The Matrix');
      expect(matrix.rating, isNull);
      // `good` is still someone saying they saw it.
      expect(matrix.trackStatus, TrackStatus.completed);
      expect(matrix.watches, hasLength(1));
    });

    test('a row missing Const falls back to the title+year rung', () {
      final social = _byTitle(parsed, 'The Social Network');
      expect(social.imdbId, isNull);
      expect(social.title, 'The Social Network');
      expect(social.year, 2010);
      expect(social.rating, 8);
    });

    test('two rows missing Const stay two records', () {
      // A blank `Const` read as the id `''` collides every unidentified title
      // into a single item — the worst kind of silent import corruption.
      final parsed = ImdbImporter.parse(
        _csv({
          'ratings.csv':
              '$_ratingsHeader\n'
              ',9,2015-06-20,Inception,x,https://x/,movie,8,148,2010,x,1,x,x\n'
              ',9,2015-06-20,Dune,x,https://x/,movie,8,155,2021,x,1,x,x',
        }),
      );

      expect(parsed.records, hasLength(2));
      expect(parsed.records.every((r) => r.imdbId == null), isTrue);
    });

    test('an unparseable Date Rated leaves the watch undated', () {
      final parsed = ImdbImporter.parse(
        _csv({
          'ratings.csv':
              '$_ratingsHeader\n'
              'tt1,9,not-a-date,Dune,x,https://x/,movie,8,155,2021,x,1,x,x',
        }),
      );

      final dune = parsed.records.single;
      expect(dune.ratedAt, isNull);
      expect(dune.watches.single.watchedAt, isNull);
      expect(dune.trackStatus, TrackStatus.completed);
    });

    test('a truncated row is skipped and counted', () {
      final parsed = ImdbImporter.parse(
        _csv({
          'ratings.csv':
              '$_ratingsHeader\n'
              'tt1,9,2015-06-20,Dune,x,https://x/,movie,8,155,2021,x,1,x,x\n'
              'tt2,9,2015-06-20,Arrival',
        }),
      );

      expect(parsed.records.map((r) => r.title), ['Dune']);
      expect(parsed.skippedRows, 1);
    });
  });
}
