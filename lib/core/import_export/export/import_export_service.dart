import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/export/letterboxd_export.dart';

/// What a [ImportExportService.restore] actually wrote.
typedef RestoreSummary = ({
  int itemsRestored,
  int watchEventsRestored,
  int skippedItems,
});

/// One parsed item, ready to insert. Watches are nested (AD-3) so the file
/// carries no foreign keys and restore never remaps ids.
typedef _ParsedItem = ({
  LibraryItemsCompanion item,
  List<_ParsedWatch> watches,
});

typedef _ParsedWatch = ({
  int? season,
  int? episode,
  DateTime? watchedAt,
  int? runtimeMinutes,
  bool isRewatch,
});

/// The canonical portable format (ADR-6): **one** serializer, whose output is
/// both the manual export and the auto-backup snapshot.
///
/// INVARIANT (two data domains, CLAUDE.md): [dao] is the only collaborator.
/// This class must never reach the cache tables (`CachedMedia`,
/// `CachedEpisodes`) or `SharedPreferences` — the cache is disposable and
/// re-fetchable, and prefs hold the metadata API key. The #33 regression test
/// greps this file to keep it that way.
class ImportExportService {
  /// Creates an [ImportExportService] over the user-owned tables.
  const ImportExportService(this.dao);

  /// The user-owned tables. The **only** data this service may read or write.
  final LibraryDao dao;

  /// Format version of the JSON document — **not** the Drift `schemaVersion`.
  static const formatVersion = 1;

  /// The whole user-owned library as the canonical map. Fields are listed by
  /// name rather than copied from `row.toJson()`, so a future column is an
  /// export decision someone makes on purpose.
  ///
  /// Derived columns are omitted (AD-2): `id`, `watchedCount`,
  /// `lastWatched*` and `WatchEvents.libraryItemId` are all recomputed on
  /// restore, so the file cannot lie about them.
  Future<Map<String, Object?>> exportMap() async {
    final items = await dao.getAll();
    return {
      'version': formatVersion,
      'exportedAt': _iso(clock.now()),
      'items': [
        for (final item in items)
          _compact({
            'mediaType': item.mediaType.name,
            'recordedSource': item.recordedSource.name,
            'tmdbId': item.tmdbId,
            'tvdbId': item.tvdbId,
            'imdbId': item.imdbId,
            'title': item.title,
            'year': item.year,
            'posterPath': item.posterPath,
            'genresCsv': item.genresCsv,
            'runtimeMinutes': item.runtimeMinutes,
            'trackStatus': item.trackStatus.name,
            'showStatus': item.showStatus,
            'episodeCountTotal': item.episodeCountTotal,
            'rating': item.rating,
            'ratedAt': _iso(item.ratedAt),
            'addedAt': _iso(item.addedAt),
            'updatedAt': _iso(item.updatedAt),
            'relinkFailed': item.relinkFailed,
            'watches': [
              for (final w in await dao.watchEventsFor(item.id))
                _compact({
                  'season': w.seasonNumber,
                  'episode': w.episodeNumber,
                  'watchedAt': _iso(w.watchedAt),
                  'runtimeMinutes': w.runtimeMinutes,
                  'isRewatch': w.isRewatch,
                }),
            ],
          }),
      ],
    };
  }

  /// [exportMap], pretty-printed.
  Future<String> exportJson() async =>
      const JsonEncoder.withIndent('  ').convert(await exportMap());

  /// The user's films as a letterboxd.com/import CSV (#31). TV rows never
  /// reach [letterboxdCsv] — Letterboxd tracks films and nothing else.
  Future<String> exportLetterboxdCsv() async => letterboxdCsv([
    for (final item in await dao.getAll())
      if (item.mediaType == MediaType.movie)
        (item, await dao.watchEventsFor(item.id)),
  ]);

  /// **Replace** the library with [json] (AD-4). Restore replaces; import
  /// merges — this never calls `MergeApplier` and never preserves an existing
  /// row.
  ///
  /// The wipe happens *after* the version gate and inside the same transaction
  /// as the inserts, so an unreadable or half-bad file can never leave the user
  /// with less than they started with. A malformed **item** is dropped and
  /// counted; the rest of the file still lands.
  ///
  /// Throws [FormatException] on syntactically invalid JSON — the auto-backup
  /// caller (#32) is the one that swallows it, so a corrupt file cannot loop
  /// the boot.
  Future<RestoreSummary> restore(String json) async {
    const nothing = (itemsRestored: 0, watchEventsRestored: 0, skippedItems: 0);

    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) return nothing;
    // Unknown/absent/non-int version rejects WITHOUT wiping. "Reject" must not
    // decay into "assume v1": M5's manual restore has no empty-DB guard.
    if (_int(decoded['version']) != formatVersion) return nothing;

