import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/export/auto_backup_service.dart';
import 'package:watch_nook/core/import_export/export/import_export_service.dart';

/// ADR-3 / the "two data domains" invariant (CLAUDE.md): user tables are
/// precious and exported; `CachedMedia`/`CachedEpisodes` are disposable and
/// `SharedPreferences` holds the metadata API key — neither may ever reach the
/// export or the backup file.
///
/// This suite must fail when someone *adds* a leak, not merely pass today, so
/// every assertion is paired with a positive one: a serializer that returned
/// `""` would satisfy every `isNot(contains(...))` here on its own.
void main() {
  // Seeded into the cache tables and prefs. If either domain ever reaches the
  // serializer, the canary rides along in the JSON.
  const cacheCanary = 'CACHE_LEAK_CANARY';
  const prefsCanary = 'PREFS_LEAK_CANARY';

  /// The 18 exported columns of `LibraryItems` — its 22 minus the 4 derived
  /// ones (AD-2: `id`, `watchedCount`, `lastWatchedSeason`,
  /// `lastWatchedEpisode`) — plus the nested `watches`. Enumerated, never
  /// counted: a count passes when one field is swapped for another.
  const itemKeys = {
    'mediaType',
    'recordedSource',
    'tmdbId',
    'tvdbId',
    'imdbId',
    'title',
    'year',
    'posterPath',
    'genresCsv',
    'runtimeMinutes',
    'trackStatus',
    'showStatus',
    'episodeCountTotal',
    'rating',
    'ratedAt',
    'addedAt',
    'updatedAt',
    'relinkFailed',
    'watches',
  };
  const watchKeys = {
    'season',
    'episode',
    'watchedAt',
    'runtimeMinutes',
    'isRewatch',
  };

  late AppDatabase db;
  late LibraryDao dao;
  late ImportExportService service;

  // Drift stores DateTime as whole unix seconds — seed on a second boundary.
  final added = DateTime(2026, 3, 4, 5, 6, 7);
  final watched = DateTime(2026, 3, 5, 20);

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = LibraryDao(db);
    service = ImportExportService(dao);

    // The service never calls `getInstance()`. That is the trap: the moment it
    // does, these values are what it gets back.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'apiKey': prefsCanary,
      'tmdb_api_key': prefsCanary,
    });

    // Every nullable user column is populated, so `_compact` drops nothing and
    // the emitted key set is the FULL one. A sparse row would let a newly
    // leaked nullable field hide behind its own null.
    final id = await dao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Severance',
        trackStatus: TrackStatus.watching,
        addedAt: added,
        updatedAt: added,
        tmdbId: const Value(95396),
        tvdbId: const Value(371980),
        imdbId: const Value('tt11280740'),
        year: const Value(2022),
        posterPath: const Value('/severance.jpg'),
        genresCsv: const Value('Drama,Mystery'),
        runtimeMinutes: const Value(47),
        showStatus: const Value('Returning Series'),
        episodeCountTotal: const Value(19),
        rating: const Value(9),
        ratedAt: Value(added),
        relinkFailed: const Value(true),
      ),
    );

    // ...and it is watched, so the derived columns are non-null too. Without a
    // watch, `lastWatchedSeason` stays null and an accidental export of it
    // would be silently compacted away — the leak would pass this suite.
    await dao.markWatched(
      id,
      season: 1,
      episode: 1,
      watchedAt: watched,
      runtimeMinutes: 47,
    );
    await dao.logRewatch(
      id,
      season: 1,
      episode: 1,
      watchedAt: watched,
      runtimeMinutes: 47,
    );

    await db
        .into(db.cachedMedia)
        .insert(
          CachedMediaCompanion.insert(
            source: MetadataSourceKind.tmdb,
            mediaType: MediaType.tv,
            sourceId: 95396,
            payload: '{"overview":"$cacheCanary"}',
            fetchedAt: added,
            title: cacheCanary,
            overview: const Value(cacheCanary),
            posterPath: const Value('/$cacheCanary.jpg'),
            genresCsv: const Value(cacheCanary),
          ),
        );
    await db
        .into(db.cachedEpisodes)
        .insert(
          CachedEpisodesCompanion.insert(
            source: MetadataSourceKind.tmdb,
            showSourceId: 95396,
            seasonNumber: 1,
            episodeNumber: 1,
            fetchedAt: added,
            title: const Value(cacheCanary),
            overview: const Value(cacheCanary),
          ),
        );
  });

  tearDown(() => db.close());

  /// The exported items, decoded.
  Future<List<Map<String, Object?>>> exportedItems() async =>
      ((await service.exportMap())['items']! as List)
          .cast<Map<String, Object?>>();

  test('export carries the user library and neither cache nor prefs', () async {
    final json = await service.exportJson();

    // Positive first: an empty string passes every exclusion below for free.
    expect(json, contains('Severance'), reason: 'the user domain IS exported');

    expect(json, isNot(contains('CANARY')), reason: 'cache/prefs never export');
    expect(json, isNot(contains('apiKey')));
  });

  test('the top-level key set is frozen', () async {
    expect((await service.exportMap()).keys.toSet(), {
      'version',
      'exportedAt',
      'items',
    });
  });

  test('the per-item key set is frozen (allowlist, not a count)', () async {
    final item = (await exportedItems()).single;

    expect(
      item.keys.toSet(),
      itemKeys,
      reason: 'a new cache-derived field cannot slip into the export unnoticed',
    );

    final watches = (item['watches']! as List).cast<Map<String, Object?>>();
    expect(watches, hasLength(2), reason: 'first watch + rewatch, both full');
    for (final watch in watches) {
      expect(watch.keys.toSet(), watchKeys);
    }
  });

  test('derived columns are recomputed on restore, never exported', () async {
    // They are non-null in the DB, so their absence below is a choice the
    // serializer made — not `_compact` dropping a null.
    final row = (await dao.getAll()).single;
    expect(row.watchedCount, 1);
    expect(row.lastWatchedSeason, isNotNull);

    final item = (await exportedItems()).single;
    for (final derived in [
      'id',
      'watchedCount',
      'lastWatchedSeason',
      'lastWatchedEpisode',
    ]) {
      expect(item, isNot(contains(derived)), reason: 'AD-2: $derived derives');
    }

    final watches = (item['watches']! as List).cast<Map<String, Object?>>();
    for (final watch in watches) {
      expect(watch, isNot(contains('id')));
      expect(watch, isNot(contains('libraryItemId')), reason: 'AD-3: nested');
    }
  });

  test('the serializer names neither a cache table nor prefs', () {
    // Catches the leak at the import statement rather than in the JSON.
    //
    // Comments are stripped first: that file's own INVARIANT doc comment names
    // the very symbols forbidden here, and prose must not fail the scan.
    //
    // Underscores are stripped too, so ONE spelling catches a symbol in both
    // the forms it can arrive in — the class (`SharedPreferences`) and the
    // import path that drags it in (`shared_preferences.dart`). Lowercasing
    // alone matches only the class, and the import is the earlier leak.
    const path = 'lib/core/import_export/export/import_export_service.dart';
    final code = File(path)
        .readAsStringSync()
        .replaceAll(RegExp('//.*'), '')
        .replaceAll('_', '')
        .toLowerCase();

    // Guard the guard — a regex that ate the whole file would pass silently.
    expect(code, contains('librarydao'), reason: 'the scan still sees code');

    for (final symbol in [
      'cachedmedia', // CachedMedia   / cached_media
      'cachedepisodes', // CachedEpisodes / cached_episodes
      'mediacachedao', // MediaCacheDao  / media_cache_dao.dart
      'sharedpreferences', // SharedPreferences / shared_preferences.dart
    ]) {
      expect(
        code,
        isNot(contains(symbol)),
        reason: '$symbol is the disposable/secret domain — keep it out',
      );
    }
  });

  test('the auto-backup snapshot inherits the exclusion', () async {
    final dir = await Directory.systemTemp.createTemp('watchnook_export_excl');
    addTearDown(() => dir.delete(recursive: true));

    final backup = AutoBackupService(
      service: service,
      dao: dao,
      directory: dir,
    );
    await backup.snapshot();
    final written = await backup.file.readAsString();

    expect(written, contains('Severance'), reason: 'the backup is not empty');
    expect(written, isNot(contains('CANARY')));
    expect(written, isNot(contains('apiKey')));
    expect(jsonDecode(written), isA<Map<String, Object?>>());
  });
}
