import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/csv_utils.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';

/// Reads a Letterboxd export — `watched.csv`, `ratings.csv`, `diary.csv` and
/// `watchlist.csv`, picked singly or unzipped together. Letterboxd tracks films
/// and nothing else, so every record is a [MediaType.movie].
///
/// Four things are less obvious than they look:
/// - **The export carries no ids**, so every film lands on the resolver's
///   title+year rung. What the export *does* carry is the [uriColumn] slug —
///   `parasite-2019` — which is the only stable identity here, and therefore
///   the key the four files are merged on.
/// - **`watched.csv` and `watchlist.csv` have identical headers**
///   (`Date,Name,Year,Letterboxd URI`), so the header cannot separate them and
///   the **basename** must. The header still does the *source* sniff: IMDb
///   ships a `watchlist.csv` too, and only Letterboxd's carries [uriColumn].
/// - **A slug's trailing number is not always a year** — see [_slugYear].
/// - **`diary.csv` outranks `watched.csv` on dates.** The diary's `Watched
///   Date` is when the film was seen; `watched.csv`'s `Date` is only when it
///   was marked. The applier keeps the *first* non-rewatch watch, so the
///   better date has to be the one that ends up there.
class LetterboxdImporter {
  const LetterboxdImporter._();

  /// Letterboxd's film-page URL, present in all four exports and in no other
  /// source's CSV. This — never the filename — is what identifies the source.
  static const uriColumn = 'Letterboxd URI';

  /// Present only in `diary.csv`, which is the only export that dates a
  /// viewing and the only one that flags a rewatch.
  static const watchedDateColumn = 'Watched Date';

  /// Present in `ratings.csv` and `diary.csv`, on Letterboxd's 0.5–5.0 scale.
  static const ratingColumn = 'Rating';

  /// The one file whose rows mean "means to watch". Its header is identical to
  /// `watched.csv`'s, so it can only be told apart by name.
  static const watchlistFile = 'watchlist.csv';

  /// True when [archive] holds at least one CSV carrying [uriColumn].
  static bool canRead(ImportArchive archive) => _read(archive).rows.isNotEmpty;

  /// Parses every export in [archive] into one record per film, merged by slug.
  static ParseResult parse(ImportArchive archive) {
    final parsed = _read(archive);
    var skipped = parsed.skipped;
    final films = <String, _Film>{};

    for (final (file, row) in parsed.rows) {
      final title = row['Name'] ?? '';
      if (title.isEmpty) {
        skipped++;
        continue;
      }

      final slug = _slug(row[uriColumn]);
      final year =
          int.tryParse(row['Year'] ?? '') ??
          (slug == null ? null : _slugYear(slug, title));

      // Without a slug two films with the same title+year collide — the same
      // bargain the resolver's title+year rung already makes.
      final film =
          films.putIfAbsent(
              slug ?? 'title:${title.toLowerCase()}:$year',
              () => _Film(title: title, year: year),
            )
            // A later row can carry the year an earlier one was missing.
            ..year ??= year;

      final rating = _rating(row[ratingColumn]);
      final date = DateTime.tryParse(row['Date'] ?? '');

      if (row.containsKey(watchedDateColumn)) {
        final watchedAt = DateTime.tryParse(row[watchedDateColumn] ?? '');
        if (row['Rewatch'] == 'Yes') {
          film.rewatch(watchedAt);
        } else {
          film.watch(watchedAt, fromDiary: true);
        }
        // Only `ratings.csv` knows the film's *current* rating; the diary knows
        // what it was rated at that sitting. So the diary only fills a hole.
        film.rate(rating, watchedAt, authoritative: false);
      } else if (row.containsKey(ratingColumn)) {
        // You cannot rate a film you have not seen, so a rating is a watch —
        // dated `Date`, which is when it was rated.
        film
          ..rate(rating, date, authoritative: true)
          ..watch(date, fromDiary: false);
      } else if (file != watchlistFile) {
        film.watch(date, fromDiary: false);
      }
      // A watchlist row's existence is its whole payload.
    }

    return (
      records: [for (final film in films.values) film.toRecord()],
      skippedRows: skipped,
    );
  }

