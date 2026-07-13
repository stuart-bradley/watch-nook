import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/resolver.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// What an import actually did. Counts, not rows — the library grid is the
/// source of truth for what landed.
@immutable
class ImportSummary {
  /// Creates an [ImportSummary].
  const ImportSummary({
    this.itemsAdded = 0,
    this.itemsUpdated = 0,
    this.watchEventsAdded = 0,
    this.rewatchesAdded = 0,
    this.skippedRows = 0,
    this.ambiguous = 0,
  });

  /// Titles that were not already in the library.
  final int itemsAdded;

  /// Titles that already existed and had null columns filled in.
  final int itemsUpdated;

  /// First-watch markers inserted (a re-import of the same history adds none).
  final int watchEventsAdded;

  /// Rewatch rows appended.
  final int rewatchesAdded;

  /// Records the applier could not write (e.g. an id collision with a
  /// different existing row). The rest of the import still lands.
  final int skippedRows;

  /// Records parked in the confirmation queue rather than applied.
  final int ambiguous;
}

/// Writes [Resolution]s into the user-owned tables **additively** (ADR-5).
///
/// The import-vs-restore invariant (CLAUDE.md): a restore *replaces*, an import
/// *merges*. So this class never deletes a row and never overwrites a value the
/// user already owns — an import is someone else's facts about the user's
/// library, and the user's own facts win. Concretely:
///
/// - the title is deduped through [LibraryDao.findByIdentity]'s id-block
///   cascade (imdb → tmdb → tvdb → title+year), so re-importing cannot fork a
///   second row for the same show;
/// - only **null** columns are filled in; an existing `trackStatus` or `rating`
///   survives a conflicting re-import untouched;
/// - first-watches go through the idempotent [LibraryDao.markManyWatched], so a
///   second import of the same history inserts nothing;
/// - rewatches append only the **deficit** over what is already stored. Without
///   that, a `plays: 3` record would append two more rewatch rows on *every*
///   re-import — the sharpest regression this class exists to prevent.
///
/// [Ambiguous] resolutions are counted and skipped: they belong to the
/// confirmation queue, and come back here as [Auto] once a human has picked.
class MergeApplier {
  /// Creates a [MergeApplier]. [sourceKind] stamps `recordedSource` on rows it
  /// inserts, pinning their ids to the backend that resolved them (ADR-4).
  const MergeApplier({required this.dao, required this.sourceKind});

  /// The user-domain DAO. Every write goes through it — no raw SQL.
  final LibraryDao dao;

  /// The backend the [Resolver] ran against.
  final MetadataSourceKind sourceKind;

  /// Applies every resolution, returning what changed. One bad record is
  /// counted in [ImportSummary.skippedRows] and rolled back on its own; it
  /// never aborts the import (AD-7).
  Future<ImportSummary> apply(Iterable<Resolution> resolutions) async {
    var itemsAdded = 0;
    var itemsUpdated = 0;
    var watchEventsAdded = 0;
    var rewatchesAdded = 0;
    var skippedRows = 0;
    var ambiguous = 0;

    for (final resolution in resolutions) {
      if (resolution is Ambiguous) {
        ambiguous++;
        continue;
      }
      final match = resolution is Auto ? resolution.match : null;
      try {
        final outcome = await _applyOne(resolution.record, match);
        if (outcome.added) itemsAdded++;
        if (outcome.updated) itemsUpdated++;
        watchEventsAdded += outcome.watchEvents;
        rewatchesAdded += outcome.rewatches;
      } on Object {
        // A unique-index collision (the record's imdb id already belongs to a
        // *different* row) or any other write failure. The record is dropped,
        // the import continues, and nothing partial was left behind.
        skippedRows++;
      }
    }

    return ImportSummary(
      itemsAdded: itemsAdded,
      itemsUpdated: itemsUpdated,
      watchEventsAdded: watchEventsAdded,
      rewatchesAdded: rewatchesAdded,
      skippedRows: skippedRows,
      ambiguous: ambiguous,
    );
  }

  /// One record, in one transaction: upsert the title, fill its null columns,
  /// then merge the watch history.
  Future<_Outcome> _applyOne(ImportRecord record, MediaSearchResult? match) =>
      dao.transaction(() async {
        final now = clock.now();
        final imdbId = match?.imdbId ?? record.imdbId;
        final tmdbId = match?.tmdbId ?? record.tmdbId;
        final tvdbId = match?.tvdbId ?? record.tvdbId;
        final title = match?.title ?? record.title;
        final year = match?.year ?? record.year;

        final before = await dao.findByIdentity(
          mediaType: record.mediaType,
          imdbId: imdbId,
          tmdbId: tmdbId,
          tvdbId: tvdbId,
          title: title,
          year: year,
        );

        final (:item, created: _) = await dao.addOrGetItem(
          LibraryItemsCompanion.insert(
            mediaType: record.mediaType,
            recordedSource: sourceKind,
            title: title,
            trackStatus: record.trackStatus ?? _defaultStatus(record),
            addedAt: now,
            updatedAt: now,
            tmdbId: Value(tmdbId),
            tvdbId: Value(tvdbId),
            imdbId: Value(imdbId),
            year: Value(year),
            posterPath: Value(match?.posterPath),
            rating: Value(record.rating),
            ratedAt: Value(
              record.rating == null ? null : record.ratedAt ?? now,
            ),
          ),
        );

        final updated =
            before != null && await _fillNullColumns(item, record, match, now);

        final watchEvents = await _applyFirstWatches(item.id, record);
        final rewatches = await _applyRewatchDeficit(item.id, record);

        return _Outcome(
          added: before == null,
          updated: updated,
          watchEvents: watchEvents,
          rewatches: rewatches,
        );
      });

