import 'package:csv/csv.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

/// The columns letterboxd.com/import reads, in order. Byte-exact — Letterboxd
/// matches on header name, and `tmdbID`/`imdbID` beat the title+year fallback.
const letterboxdHeader = [
  'Name',
  'Year',
  'Rating',
  'Rewatch',
  'WatchedDate',
  'tmdbID',
  'imdbID',
];

/// Renders [movies] as a Letterboxd-importable CSV.
///
/// Letterboxd's import is **diary-shaped**: one row per viewing, not per film.
/// So a film watched once and rewatched twice emits three rows, and `Rewatch`
/// is what tells them apart.
///
/// Non-movies are dropped — Letterboxd tracks films and nothing else. A movie
/// with neither a watch event nor a rating is a *watchlist* entry, and emitting
/// it would tell Letterboxd the user had seen it; it is dropped too. A rating
/// with no event does emit one dateless row: you cannot rate a film you have
/// not seen — the same inference `LetterboxdImporter` already makes.
String letterboxdCsv(List<(LibraryItem, List<WatchEvent>)> movies) {
  final rows = <List<String>>[letterboxdHeader];

  for (final (item, events) in movies) {
    if (item.mediaType != MediaType.movie) continue;
    final rating = _rating(item.rating);

    if (events.isEmpty) {
      if (rating.isEmpty) continue;
      rows.add(_row(item, rating, rewatch: false, watchedAt: null));
      continue;
    }
    for (final event in events) {
      rows.add(
        _row(
          item,
          rating,
          rewatch: event.isRewatch,
          watchedAt: event.watchedAt,
        ),
      );
    }
  }

  // Defaults are RFC 4180: `,` fields, CRLF lines, quote-when-necessary.
  return const CsvEncoder().convert(rows);
}

List<String> _row(
  LibraryItem item,
  String rating, {
  required bool rewatch,
  required DateTime? watchedAt,
}) => [
  item.title,
  item.year?.toString() ?? '',
  rating,
  if (rewatch) 'Yes' else 'No',
  _date(watchedAt),
  item.tmdbId?.toString() ?? '',
  item.imdbId ?? '',
];

/// The DB stores 1–10; Letterboxd rates in half-stars, 0.5–5.0. Exact inverse
/// of `LetterboxdImporter._rating`'s `(stars * 2).round()`.
///
/// `0` emits empty, not `0.0`: Letterboxd's scale floors at 0.5, so a zero is
/// "unrated" however it got into the column.
String _rating(int? rating) =>
    rating == null || rating <= 0 ? '' : (rating / 2).toStringAsFixed(1);

/// `yyyy-MM-dd` in local time — the day the user believes they watched it, and
/// the same reading `LetterboxdImporter` gives a date-only cell. A null date
/// emits **empty**, so Letterboxd files the viewing as undated rather than on
/// the epoch.
String _date(DateTime? at) => at == null
    ? ''
    : '${at.year.toString().padLeft(4, '0')}-'
          '${at.month.toString().padLeft(2, '0')}-'
          '${at.day.toString().padLeft(2, '0')}';
