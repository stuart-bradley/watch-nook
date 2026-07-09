import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/trakt_importer.dart';

/// #25 — the Trakt importer, against the synthesized `sync/watched`-shape
/// export.
///
/// Adversarial angles, each a regression someone would otherwise ship:
/// - `plays` is a **count**: reading it as a boolean loses every rewatch, and
///   emitting `plays` first-watches instead of one duplicates history;
/// - the same film appears in `watched`, `ratings` **and** `watchlist` — keying
///   on anything but the id block turns one title into three library items;
/// - TMDB numbers movies and shows in separate namespaces, so id `603` alone is
///   not identity;
/// - `year: "unknown"` and a missing `ids` block are **structurally valid**
///   JSON that an `as`-cast turns into a `TypeError` — which `on Exception`
///   never catches (CLAUDE.md).

ImportArchive _fixture(String path) => ImportArchive({
  path.split('/').last: Uint8List.fromList(File(path).readAsBytesSync()),
});

ImportArchive _json(String source) => ImportArchive({
  'export.json': Uint8List.fromList(utf8.encode(source)),
});

ImportRecord _byTitle(ParseResult parsed, String title) =>
    parsed.records.firstWhere((r) => r.title == title);

void main() {
  late ParseResult parsed;

  setUpAll(
    () => parsed = TraktImporter.parse(
      _fixture('test/fixtures/trakt/trakt-export.json'),
    ),
  );

  group('canRead', () {
    test('accepts a Trakt export', () {
      final archive = _fixture('test/fixtures/trakt/trakt-export.json');
      expect(TraktImporter.canRead(archive), isTrue);
    });

    test('rejects a CSV export from another source', () {
      final archive = _fixture('test/fixtures/imdb_ratings.csv');
      expect(TraktImporter.canRead(archive), isFalse);
    });

    test('rejects JSON that is not a Trakt export', () {
      expect(TraktImporter.canRead(_json('{"films": []}')), isFalse);
    });
  });

  group('fixture', () {
    test('merges every section into one record per title', () {
      // 2 watched movies + 2 watched shows + 2 watchlist titles; the two rated
      // titles are already among the watched ones.
      expect(parsed.records, hasLength(6));
      expect(parsed.skippedRows, 0);
    });

    test('carries the full id block', () {
      final office = _byTitle(parsed, 'The Office');
      expect(office.mediaType, MediaType.tv);
      expect(office.imdbId, 'tt0386676');
      expect(office.tmdbId, 2316);
      expect(office.tvdbId, 73244);
      expect(office.year, 2005);

      final parasite = _byTitle(parsed, 'Parasite');
      expect(parasite.mediaType, MediaType.movie);
      expect(parasite.imdbId, 'tt6751668');
      expect(parasite.tmdbId, 496243);
      expect(parasite.tvdbId, isNull);
    });

    test('one play is a watch, not a rewatch', () {
      final watches = _byTitle(parsed, 'Parasite').watches;
      expect(watches, hasLength(1));
      expect(watches.single.isRewatch, isFalse);
      expect(watches.single.coordinate, (null, null));
      expect(watches.single.watchedAt, DateTime.utc(2020, 1, 15, 20));
    });

    test('plays above the first become rewatches', () {
      final watches = _byTitle(parsed, 'The Matrix').watches;
      expect(watches, hasLength(2));
      expect(watches.map((w) => w.isRewatch), [false, true]);
    });

    test('shows carry episode coordinates in aired order', () {
      final watches = _byTitle(parsed, 'The Office').watches;
      expect(watches.map((w) => w.coordinate), [(1, 1), (1, 2), (2, 1)]);
      expect(watches.every((w) => !w.isRewatch), isTrue);
      expect(watches.first.watchedAt, DateTime.utc(2019, 1, 1, 2));
    });

    test('a rating lands on the record its watches did', () {
      final breakingBad = _byTitle(parsed, 'Breaking Bad');
      expect(breakingBad.rating, 10);
      expect(breakingBad.ratedAt, DateTime.utc(2019, 2, 12));
      expect(breakingBad.watches, hasLength(1));
    });

    test('watchlist titles have no watches, so the applier shelves them', () {
      for (final title in ['Blade Runner 2049', 'Arcane']) {
        final record = _byTitle(parsed, title);
        expect(record.watches, isEmpty, reason: title);
        expect(record.hasFirstWatch, isFalse, reason: title);
        expect(record.trackStatus, isNull, reason: title);
      }
    });
  });

  group('malformed', () {
    late ParseResult broken;

    setUpAll(
      () => broken = TraktImporter.parse(
        _fixture('test/fixtures/malformed/trakt-export.json'),
      ),
    );

    test('a string year degrades to null rather than throwing', () {
      final show = _byTitle(broken, 'Show With No Ids');
      expect(show.year, isNull);
    });

    test('a missing ids block falls back to the title+year rung', () {
      final show = _byTitle(broken, 'Show With No Ids');
      expect(show.imdbId, isNull);
      expect(show.tmdbId, isNull);
      expect(show.tvdbId, isNull);
      expect(show.watches.single.coordinate, (1, 1));
    });

    test('the good rows still land', () {
      expect(_byTitle(broken, 'Parasite').imdbId, 'tt6751668');
      expect(broken.records, hasLength(2));
    });
  });

  group('degrades rather than throws', () {
    test('a movie and a show sharing a tmdb id stay separate', () {
      final result = TraktImporter.parse(
        _json('''
        {"ratings": {
          "movies": [
            {"rating": 8, "movie": {"title": "Film", "ids": {"tmdb": 603}}}
          ],
          "shows": [
            {"rating": 6, "show": {"title": "Series", "ids": {"tmdb": 603}}}
          ]
        }}'''),
      );
      expect(result.records, hasLength(2));
      expect(_byTitle(result, 'Film').rating, 8);
      expect(_byTitle(result, 'Series').rating, 6);
    });

    test('episode plays above the first become rewatches', () {
      final result = TraktImporter.parse(
        _json('''
        {"watched": {"shows": [{
          "show": {"title": "S", "ids": {"tvdb": 1}},
          "seasons": [{"number": 1, "episodes": [{"number": 1, "plays": 3}]}]
        }]}}'''),
      );
      final watches = _byTitle(result, 'S').watches;
      expect(watches, hasLength(3));
      expect(watches.map((w) => w.isRewatch), [false, true, true]);
    });

    test('a titleless row costs a row, not the import', () {
      final result = TraktImporter.parse(
        _json('''
        {"watched": {"movies": [
          {"plays": 1, "movie": {"ids": {"imdb": "tt1"}}},
          "not an object",
          {"plays": 1, "movie": {"title": "Kept", "ids": {"imdb": "tt2"}}}
        ]}}'''),
      );
      expect(result.records, hasLength(1));
      expect(result.records.single.title, 'Kept');
      expect(result.skippedRows, 2);
    });

    test('a non-numeric rating is dropped, the title is not', () {
      final result = TraktImporter.parse(
        _json('''
        {"ratings": {"movies": [
          {"rating": "great", "movie": {"title": "Film", "ids": {"imdb": "t"}}}
        ]}}'''),
      );
      expect(result.records.single.rating, isNull);
      expect(result.skippedRows, 1);
    });

    test('a malformed season is skipped, its siblings are not', () {
      final result = TraktImporter.parse(
        _json('''
        {"watched": {"shows": [{
          "show": {"title": "S", "ids": {"tvdb": 1}},
          "seasons": [
            {"number": null, "episodes": [{"number": 1}]},
            {"number": 2, "episodes": [{"number": "x"}, {"number": 4}]}
          ]
        }]}}'''),
      );
      expect(_byTitle(result, 'S').watches.single.coordinate, (2, 4));
      expect(result.skippedRows, 2);
    });

    test('unparseable JSON yields nothing rather than throwing', () {
      final result = TraktImporter.parse(_json('{ not json'));
      expect(result.records, isEmpty);
      expect(result.skippedRows, 0);
    });
  });
}
