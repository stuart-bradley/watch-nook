import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/csv_utils.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';

/// Reads a TV Time GDPR export — the ~80-file zip, or the folder someone
/// unzipped by hand. Five of its tables carry library data; the rest is PII the
/// app never touches.
///
/// **TV** rows carry a TheTVDB id, so they resolve on the id rung with no
/// search. **Movie** rows carry only TV Time's internal UUID, which means
/// nothing to any metadata backend — they fall to the resolver's title+year
/// rung, exactly as ADR-5 expects.
class TvTimeImporter {
  const TvTimeImporter._();

  /// The show list: `archived`, `tv_show_name`, `tv_show_id` (TheTVDB).
  static const followedFile = 'followed_tv_show.csv';

  /// Per-show user state. Read for `is_followed`; `nb_episodes_seen` is a
  /// denormalized count with no coordinates behind it, and `watchedCount` is
  /// recomputed from the events we do have, so it is deliberately ignored.
  static const userDataFile = 'user_tv_show_data.csv';

  /// The **authoritative, complete** per-episode watch log — one row per
  /// watched episode (plus per-show aggregate roll-ups with blank coordinates,
  /// which are ignored). This is the real history; [seenSourceFile] /
  /// [seenLatestFile] are a tiny recent slice (using them alone imported ~2.6%
  /// of watched episodes — #11), so they are only a fallback when v2 is absent.
  static const trackingV2File = 'tracking-prod-records-v2.csv';

  /// Fallback episode history (older exports without [trackingV2File]).
  static const seenSourceFile = 'seen_episode_source.csv';

  /// A **delta** on top of [seenSourceFile], not a replacement — the two are
  /// unioned. Treating it as a replacement would drop years of history.
  static const seenLatestFile = 'seen_episode_latest.csv';

  /// Movies (and episode rows we ignore — the seen-episode tables are the
  /// authority on episodes, and these duplicate a subset of them).
  static const trackingFile = 'tracking-prod-records.csv';

  /// True when [archive] looks like a TV Time export.
  static bool canRead(ImportArchive archive) =>
      archive.has(followedFile) || archive.has(trackingFile);

  /// Parses every table this importer understands into one record per title.
  ///
  /// Episodes are keyed by `tv_show_name` in TV Time's export — the only join
  /// key those tables offer — so a show must appear in [followedFile] for its
  /// episodes to land. An orphan episode row is skipped and counted rather than
  /// filed under an invented show.
  static ParseResult parse(ImportArchive archive) {
    var skipped = 0;

    final followed = _read(archive, followedFile);
    skipped += followed.skipped;
    final shows = <String, int>{};
    final statuses = <String, TrackStatus>{};
    for (final row in followed.rows) {
      final name = row['tv_show_name'] ?? '';
      final tvdbId = int.tryParse(row['tv_show_id'] ?? '');
      if (name.isEmpty || tvdbId == null) {
        skipped++;
        continue;
      }
      shows[name] = tvdbId;
      // A TV Time user archives what they have finished.
      statuses[name] = row['archived'] == '1'
          ? TrackStatus.completed
          : TrackStatus.watching;
    }

    final userData = _read(archive, userDataFile);
    skipped += userData.skipped;
    for (final row in userData.rows) {
      final name = row['tv_show_name'] ?? '';
      // Unfollowed but not archived: walked away from, not finished.
      if (row['is_followed'] == '0' && statuses[name] == TrackStatus.watching) {
        statuses[name] = TrackStatus.dropped;
      }
    }

    // Prefer the complete v2 log; fall back to the seen_episode_* delta pair
    // only when the export predates v2. Either way, orphan episode rows (a show
    // not in [shows]) are skipped and counted.
    final history = archive.has(trackingV2File)
        ? _watchesFromV2(archive, shows)
        : _watchesFromSeenTables(archive, shows);
    skipped += history.skipped;
    final watches = history.watches;

    final records = [
      for (final show in shows.entries)
        ImportRecord(
          mediaType: MediaType.tv,
          title: show.key,
          year: _yearSuffix(show.key),
          tvdbId: show.value,
          trackStatus: statuses[show.key],
          watches: watches[show.key]?.values.toList() ?? const [],
        ),
    ];

    final movies = _parseMovies(archive, () => skipped++);
    records.addAll(movies);

    return (records: records, skippedRows: skipped);
  }

  /// Per-episode history from the authoritative v2 log. Rows with blank
  /// coordinates are per-show aggregate roll-ups (a watch count, no episode)
  /// and are ignored — not counted as skips. Specials (`is_special`) are
  /// dropped:
  /// TVDB and TMDB number them differently, so importing them would mark the
  /// wrong episode, and they are not progress episodes anyway.
  static ({Map<String, Map<(int, int), ImportWatch>> watches, int skipped})
  _watchesFromV2(ImportArchive archive, Map<String, int> shows) {
    final parsed = _read(archive, trackingV2File);
    var skipped = parsed.skipped;
    final watches = <String, Map<(int, int), ImportWatch>>{};
    for (final row in parsed.rows) {
      if (row['is_special'] == 'true') continue;
      final name = row['series_name'] ?? '';
      final season = int.tryParse(row['season_number'] ?? '');
      final episode = int.tryParse(row['episode_number'] ?? '');
      if (season == null || episode == null) continue; // aggregate roll-up
      if (!shows.containsKey(name)) {
        skipped++;
        continue;
      }
      watches.putIfAbsent(name, () => {}).putIfAbsent(
        (season, episode),
        () => ImportWatch(
          season: season,
          episode: episode,
          watchedAt: _date(row['created_at']),
        ),
      );
    }
    return (watches: watches, skipped: skipped);
  }