    final raw = decoded['items'];
    if (raw is! List) return nothing;

    var skipped = 0;
    final parsed = <_ParsedItem>[];
    for (final entry in raw) {
      final item = _parseItem(entry);
      if (item == null) {
        skipped++;
      } else {
        parsed.add(item);
      }
    }

    var events = 0;
    await dao.transaction(() async {
      await dao.deleteAllUserData();
      for (final p in parsed) {
        final id = await dao.insertItem(p.item);
        for (final w in p.watches) {
          await dao.insertWatchEvent(
            WatchEventsCompanion.insert(
              libraryItemId: id,
              seasonNumber: Value(w.season),
              episodeNumber: Value(w.episode),
              watchedAt: Value(w.watchedAt),
              runtimeMinutes: Value(w.runtimeMinutes),
              isRewatch: Value(w.isRewatch),
            ),
          );
          events++;
        }
        await dao.recomputeDenormalized(id);
      }
    });

    return (
      itemsRestored: parsed.length,
      watchEventsRestored: events,
      skippedItems: skipped,
    );
  }

  /// Parses one item, or null if a required field is missing or wrongly typed.
  ///
  /// Every field goes through a typed helper rather than an `as` cast: `as`
  /// raises [TypeError], which is an [Error] and so escapes `on Exception`
  /// (CLAUDE.md Dart gotcha). A structurally-valid-but-malformed item must cost
  /// one item, never the file.
  _ParsedItem? _parseItem(Object? entry) {
    if (entry is! Map<String, Object?>) return null;

    final mediaType = _enum(entry['mediaType'], MediaType.values);
    final recordedSource = _enum(
      entry['recordedSource'],
      MetadataSourceKind.values,
    );
    final title = _str(entry['title']);
    final trackStatus = _enum(entry['trackStatus'], TrackStatus.values);
    final addedAt = _date(entry['addedAt']);
    // A file that knows when a row was added but not when it was touched is
    // recoverable; one missing both is not.
    final updatedAt = _date(entry['updatedAt']) ?? addedAt;

    if (mediaType == null ||
        recordedSource == null ||
        title == null ||
        trackStatus == null ||
        addedAt == null ||
        updatedAt == null) {
      return null;
    }

    final rawWatches = entry['watches'];
    return (
      item: LibraryItemsCompanion.insert(
        mediaType: mediaType,
        recordedSource: recordedSource,
        title: title,
        trackStatus: trackStatus,
        addedAt: addedAt,
        updatedAt: updatedAt,
        tmdbId: Value(_int(entry['tmdbId'])),
        tvdbId: Value(_int(entry['tvdbId'])),
        imdbId: Value(_str(entry['imdbId'])),
        year: Value(_int(entry['year'])),
        posterPath: Value(_str(entry['posterPath'])),
        genresCsv: Value(_str(entry['genresCsv'])),
        runtimeMinutes: Value(_int(entry['runtimeMinutes'])),
        showStatus: Value(_str(entry['showStatus'])),
        episodeCountTotal: Value(_int(entry['episodeCountTotal'])),
        rating: Value(_int(entry['rating'])),
        ratedAt: Value(_date(entry['ratedAt'])),
        relinkFailed: Value(_bool(entry['relinkFailed']) ?? false),
      ),
      watches: [
        if (rawWatches is List)
          for (final w in rawWatches)
            if (w is Map<String, Object?>)
              (
                season: _int(w['season']),
                episode: _int(w['episode']),
                watchedAt: _date(w['watchedAt']),
                runtimeMinutes: _int(w['runtimeMinutes']),
                isRewatch: _bool(w['isRewatch']) ?? false,
              ),
      ],
    );
  }
}

/// Drops null values — absent and null read identically, and the file stays
/// small. `false` and `0` survive.
Map<String, Object?> _compact(Map<String, Object?> map) => {
  for (final e in map.entries)
    if (e.value != null) e.key: e.value,
};

/// Every [DateTime] is written as UTC: a local-vs-`Z` mismatch would silently
/// shift a round-tripped date across a day boundary.
String? _iso(DateTime? value) => value?.toUtc().toIso8601String();

String? _str(Object? v) => v is String ? v : null;
int? _int(Object? v) => v is int ? v : null;
bool? _bool(Object? v) => v is bool ? v : null;
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

T? _enum<T extends Enum>(Object? v, List<T> values) {
  final name = _str(v);
  if (name == null) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