  /// Fills the columns this record knows and the existing row does not. Never
  /// touches `trackStatus` — the user's own status outranks the export's — and
  /// only sets `rating` when there isn't one already. Returns true if it wrote.
  Future<bool> _fillNullColumns(
    LibraryItem item,
    ImportRecord record,
    MediaSearchResult? match,
    DateTime now,
  ) async {
    final ratable = item.rating == null && record.rating != null;
    final patch = LibraryItemsCompanion(
      imdbId: _fill(item.imdbId, match?.imdbId ?? record.imdbId),
      tmdbId: _fill(item.tmdbId, match?.tmdbId ?? record.tmdbId),
      tvdbId: _fill(item.tvdbId, match?.tvdbId ?? record.tvdbId),
      year: _fill(item.year, match?.year ?? record.year),
      posterPath: _fill(item.posterPath, match?.posterPath),
      rating: ratable ? Value(record.rating) : const Value.absent(),
      ratedAt: ratable ? Value(record.ratedAt ?? now) : const Value.absent(),
    );

    final wrote = [
      patch.imdbId,
      patch.tmdbId,
      patch.tvdbId,
      patch.year,
      patch.posterPath,
      patch.rating,
    ].any((v) => v.present);
    if (!wrote) return false;

    await dao.updateItem(item.id, patch);
    return true;
  }

  /// Present only when the row has a hole and the export can fill it.
  static Value<T> _fill<T extends Object>(T? existing, T? incoming) =>
      existing == null && incoming != null
      ? Value(incoming)
      : const Value.absent();

  /// The idempotent watched markers. Grouped by date so each distinct viewing
  /// date keeps its own `watchedAt` while still riding one bulk write (and one
  /// `recomputeDenormalized`) per group.
  ///
  /// A movie's coordinate is `(null, null)`, which `markManyWatched` cannot
  /// express, so it goes through `markWatched`. TV rows missing a coordinate
  /// are dropped by [_episodeMarks] and surface as a skipped watch, never as a
  /// half-null `WatchEvents` row.
  Future<int> _applyFirstWatches(int itemId, ImportRecord record) async {
    final firsts = record.watches.where((w) => !w.isRewatch);
    if (record.mediaType == MediaType.movie) {
      final before = await dao.watchEventsFor(itemId);
      if (before.any((e) => !e.isRewatch)) return 0; // already watched
      final watch = firsts.firstOrNull;
      if (watch == null) return 0;
      await dao.markWatched(itemId, watchedAt: watch.watchedAt);
      return 1;
    }

    final byDate = <DateTime?, List<EpisodeMark>>{};
    for (final mark in _episodeMarks(firsts)) {
      byDate.putIfAbsent(mark.$1, () => []).add(mark.$2);
    }

    var inserted = 0;
    for (final group in byDate.entries) {
      inserted += await dao.markManyWatched(
        itemId,
        group.value,
        watchedAt: group.key,
      );
    }
    return inserted;
  }

  /// Appends only the rewatches the row is **missing**, per coordinate:
  /// `max(0, wanted - stored)`. Re-importing the same file therefore appends
  /// nothing, while a genuinely new rewatch still lands.
  Future<int> _applyRewatchDeficit(int itemId, ImportRecord record) async {
    final wanted = <(int?, int?), List<ImportWatch>>{};
    for (final w in record.watches.where((w) => w.isRewatch)) {
      wanted.putIfAbsent(w.coordinate, () => []).add(w);
    }
    if (wanted.isEmpty) return 0;

    final stored = <(int?, int?), int>{};
    for (final e in await dao.watchEventsFor(itemId)) {
      if (!e.isRewatch) continue;
      final key = (e.seasonNumber, e.episodeNumber);
      stored[key] = (stored[key] ?? 0) + 1;
    }

    var appended = 0;
    for (final entry in wanted.entries) {
      for (final w in entry.value.skip(stored[entry.key] ?? 0)) {
        await dao.logRewatch(
          itemId,
          season: w.season,
          episode: w.episode,
          watchedAt: w.watchedAt,
        );
        appended++;
      }
    }
    return appended;
  }

  /// `(watchedAt, mark)` for every watch that carries a full aired coordinate.
  ///
  /// `runtimeMinutes` is null: an export knows what you watched, never how long
  /// it ran. Imported history therefore contributes to watch *counts* but not
  /// to watch *time* — the stats invariant forbids back-filling it from the
  /// disposable cache.
  static Iterable<(DateTime?, EpisodeMark)> _episodeMarks(
    Iterable<ImportWatch> watches,
  ) sync* {
    for (final w in watches) {
      final season = w.season;
      final episode = w.episode;
      if (season == null || episode == null) continue;
      yield (
        w.watchedAt,
        (
          season: season,
          episode: episode,
          runtimeMinutes: null,
        ),
      );
    }
  }

  /// Only used when an importer had nothing to say: a title with watch history
  /// is under way (a finished movie is finished), one without is a watchlist
  /// entry. Importers set the status explicitly wherever the export implies
  /// one, so this is a floor, never an override.
  static TrackStatus _defaultStatus(ImportRecord record) {
    if (!record.hasFirstWatch) return TrackStatus.watchlist;
    return record.mediaType == MediaType.movie
        ? TrackStatus.completed
        : TrackStatus.watching;
  }
}

/// What [MergeApplier._applyOne] did to one record.
@immutable
class _Outcome {
  const _Outcome({
    required this.added,
    required this.updated,
    required this.watchEvents,
    required this.rewatches,
  });

  final bool added;
  final bool updated;
  final int watchEvents;
  final int rewatches;
}
