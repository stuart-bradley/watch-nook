import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A picked import file flattened to `path → bytes`.
///
/// The exports arrive in two shapes and the importers should not care which: a
/// **zip** (TV Time's GDPR bundle, Letterboxd's export) or a **single file**
/// (an IMDb CSV, a Trakt JSON). [ImportArchive.fromBytes] normalizes both to
/// the same map, so an importer only ever asks for the entries it needs by
/// name.
class ImportArchive {
  /// Creates an archive over already-extracted [entries], keyed by path.
  const ImportArchive(this.entries);

  /// Reads [bytes] as a zip when they carry the zip magic (`PK`), otherwise as
  /// a single entry named [filename]. Directory entries are dropped.
  factory ImportArchive.fromBytes(String filename, Uint8List bytes) {
    if (!_looksLikeZip(bytes)) {
      return ImportArchive({filename: bytes});
    }
    final zip = ZipDecoder().decodeBytes(bytes);
    return ImportArchive({
      for (final f in zip.files)
        if (f.isFile) f.name: f.content,
    });
  }

  /// Every file in the archive, keyed by its **full path** (a zip keeps its
  /// directories). Lookups match on basename — see [readText].
  final Map<String, Uint8List> entries;

  /// The bytes of the entry whose **basename** is [name], or null. Matching on
  /// the basename is what lets a nested ~80-file GDPR zip be read the same way
  /// as a folder someone unzipped by hand.
  Uint8List? read(String name) {
    for (final entry in entries.entries) {
      if (_basename(entry.key) == name) return entry.value;
    }
    return null;
  }

  /// [read], decoded as UTF-8 with the byte-order mark stripped (IMDb's export
  /// ships one, and a leading `﻿` would corrupt the first CSV header).
  /// Malformed bytes are replaced rather than thrown on (AD-7).
  String? readText(String name) {
    final bytes = read(name);
    if (bytes == null) return null;
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.startsWith('﻿') ? text.substring(1) : text;
  }

  /// True when an entry with this basename exists — how an importer decides
  /// whether an archive is its own.
  bool has(String name) => read(name) != null;

  static bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;

  static String _basename(String path) => path.split('/').last;
}
