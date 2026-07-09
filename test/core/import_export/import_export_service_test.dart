import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/export/import_export_service.dart';

void main() {
  late AppDatabase db;
  late LibraryDao dao;
  late ImportExportService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = LibraryDao(db);
    service = ImportExportService(dao);
  });
  tearDown(() => db.close());

  // Drift stores DateTime as whole unix seconds, so seed on second boundaries
  // or a round-trip comparison fails on truncation, not on logic.
  final added = DateTime(2026, 3, 4, 5, 6, 7);
  final watched = DateTime(2026, 3, 5, 20);

  Future<int> seedMovie() => dao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.movie,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Dune, Part Two "Extended"',
      trackStatus: TrackStatus.completed,
      addedAt: added,
      updatedAt: added,
      tmdbId: const Value(693134),
      imdbId: const Value('tt15239678'),
      year: const Value(2024),
      posterPath: const Value('/dune.jpg'),
      genresCsv: const Value('Science Fiction,Adventure'),
      runtimeMinutes: const Value(166),
      rating: const Value(9),
      ratedAt: Value(added),
    ),
  );

  Future<int> seedShow() => dao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.tv,
      recordedSource: MetadataSourceKind.tvdb,
      title: 'Severance',
      trackStatus: TrackStatus.watching,
      addedAt: added,
      updatedAt: added,
      tvdbId: const Value(371980),
      showStatus: const Value('Returning Series'),
      episodeCountTotal: const Value(19),
      relinkFailed: const Value(true),
    ),
  );

  /// A minimal item document that restores cleanly, before [overrides] /
  /// [remove] make it adversarial.
  Map<String, Object?> itemDoc({
    Map<String, Object?> overrides = const {},
    List<String> remove = const [],
  }) {
    final map = <String, Object?>{
      'mediaType': 'movie',
      'recordedSource': 'tmdb',
      'title': 'Arrival',
      'trackStatus': 'completed',
      'addedAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-02T00:00:00.000Z',
      ...overrides,
    };
    remove.forEach(map.remove);
    return map;
  }

  String doc(List<Map<String, Object?>> items) =>
      jsonEncode({'version': 1, 'items': items});

  group('export', () {
    test('empty library exports items: [] and restores to empty', () async {
      final map = await service.exportMap();
      expect(map['version'], 1);
      expect(map['items'], isEmpty);

      final summary = await service.restore(await service.exportJson());
      expect(summary.itemsRestored, 0);
      expect(await dao.getAll(), isEmpty);
    });

    test('omits nulls and derived columns; nests watches', () async {
      final id = await seedShow();
      await dao.markWatched(id, season: 1, episode: 1, watchedAt: watched);

      final items = (await service.exportMap())['items']! as List;
      final item = items.single as Map<String, Object?>;

      // Derived (AD-2) — the file must not be able to lie about these.
      expect(item.keys, isNot(contains('id')));
      expect(item.keys, isNot(contains('watchedCount')));
      expect(item.keys, isNot(contains('lastWatchedSeason')));
      expect(item.keys, isNot(contains('lastWatchedEpisode')));
      // Null columns are absent, not `null`.
      expect(item.keys, isNot(contains('tmdbId')));
      expect(item.keys, isNot(contains('rating')));
      // Non-null falsy values survive compaction.
      expect(item['relinkFailed'], isTrue);
      expect(item['tvdbId'], 371980);

      final watch = (item['watches']! as List).single as Map<String, Object?>;
      expect(watch.keys, isNot(contains('libraryItemId')));
      expect(watch['season'], 1);
      expect(watch['isRewatch'], isFalse);
      expect(watch['watchedAt'], watched.toUtc().toIso8601String());
    });

    test('exportedAt comes from the injected Clock, never DateTime.now', () {
      final frozen = DateTime.utc(2030, 1, 2, 3, 4, 5);
      return withClock(Clock.fixed(frozen), () async {
        final map = await service.exportMap();
        expect(map['exportedAt'], '2030-01-02T03:04:05.000Z');
      });
    });
  });

  group('round-trip', () {
    test('export → wipe → restore is identical (ignoring ids)', () async {
      final movieId = await seedMovie();
      final showId = await seedShow();
      await dao.markWatched(
        movieId,
        watchedAt: watched,
        runtimeMinutes: 166,
      );
      await dao.logRewatch(
        movieId,
        watchedAt: watched.add(const Duration(days: 30)),
      );
      await dao.markWatched(showId, season: 1, episode: 1, watchedAt: watched);
      await dao.markWatched(showId, season: 1, episode: 2);

      final before = await dao.getAll();
      final beforeEvents = {
        for (final item in before)
          item.title: [
            for (final e in await dao.watchEventsFor(item.id))
              (
                e.seasonNumber,
                e.episodeNumber,
                e.watchedAt,
                e.runtimeMinutes,
                e.isRewatch,
              ),
          ],
      };

      final json = await service.exportJson();
      await dao.deleteAllUserData();
      expect(await dao.getAll(), isEmpty);

      final summary = await service.restore(json);
      expect(summary.itemsRestored, 2);
      expect(summary.watchEventsRestored, 4);
      expect(summary.skippedItems, 0);

      final after = await dao.getAll();
      expect(
        after.map((i) => i.copyWith(id: 0)).toSet(),
        before.map((i) => i.copyWith(id: 0)).toSet(),
      );

      for (final item in after) {
        final events = [
          for (final e in await dao.watchEventsFor(item.id))
            (
              e.seasonNumber,
              e.episodeNumber,
              e.watchedAt,
              e.runtimeMinutes,
              e.isRewatch,
            ),
        ];
        expect(events, unorderedEquals(beforeEvents[item.title]!));
      }
    });

    test('watchedCount / lastWatched* are recomputed, not trusted', () async {
      final showId = await seedShow();
      await dao.markWatched(showId, season: 1, episode: 1);
      await dao.markWatched(showId, season: 2, episode: 3);
      await dao.logRewatch(showId, season: 1, episode: 1);

      final json = await service.exportJson();
      await service.restore(json);

      final show = (await dao.getAll()).single;
      expect(show.watchedCount, 2); // the rewatch does not inflate it
      expect(show.lastWatchedSeason, 2);
      expect(show.lastWatchedEpisode, 3);
    });
  });

  group('restore — version gate', () {
    /// Every rejected document must leave a **non-empty** library untouched:
    /// the wipe must never precede the gate.
    Future<void> expectNoWipe(String json) async {
      final summary = await service.restore(json);
      expect(summary.itemsRestored, 0);
      expect(summary.watchEventsRestored, 0);
      expect((await dao.getAll()).single.title, 'Severance');
    }

    setUp(seedShow);

    test('unknown, zero, stringly, absent versions all reject', () async {
      await expectNoWipe(jsonEncode({'version': 99, 'items': <Object>[]}));
      await expectNoWipe(jsonEncode({'version': 0, 'items': <Object>[]}));
      await expectNoWipe(jsonEncode({'version': '1', 'items': <Object>[]}));
      await expectNoWipe(jsonEncode({'items': <Object>[]}));
      await expectNoWipe(jsonEncode(<Object>[]));
      // A v1 doc whose `items` is not a list is not a v1 doc.
      await expectNoWipe(jsonEncode({'version': 1, 'items': 'nope'}));
    });

    test('a valid v1 doc replaces rather than merges', () async {
      final summary = await service.restore(doc([itemDoc()]));
      expect(summary.itemsRestored, 1);
      expect((await dao.getAll()).single.title, 'Arrival');
    });
  });

  group('restore — malformed input', () {
    test('syntactically invalid JSON throws FormatException', () {
      expect(() => service.restore('not json'), throwsFormatException);
    });

    test(
      'structurally valid but wrongly typed items drop, never throw',
      () async {
        final cases = <String, Map<String, Object?>>{
          'mediaType not an enum name': itemDoc(overrides: {'mediaType': 42}),
          'mediaType unknown enum name': itemDoc(
            overrides: {'mediaType': 'anime'},
          ),
          'title null': itemDoc(overrides: {'title': null}),
          'addedAt an int': itemDoc(overrides: {'addedAt': 1767225600}),
          'addedAt unparseable': itemDoc(overrides: {'addedAt': 'yesterday'}),
          'trackStatus missing': itemDoc(remove: ['trackStatus']),
          'recordedSource missing': itemDoc(remove: ['recordedSource']),
          'both dates absent': itemDoc(remove: ['addedAt', 'updatedAt']),
        };

        for (final entry in cases.entries) {
          final summary = await service.restore(doc([entry.value]));
          expect(summary.skippedItems, 1, reason: entry.key);
          expect(summary.itemsRestored, 0, reason: entry.key);
          expect(await dao.getAll(), isEmpty, reason: entry.key);
        }
      },
    );

    test('a non-map item drops without taking the file with it', () async {
      final json = jsonEncode({
        'version': 1,
        'items': ['not an item', itemDoc()],
      });
      final summary = await service.restore(json);
      expect(summary.skippedItems, 1);
      expect((await dao.getAll()).single.title, 'Arrival');
    });

    test('updatedAt absent falls back to addedAt', () async {
      final summary = await service.restore(
        doc([
          itemDoc(remove: ['updatedAt']),
        ]),
      );
      expect(summary.itemsRestored, 1);
      final item = (await dao.getAll()).single;
      expect(item.updatedAt, item.addedAt);
    });

    test('unknown extra keys are ignored, not fatal', () async {
      final summary = await service.restore(
        doc([
          itemDoc(overrides: {'watchedCount': 999, 'futureColumn': 'x'}),
        ]),
      );
      expect(summary.itemsRestored, 1);
      expect((await dao.getAll()).single.watchedCount, 0); // recomputed
    });

    test(
      'a bad item mid-file loses only itself; the wipe happens once',
      () async {
        await seedShow();
        final json = jsonEncode({
          'version': 1,
          'items': [
            itemDoc(overrides: {'title': 'Good One'}),
            itemDoc(overrides: {'mediaType': 'spaceship'}),
            itemDoc(
              overrides: {
                'title': 'Good Two',
                'watches': [
                  {'watchedAt': '2026-03-05T20:00:00.000Z', 'isRewatch': false},
                  {'isRewatch': true},
                  'not a watch',
                ],
              },
            ),
          ],
        });

        final summary = await service.restore(json);
        expect(summary.itemsRestored, 2);
        expect(summary.skippedItems, 1);
        expect(summary.watchEventsRestored, 2); // the non-map watch dropped

        final titles = (await dao.getAll()).map((i) => i.title);
        expect(titles, unorderedEquals(['Good One', 'Good Two']));
        expect(titles, isNot(contains('Severance'))); // replaced, not merged
      },
    );

    test('malformed watches never abort their item', () async {
      final summary = await service.restore(
        doc([
          itemDoc(overrides: {'watches': 'nope'}),
        ]),
      );
      expect(summary.itemsRestored, 1);
      expect(summary.watchEventsRestored, 0);
    });
  });

  group('two-domains invariant', () {
    test('a restore of a full export never touches the cache tables', () async {
      await db
          .into(db.cachedMedia)
          .insert(
            CachedMediaCompanion.insert(
              source: MetadataSourceKind.tmdb,
              mediaType: MediaType.movie,
              sourceId: 693134,
              payload: '{}',
              fetchedAt: added,
              title: 'Dune, Part Two',
            ),
          );
      await seedMovie();

      final json = await service.exportJson();
      expect(json, isNot(contains('payload')));
      expect(json, isNot(contains('fetchedAt')));

      await service.restore(json);
      expect(await db.select(db.cachedMedia).get(), hasLength(1));
    });
  });
}
