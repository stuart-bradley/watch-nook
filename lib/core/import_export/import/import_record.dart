import 'package:flutter/foundation.dart';
import 'package:watch_nook/core/database/tables.dart';

/// One viewing of one coordinate, as read out of an export file.
///
/// Both [season] and [episode] null means a **movie** — the same shape
/// `WatchEvents` stores, so the applier never has to translate.
@immutable
class ImportWatch {
  /// Creates an [ImportWatch].
  const ImportWatch({
    this.season,
    this.episode,
    this.watchedAt,
    this.isRewatch = false,
  });

  /// Aired-order season. Null for a movie.
  final int? season;

  /// Aired-order episode. Null for a movie.
  final int? episode;

  /// When it was watched, if the export said. Null = watched, date unknown.
  final DateTime? watchedAt;

  /// True for an extra viewing appended on top of the first watch.
  final bool isRewatch;

  /// The `(season, episode)` this watch belongs to — the coordinate the
  /// idempotent watched-marker and the rewatch deficit are both keyed by.
  (int?, int?) get coordinate => (season, episode);
}

/// One title read out of an export, normalized to the **database's** shape
/// rather than the source's (AD-2). Importers do all source-specific parsing
/// and rating rescaling; the resolver and applier never learn which service a
/// record came from.
@immutable
class ImportRecord {
  /// Creates an [ImportRecord].
  const ImportRecord({
    required this.mediaType,
    required this.title,
    this.year,
    this.imdbId,
    this.tmdbId,
    this.tvdbId,
    this.trackStatus,
    this.rating,
    this.ratedAt,
    this.watches = const [],
  });

  /// Movie or TV show.
  final MediaType mediaType;

  /// Display title, as the export spelled it.
  final String title;

  /// Release / first-air year, if the export carried one.
  final int? year;

  /// IMDb id — the strongest identity, and the only one that is universal.
  final String? imdbId;

  /// TheMovieDB id, if the export carried one.
  final int? tmdbId;

  /// TheTVDB id, if the export carried one.
  final int? tvdbId;

  /// The status the export implies. Null lets the applier default it.
  final TrackStatus? trackStatus;

  /// User rating on the DB's 0–10 scale. Importers rescale at their boundary
  /// (Letterboxd's 0.5–5.0 doubles; IMDb/Trakt are already 1–10).
  final int? rating;

  /// When the rating was given, if the export said.
  final DateTime? ratedAt;

  /// Every viewing this export knows about, first-watches and rewatches.
  final List<ImportWatch> watches;

  /// True when the export recorded at least one first-watch (not a rewatch) —
  /// the applier's cue for defaulting [trackStatus].
  bool get hasFirstWatch => watches.any((w) => !w.isRewatch);
}

/// What an importer read out of one archive: the records it understood, and the
/// number of rows it had to drop. Degrading is the contract (AD-7) — a bad row
/// costs a row, never the import — so the count is surfaced, never swallowed.
typedef ParseResult = ({List<ImportRecord> records, int skippedRows});
