import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/importers.dart';

/// #28 — source detection, the one decision the import UI makes before the
/// pipeline takes over.
///
/// Adversarial: detection must key off **content**, not filenames. IMDb and
/// Letterboxd both ship a `watchlist.csv`, so a name-based sniff files a
/// Letterboxd export as an IMDb one — every film then resolves against the
/// wrong id block. And an unrecognized file must come back as `null` rather
/// than being claimed by whichever importer runs last and quietly parsing to
/// zero records.

ImportArchive _archive(String dir) => ImportArchive({
  for (final f in Directory(dir).listSync().whereType<File>())
    if (f.path.endsWith('.csv') || f.path.endsWith('.json'))
      f.path.split('/').last: Uint8List.fromList(f.readAsBytesSync()),
});

ImportArchive _text(String name, String body) =>
    ImportArchive({name: Uint8List.fromList(utf8.encode(body))});

void main() {
  test('each real export is claimed by its own importer', () {
    expect(
      parseArchive(_archive('test/fixtures/tvtime'))?.$1,
      ImportSourceKind.tvTime,
    );
    expect(
      parseArchive(_archive('test/fixtures/trakt'))?.$1,
      ImportSourceKind.trakt,
    );
    expect(
      parseArchive(_archive('test/fixtures/letterboxd'))?.$1,
      ImportSourceKind.letterboxd,
    );
    expect(
      parseArchive(
        ImportArchive({
          'imdb_ratings.csv': Uint8List.fromList(
            File('test/fixtures/imdb_ratings.csv').readAsBytesSync(),
          ),
        }),
      )?.$1,
      ImportSourceKind.imdb,
    );
  });

  test("a Letterboxd watchlist.csv is not mistaken for IMDb's", () {
    // Same filename, different columns. Only the header separates them.
    final detected = parseArchive(
      _text(
        'watchlist.csv',
        'Date,Name,Year,Letterboxd URI\n'
            '2024-01-01,Dune,2021,https://letterboxd.com/film/dune-2021/\n',
      ),
    );
    expect(detected?.$1, ImportSourceKind.letterboxd);
    expect(detected?.$2.records, hasLength(1));
  });

  test('an unrecognized file is claimed by nobody', () {
    expect(parseArchive(_text('notes.csv', 'a,b\n1,2\n')), isNull);
    expect(parseArchive(_text('x.json', '{"hello": "world"}')), isNull);
    expect(parseArchive(const ImportArchive({})), isNull);
  });
}