  /// Fallback for exports without [trackingV2File]: union the seen_episode_*
  /// delta pair (idempotent, keeping the older source-of-truth timestamp).
  static ({Map<String, Map<(int, int), ImportWatch>> watches, int skipped})
  _watchesFromSeenTables(ImportArchive archive, Map<String, int> shows) {
    var skipped = 0;
    final watches = <String, Map<(int, int), ImportWatch>>{};
    for (final file in const [seenSourceFile, seenLatestFile]) {
      final parsed = _read(archive, file);
      skipped += parsed.skipped;
      for (final row in parsed.rows) {
        final name = row['tv_show_name'] ?? '';
        final season = int.tryParse(row['episode_season_number'] ?? '');
        final episode = int.tryParse(row['episode_number'] ?? '');
        if (season == null || episode == null || !shows.containsKey(name)) {
          skipped++;
          continue;
        }
        watches.putIfAbsent(name, () => {}).putIfAbsent(
          (season, episode),
          () => ImportWatch(
            season: season,
            episode: episode,
            watchedAt: _date(row['created_at']),
          ),
        );
      }
    }
    return (watches: watches, skipped: skipped);
  }

  /// Movies live in `tracking-prod-records.csv`, one row per *event*: a
  /// `follow` (watchlist) and a `watch` for the same film, keyed by the same
  /// `uuid`. Collapsing on the uuid is what stops one film becoming two items.
  static List<ImportRecord> _parseMovies(
    ImportArchive archive,
    void Function() onSkip,
  ) {
    final tracking = _read(archive, trackingFile);
    for (var i = 0; i < tracking.skipped; i++) {
      onSkip();
    }

    final movies = <String, _Movie>{};
    for (final row in tracking.rows) {
      if (row['entity_type'] != 'movie') continue;
      final uuid = row['uuid'] ?? '';
      final name = row['movie_name'] ?? '';
      if (uuid.isEmpty || name.isEmpty) {
        onSkip();
        continue;
      }
      final movie = movies.putIfAbsent(uuid, () => _Movie(name));
      final rewatches = int.tryParse(row['rewatch_count'] ?? '') ?? 0;
      movie
        // Duplicate rows disagree about `release_date` (and one carries the
        // bogus `0001-01-01`), so the first plausible year wins.
        ..year ??= _yearOf(row['release_date'])
        ..rewatches = rewatches > movie.rewatches ? rewatches : movie.rewatches;
      if (row['type'] == 'watch') {
        movie
          ..watched = true
          ..watchedAt = _date(row['watch_date']) ?? _date(row['created_at']);
      }
    }

    return [
      for (final movie in movies.values)
        ImportRecord(
          mediaType: MediaType.movie,
          title: movie.title,
          year: movie.year,
          trackStatus: movie.watched
              ? TrackStatus.completed
              : TrackStatus.watchlist,
          watches: [
            if (movie.watched) ImportWatch(watchedAt: movie.watchedAt),
            for (var i = 0; i < movie.rewatches; i++)
              ImportWatch(watchedAt: movie.watchedAt, isRewatch: true),
          ],
        ),
    ];
  }

  static ({List<Map<String, String>> rows, int skipped}) _read(
    ImportArchive archive,
    String name,
  ) {
    final text = archive.readText(name);
    return text == null ? (rows: const [], skipped: 0) : parseCsv(text);
  }

  /// `Battlestar Galactica (2003)` → 2003. The title keeps its suffix (that is
  /// how the user knows the show), but the year gives the resolver's title
  /// search something to disambiguate on.
  static int? _yearSuffix(String title) =>
      int.tryParse(RegExp(r'\((\d{4})\)$').firstMatch(title)?.group(1) ?? '');

  /// TV Time writes `0001-01-01` when it has no release date. Anything before
  /// cinema exists is that sentinel, not a year.
  static int? _yearOf(String? raw) {
    final year = _date(raw)?.year;
    return year == null || year < 1900 ? null : year;
  }

  /// Timestamps arrive two ways: `2021-05-17 07:08:00` on most tables, epoch
  /// seconds in `watch_date`.
  static DateTime? _date(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final epoch = int.tryParse(raw);
    if (epoch != null) {
      return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    }
    return DateTime.tryParse(raw);
  }
}

/// A film being accumulated across its `follow` and `watch` rows.
class _Movie {
  _Movie(this.title);

  final String title;
  int? year;
  bool watched = false;
  DateTime? watchedAt;
  int rewatches = 0;
}
