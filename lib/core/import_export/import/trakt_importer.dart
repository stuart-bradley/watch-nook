import 'dart:convert';

import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';

/// Reads a Trakt export — either a single JSON document with `watched`,
/// `ratings` and `watchlist` sections (each split into `movies`/`shows`), or the
/// real "Settings → Data → Export" download, a zip of per-endpoint JSON arrays
/// (`watched-shows.json`, `watched-movies.json`, …); see [_decode].
///
/// Trakt carries a full `ids` block (imdb + tmdb + tvdb), so titles land on the
/// resolver's id rung with no search. Three things make it less trivial than it
/// looks:
/// - **`plays` is a count, not a flag.** `plays: 2` is one first watch plus one
///   rewatch; the deficit above the first play becomes `isRewatch` rows.
/// - **a title appears in several sections.** Watched + rated + watchlisted is
///   one record, keyed by its id block — never three.
/// - **the export is user-editable JSON.** `year` shows up as `"unknown"` and
///   `ids` can be missing, so every field is read defensively. An `as`-cast
///   throws `TypeError`, which `on Exception` never catches (CLAUDE.md).
///
/// `trackStatus` is deliberately left null: `MergeApplier` already defaults a
/// watched movie to `completed`, a watched show to `watching`, and an unwatched
/// title to `watchlist` — which is exactly what these sections mean.
class TraktImporter {
  const TraktImporter._();

  /// The sections we read, in the order a title's fields are filled in.
  static const _sections = ['watched', 'ratings', 'watchlist'];

  /// True when [archive] holds a JSON file shaped like a Trakt export.
  static bool canRead(ImportArchive archive) => _decode(archive) != null;

  /// Parses the export into one record per title, merged across sections.
  static ParseResult parse(ImportArchive archive) {
    final root = _decode(archive);
    if (root == null) return (records: const [], skippedRows: 0);

    final titles = <String, _Title>{};
    var skipped = 0;

    /// Finds-or-creates the record for the `movie`/`show` object in [row].
    _Title? titleOf(Map<String, dynamic> row, MediaType type) {
      final media = row[type == MediaType.movie ? 'movie' : 'show'];
      if (media is! Map<String, dynamic>) return null;
      final name = _string(media['title']);
      if (name == null) return null;

      final ids = media['ids'];
      final block = ids is Map ? ids : const <Object?, Object?>{};
      final imdbId = _string(block['imdb']);
      final tmdbId = _int(block['tmdb']);
      final tvdbId = _int(block['tvdb']);
      final year = _int(media['year']);

      // Each id rung is namespaced: a bare `603` is both a film's TMDB id and
      // some series' — and TMDB numbers movies and shows independently, so the
      // media type is part of identity too.
      final id = switch ((imdbId, tmdbId, tvdbId)) {
        (final String i, _, _) => 'imdb:$i',
        (_, final int t, _) => 'tmdb:$t',
        (_, _, final int t) => 'tvdb:$t',
        _ => 'title:${name.toLowerCase()}:$year',
      };
      return titles.putIfAbsent(
        '${type.name}/$id',
        () => _Title(
          mediaType: type,
          title: name,
          year: year,
          imdbId: imdbId,
          tmdbId: tmdbId,
          tvdbId: tvdbId,
        ),
      );
    }

    void each(
      String section,
      MediaType type,
      void Function(Map<String, dynamic> row, _Title title) apply,
    ) {
      final part = root[section];
      final rows = part is Map<String, dynamic>
          ? part[type == MediaType.movie ? 'movies' : 'shows']
          : null;
      if (rows is! List) return;
      for (final row in rows) {
        if (row is! Map<String, dynamic>) {
          skipped++;
          continue;
        }
        final title = titleOf(row, type);
        if (title == null) {
          skipped++;
          continue;
        }
        apply(row, title);
      }
    }

    for (final type in MediaType.values) {
      for (final section in _sections) {
        each(section, type, (row, title) {
          switch (section) {
            case 'watched':
              if (type == MediaType.movie) {
                title.addPlays(
                  _int(row['plays']),
                  _date(row['last_watched_at']),
                );
              } else {
                final before = title.watches.length;
                skipped += title.addSeasons(row['seasons']);
                // No episode tree (an export made without extended=full omits
                // `seasons`). Don't invent episode coordinates, but don't let a
                // genuinely-watched show import as an empty *watchlist* entry
                // either — mark it `watching` so it reads as started.
                if (title.watches.length == before) {
                  title.trackStatus ??= TrackStatus.watching;
                }
              }
            case 'ratings':
              final rating = _int(row['rating']);
              if (rating == null || rating < 1 || rating > 10) {
                skipped++;
                return;
              }
              title
                ..rating = rating
                ..ratedAt = _date(row['rated_at']);
            // `watchlist`: the row's existence is the whole payload.
          }
        });
      }
    }

    return (
      records: [for (final title in titles.values) title.toRecord()],
      skippedRows: skipped,
    );
  }

