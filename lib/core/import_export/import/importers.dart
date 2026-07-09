import 'package:watch_nook/core/import_export/import/imdb_importer.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/letterboxd_importer.dart';
import 'package:watch_nook/core/import_export/import/trakt_importer.dart';
import 'package:watch_nook/core/import_export/import/tv_time_importer.dart';

/// The services Watchnook can read an export from.
enum ImportSourceKind {
  /// TV Time's GDPR zip.
  tvTime('TV Time'),

  /// Trakt's JSON export.
  trakt('Trakt'),

  /// IMDb's ratings / watchlist CSVs.
  imdb('IMDb'),

  /// Letterboxd's export zip.
  letterboxd('Letterboxd');

  const ImportSourceKind(this.label);

  /// Display name, for "Read 42 titles from your Letterboxd export".
  final String label;
}

/// The importer that recognizes [archive], and what it read — or null when no
/// importer claims the file.
///
/// Detection is by **content**, never by filename: each importer's `canRead`
/// keys off a column or entry that no other source's export carries (`Const`
/// for IMDb, `Letterboxd URI` for Letterboxd), so a renamed file still lands.
/// Order is therefore only a tie-break that no real export should reach.
(ImportSourceKind, ParseResult)? parseArchive(ImportArchive archive) {
  if (TvTimeImporter.canRead(archive)) {
    return (ImportSourceKind.tvTime, TvTimeImporter.parse(archive));
  }
  if (TraktImporter.canRead(archive)) {
    return (ImportSourceKind.trakt, TraktImporter.parse(archive));
  }
  if (ImdbImporter.canRead(archive)) {
    return (ImportSourceKind.imdb, ImdbImporter.parse(archive));
  }
  if (LetterboxdImporter.canRead(archive)) {
    return (ImportSourceKind.letterboxd, LetterboxdImporter.parse(archive));
  }
  return null;
}