  /// Every data row of every CSV in [archive] whose header carries [uriColumn],
  /// paired with the lowercased basename of the file it came from. Rows keep
  /// their own file's header, so [watchedDateColumn] and [ratingColumn] sort
  /// the diary and ratings exports out afterwards; the basename is needed only
  /// for the two files whose headers are indistinguishable.
  ///
  /// A CSV that survives parsing with no rows carries no signal, so it reads as
  /// "not Letterboxd" — which is also the right answer for an empty export.
  static ({List<(String, Map<String, String>)> rows, int skipped}) _read(
    ImportArchive archive,
  ) {
    final rows = <(String, Map<String, String>)>[];
    var skipped = 0;

    for (final path in archive.entries.keys) {
      if (!path.toLowerCase().endsWith('.csv')) continue;
      final name = path.split('/').last;
      final text = archive.readText(name);
      if (text == null) continue;

      final parsed = parseCsv(text);
      if (parsed.rows.isEmpty || !parsed.rows.first.containsKey(uriColumn)) {
        continue;
      }
      for (final row in parsed.rows) {
        rows.add((name.toLowerCase(), row));
      }
      skipped += parsed.skipped;
    }

    return (rows: rows, skipped: skipped);
  }

  /// The `parasite-2019` of `https://letterboxd.com/film/parasite-2019/`.
  static String? _slug(String? uri) {
    final segments = Uri.tryParse(uri ?? '')?.pathSegments ?? const <String>[];
    final film = segments.indexOf('film');
    if (film < 0 || film + 1 >= segments.length) return null;
    final slug = segments[film + 1];
    return slug.isEmpty ? null : slug;
  }

  /// The year Letterboxd appended to [slug] to disambiguate two films sharing
  /// [title] — or null, which is nearly always the answer.
  ///
  /// `blade-runner-2049` is **not** such a case: 2049 is part of the title and
  /// the film is from 2017. Reading any trailing number as a year is therefore
  /// wrong on exactly the film that makes it look right. The suffix only counts
  /// when the title itself does not already spell it, which is Letterboxd's own
  /// rule. A title whose slugification we get wrong (`Schindler's List` →
  /// `schindler-s-list` vs Letterboxd's `schindlers-list`) simply yields no
  /// hint — this only ever runs when the `Year` column is missing.
  static int? _slugYear(String slug, String title) {
    final base = _slugify(title);
    if (!slug.startsWith('$base-')) return null;
    return int.tryParse(slug.substring(base.length + 1));
  }

  static String _slugify(String title) => title
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// Letterboxd rates in half-stars, 0.5–5.0; the DB stores 1–10. `great`, `6`
  /// and a blank cell are all "no rating" — which costs the rating, never the
  /// row: the film was still watched.
  static int? _rating(String? value) {
    final stars = double.tryParse(value ?? '');
    if (stars == null || stars < 0.5 || stars > 5) return null;
    return (stars * 2).round();
  }
}

/// A film being accumulated across the four exports that may mention it.
class _Film {
  _Film({required this.title, this.year});

  final String title;
  int? year;
  bool watched = false;
  DateTime? firstWatchedAt;
  bool _firstFromDiary = false;
  int? rating;
  DateTime? ratedAt;
  final rewatches = <ImportWatch>[];

  /// Records a first viewing. A diary row's date is the real one and pins the
  /// watch; anything else only fills a hole (see the class doc).
  void watch(DateTime? at, {required bool fromDiary}) {
    watched = true;
    if (fromDiary && !_firstFromDiary) {
      _firstFromDiary = true;
      firstWatchedAt = at;
    } else if (!_firstFromDiary) {
      firstWatchedAt ??= at;
    }
  }

  /// Appends an extra viewing. The applier stores the deficit over what is
  /// already saved, so a re-import of the same diary appends nothing.
  void rewatch(DateTime? at) =>
      rewatches.add(ImportWatch(watchedAt: at, isRewatch: true));

  /// [value] may be null — a rating Letterboxd wrote in a shape we cannot read
  /// must not cost the row it came on.
  void rate(int? value, DateTime? at, {required bool authoritative}) {
    if (authoritative) {
      rating = value ?? rating;
      ratedAt = at ?? ratedAt;
    } else {
      rating ??= value;
      ratedAt ??= at;
    }
  }

  ImportRecord toRecord() => ImportRecord(
    mediaType: MediaType.movie,
    title: title,
    year: year,
    // Load-bearing: a film logged in the diary only as a *rewatch* has no
    // first-watch, so a status derived from watch history would file a film
    // they have seen twice under `watchlist`.
    trackStatus: watched || rewatches.isNotEmpty ? TrackStatus.completed : null,
    rating: rating,
    ratedAt: ratedAt,
    watches: [
      // First, so the applier's `firsts.firstOrNull` picks the best-known date.
      if (watched) ImportWatch(watchedAt: firstWatchedAt),
      ...rewatches,
    ],
  );
}
