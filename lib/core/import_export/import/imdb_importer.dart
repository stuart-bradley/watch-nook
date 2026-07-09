import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/csv_utils.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';

/// Reads an IMDb export: the ratings CSV and the watchlist CSV, picked singly
/// or unzipped together. Both carry `Const` — the `tt…` id — so every title
/// lands on the resolver's id rung with no search.
///
/// Three things are less obvious than they look:
/// - **IMDb and Letterboxd name their exports the same.** Both ship a
///   `ratings.csv` and a `watchlist.csv`, so the filename decides nothing. The
///   `Const` column is the format sniff, and [ratingColumn]'s presence on a row
///   is what separates a ratings row from a watchlist row.
/// - **A rating implies a watch** — you cannot rate what you have not seen — so
///   a rated title is `completed`. A rated *movie* also gets one watch event,
///   dated `Date Rated`. A rated *show* gets **none**: IMDb exports no episode
///   history, and inventing coordinates would fabricate watched flags.
/// - **[_mediaTypes] is a whitelist.** `tvEpisode`, `short` and `videoGame` are
///   rows this app has no home for; a blacklist would let the next type IMDb
///   invents leak in as a movie.
class ImdbImporter {
  const ImdbImporter._();

  /// IMDb's id column, present in both exports and in no other source's CSV.
  static const idColumn = 'Const';

  /// Present only in the ratings export. Its presence on a row means "watched
  /// and rated"; its absence means "means to watch".
  static const ratingColumn = 'Your Rating';

  /// `Title Type` values this app can store, and what they store as. Anything
  /// else — an episode, a short, a video game — is skipped and counted (AD-7).
  static const Map<String, MediaType> _mediaTypes = {
    'movie': MediaType.movie,
    'tvMovie': MediaType.movie,
    'tvSeries': MediaType.tv,
    'tvMiniSeries': MediaType.tv,
  };

  /// True when [archive] holds at least one CSV carrying IMDb's [idColumn].
  static bool canRead(ImportArchive archive) => _read(archive).rows.isNotEmpty;

  /// Parses both exports into one record per title, merged by id.
  static ParseResult parse(ImportArchive archive) {
    final parsed = _read(archive);
    var skipped = parsed.skipped;
    final titles = <String, _Title>{};

    for (final row in parsed.rows) {
      final mediaType = _mediaTypes[row['Title Type']];
      final title = row['Title'] ?? '';
      if (mediaType == null || title.isEmpty) {
        skipped++;
        continue;
      }

      // A row can be missing its `Const`, and a blank one must not become the
      // id `''` — that would collide every unidentified title into one item.
      final id = row[idColumn] ?? '';
      final imdbId = id.startsWith('tt') ? id : null;
      final year = int.tryParse(row['Year'] ?? '');

      final entry = titles.putIfAbsent(
        '${mediaType.name}/${imdbId ?? 'title:${title.toLowerCase()}:$year'}',
        () => _Title(
          mediaType: mediaType,
          title: title,
          year: year,
          imdbId: imdbId,
        ),
      );

      // A watchlist row's existence is its whole payload. A title in both
      // exports is rated, and rated outranks watchlisted whichever file the
      // archive happens to yield first.
      if (row.containsKey(ratingColumn)) {
        entry.rate(
          _rating(row[ratingColumn]),
          DateTime.tryParse(row['Date Rated'] ?? ''),
        );
      }
    }

    return (
      records: [for (final title in titles.values) title.toRecord()],
      skippedRows: skipped,
    );
  }

  /// Every data row of every CSV in [archive] whose header carries [idColumn],
  /// flattened. Rows keep their own file's header, so [ratingColumn] tells the
  /// two exports apart afterwards and neither file needs naming.
  ///
  /// A CSV that survives parsing with no rows carries no signal, so it reads as
  /// "not IMDb" — which is also the right answer for an empty export.
  static ({List<Map<String, String>> rows, int skipped}) _read(
    ImportArchive archive,
  ) {
    final rows = <Map<String, String>>[];
    var skipped = 0;

    for (final path in archive.entries.keys) {
      if (!path.toLowerCase().endsWith('.csv')) continue;
      final text = archive.readText(path.split('/').last);
      if (text == null) continue;

      final parsed = parseCsv(text);
      if (parsed.rows.isEmpty || !parsed.rows.first.containsKey(idColumn)) {
        continue;
      }
      rows.addAll(parsed.rows);
      skipped += parsed.skipped;
    }

    return (rows: rows, skipped: skipped);
  }

  /// IMDb rates 1–10 as an integer. `good`, `8.7` and `` are all "no rating" —
  /// which costs the rating, never the row: the title was still watched.
  static int? _rating(String? value) {
    final rating = int.tryParse(value ?? '');
    return rating != null && rating >= 1 && rating <= 10 ? rating : null;
  }
}

/// A title being accumulated across the two exports that may mention it.
class _Title {
  _Title({
    required this.mediaType,
    required this.title,
    this.year,
    this.imdbId,
  });

  final MediaType mediaType;
  final String title;
  final int? year;
  final String? imdbId;
  bool rated = false;
  int? rating;
  DateTime? ratedAt;
  final watches = <ImportWatch>[];

  /// Records that the user rated this title. [value] may be null — a rating
  /// IMDb wrote in a shape we cannot read still proves they watched it.
  void rate(int? value, DateTime? at) {
    rated = true;
    rating ??= value;
    ratedAt ??= at;
    // Movies only: the export gives a show's rating but never its episodes.
    if (mediaType == MediaType.movie && watches.isEmpty) {
      watches.add(ImportWatch(watchedAt: at));
    }
  }

  ImportRecord toRecord() => ImportRecord(
    mediaType: mediaType,
    title: title,
    year: year,
    imdbId: imdbId,
    // Load-bearing for shows: a rated show has no watch event, so the applier
    // would otherwise default it to `watchlist` — the one status it is not.
    trackStatus: rated ? TrackStatus.completed : null,
    rating: rating,
    ratedAt: ratedAt,
    watches: watches,
  );
}
