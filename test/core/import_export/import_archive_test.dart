import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';

/// #23 — the multi-file archive front door. Adversarial: an export is a zip on
/// one platform and a hand-unzipped folder on another, and TV Time buries its
/// CSVs under a directory prefix. If lookup were path-exact, the real GDPR zip
/// would silently read as "no entries" and the import would report success
/// having done nothing.

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  test('a plain file is one entry, readable under its own name', () {
    final archive = ImportArchive.fromBytes(
      'imdb_ratings.csv',
      Uint8List.fromList(utf8.encode('Const,Title\ntt1,Heat\n')),
    );

    expect(archive.entries, hasLength(1));
    expect(archive.readText('imdb_ratings.csv'), startsWith('Const,Title'));
    expect(archive.has('imdb_ratings.csv'), isTrue);
    expect(archive.readText('nope.csv'), isNull);
  });

  test('a zip is detected by magic bytes and expanded', () {
    final archive = ImportArchive.fromBytes(
      'export.zip',
      _zip({'followed_tv_show.csv': 'tv_show_id\n73244\n'}),
    );

    expect(archive.readText('followed_tv_show.csv'), contains('73244'));
  });

  test('a nested zip entry is found by basename, not by full path', () {
    // The real TV Time GDPR zip nests every CSV under a dated directory.
    final archive = ImportArchive.fromBytes(
      'export.zip',
      _zip({'gdpr_export_2026/data/seen_episode_source.csv': 'id\n1\n'}),
    );

    expect(archive.has('seen_episode_source.csv'), isTrue);
    expect(archive.readText('seen_episode_source.csv'), contains('1'));
  });

  test('a leading byte-order mark is stripped from the header row', () {
    final archive = ImportArchive.fromBytes(
      'imdb_ratings.csv',
      Uint8List.fromList(utf8.encode('\u{FEFF}Const,Title\n')),
    );

    // Not `contains` — the BOM would leave the *first* header cell unmatchable
    // by name, which is exactly how a real IMDb export breaks a CSV parser.
    expect(archive.readText('imdb_ratings.csv'), startsWith('Const'));
  });

  test('directory entries are dropped', () {
    final archive = Archive()
      ..addFile(ArchiveFile.directory('dir'))
      ..addFile(ArchiveFile.bytes('dir/a.csv', utf8.encode('x')));
    final zipped = ZipEncoder().encodeBytes(archive);

    expect(ImportArchive.fromBytes('e.zip', zipped).entries, hasLength(1));
  });

  test('malformed bytes decode lossily rather than throwing', () {
    final archive = ImportArchive.fromBytes(
      'x.csv',
      Uint8List.fromList([0xFF, 0xFE, 0x41]),
    );

    expect(archive.readText('x.csv'), endsWith('A'));
  });
}