  /// A Trakt export in one of two real shapes, normalised to the single-object
  /// form the parser reads (`{watched: {movies, shows}, ...}`):
  ///
  /// 1. a **single JSON object** carrying a `watched`/`ratings`/`watchlist`
  ///    section (the API / older shape); or
  /// 2. the real **"Settings → Data → Export"** download — a zip of
  ///    per-endpoint JSON *arrays* (e.g. `watched-shows.json`). Without this
  ///    branch a real export is a single unmatched object → `canRead` false →
  ///    the whole import silently does nothing.
  ///
  /// Every other export here is CSV, so this doubles as the format sniff.
  static Map<String, dynamic>? _decode(ImportArchive archive) {
    for (final entry in archive.entries.entries) {
      if (!entry.key.toLowerCase().endsWith('.json')) continue;
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(entry.value, allowMalformed: true));
      } on FormatException {
        continue;
      }
      if (json is Map<String, dynamic> && _sections.any(json.containsKey)) {
        return json;
      }
    }
    return _assembleFromFiles(archive);
  }

  /// Builds the single-object shape from the multi-file export's watched
  /// arrays. (Ratings / watchlist per-file shapes aren't assembled yet — watch
  /// history is the priority; a real export sample can extend this.)
  static Map<String, dynamic>? _assembleFromFiles(ImportArchive archive) {
    final movies = _jsonArray(archive, 'watched-movies.json');
    final shows = _jsonArray(archive, 'watched-shows.json');
    if (movies == null && shows == null) return null;
    return {
      'watched': {'movies': ?movies, 'shows': ?shows},
    };
  }

  static List<Object?>? _jsonArray(ImportArchive archive, String name) {
    final text = archive.readText(name);
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      return json is List ? json : null;
    } on FormatException {
      return null;
    }
  }
}

/// A title being accumulated across the sections that mention it.
class _Title {
  _Title({
    required this.mediaType,
    required this.title,
    this.year,
    this.imdbId,
    this.tmdbId,
    this.tvdbId,
  });

  final MediaType mediaType;
  final String title;
  final int? year;
  final String? imdbId;
  final int? tmdbId;
  final int? tvdbId;
  int? rating;
  DateTime? ratedAt;

  /// Usually null (the applier defaults it); set to `watching` only for a
  /// watched show that carried no episode tree (the fallback).
  TrackStatus? trackStatus;
  final watches = <ImportWatch>[];

  /// `plays` counts viewings: the first is the watch, every one after it a
  /// rewatch. A missing or nonsense count still means "watched once" — the row
  /// is in the `watched` section, after all.
  void addPlays(int? plays, DateTime? at, {int? season, int? episode}) {
    final count = plays == null || plays < 1 ? 1 : plays;
    for (var i = 0; i < count; i++) {
      watches.add(
        ImportWatch(
          season: season,
          episode: episode,
          watchedAt: at,
          isRewatch: i > 0,
        ),
      );
    }
  }

  /// Episode-level history. Returns the number of rows it had to drop.
  int addSeasons(Object? seasons) {
    if (seasons is! List) return 0;
    var skipped = 0;
    for (final season in seasons) {
      final number = season is Map<String, dynamic>
          ? _int(season['number'])
          : null;
      final episodes = season is Map<String, dynamic>
          ? season['episodes']
          : null;
      if (number == null || episodes is! List) {
        skipped++;
        continue;
      }
      for (final episode in episodes) {
        if (episode is! Map<String, dynamic>) {
          skipped++;
          continue;
        }
        final coordinate = _int(episode['number']);
        if (coordinate == null) {
          skipped++;
          continue;
        }
        addPlays(
          _int(episode['plays']),
          _date(episode['last_watched_at']),
          season: number,
          episode: coordinate,
        );
      }
    }
    return skipped;
  }

  ImportRecord toRecord() => ImportRecord(
    mediaType: mediaType,
    title: title,
    year: year,
    imdbId: imdbId,
    tmdbId: tmdbId,
    tvdbId: tvdbId,
    trackStatus: trackStatus,
    rating: rating,
    ratedAt: ratedAt,
    watches: watches,
  );
}

/// `2019`, `"2019"` and `19.0` are all a year; `"unknown"` and `null` are not.
int? _int(Object? value) => switch (value) {
  final int value => value,
  final num value => value.toInt(),
  final String value => int.tryParse(value),
  _ => null,
};

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
