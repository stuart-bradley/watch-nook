import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/merge_applier.dart';
import 'package:watch_nook/core/import_export/import/resolver.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// #23 / US-11 — **import merges, it never wipes.** These are the regression
/// tests for the import-vs-restore invariant (CLAUDE.md), written from "what
/// does the bug look like?" rather than "does the happy path work?":
///
/// - a second import forks a duplicate item, or re-inserts every watch event;
/// - `plays: 3` appends two more rewatch rows on *every* re-import, so a
///   rewatch counter climbs forever;
/// - an import overwrites the rating or status the user set by hand;
/// - an import deletes watch history the export happens not to mention;
/// - an ambiguous match is applied instead of being queued for a human.
///
/// Real in-memory Drift, not a mock DAO — the id-block dedupe and the unique
/// indexes are precisely what is under test.

void main() {
  late AppDatabase db;
  late LibraryDao dao;
  late MergeApplier applier;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = LibraryDao(db);
    applier = MergeApplier(dao: dao, sourceKind: MetadataSourceKind.tmdb);
  });
  tearDown(() => db.close());

  Future<List<WatchEvent>> allEvents() => db.select(db.watchEvents).get();
  Future<List<LibraryItem>> allItems() => db.select(db.libraryItems).get();

  ImportRecord theOffice({
    List<ImportWatch> watches = const [],
    String? imdbId,
    int? tmdbId,
    int? tvdbId = 73244,
    TrackStatus? status,
    int? rating,
  }) => ImportRecord(
    mediaType: MediaType.tv,
    title: 'The Office',
    year: 2005,
    imdbId: imdbId,
    tmdbId: tmdbId,
    tvdbId: tvdbId,
    trackStatus: status,
    rating: rating,
    watches: watches,
  );

  const s1e1 = ImportWatch(season: 1, episode: 1);
  const s1e2 = ImportWatch(season: 1, episode: 2);

  group('re-import is a no-op', () {
    test(
      'applying the same records twice changes nothing the second time',
      () async {
        final records = [
          Auto(theOffice(watches: const [s1e1, s1e2])),
          const Auto(
            ImportRecord(
              mediaType: MediaType.movie,
              title: 'Parasite',
              year: 2019,
              imdbId: 'tt6751668',
              watches: [ImportWatch()],
            ),
          ),
        ];

        final first = await applier.apply(records);
        final itemsAfterFirst = await allItems();
        final eventsAfterFirst = await allEvents();

        final second = await applier.apply(records);

        expect(first.itemsAdded, 2);
        expect(first.watchEventsAdded, 3);

        expect(second.itemsAdded, 0, reason: 'dedupe by id block');
        expect(second.watchEventsAdded, 0, reason: 'markWatched is idempotent');
        expect(await allItems(), hasLength(itemsAfterFirst.length));
        expect(await allEvents(), hasLength(eventsAfterFirst.length));
      },
    );

    test('a rewatch count does not climb on every re-import', () async {
      // The sharpest regression: `logRewatch` appends unconditionally, so an
      // applier that replays `plays: 3` blindly grows the row count forever.
      final record = Auto(
        theOffice(
          watches: const [
            s1e1,
            ImportWatch(season: 1, episode: 1, isRewatch: true),
            ImportWatch(season: 1, episode: 1, isRewatch: true),
          ],
        ),
      );

      final first = await applier.apply([record]);
      final second = await applier.apply([record]);
      final third = await applier.apply([record]);

      expect(first.rewatchesAdded, 2);
      expect(second.rewatchesAdded, 0);
      expect(third.rewatchesAdded, 0);
      expect(
        (await allEvents()).where((e) => e.isRewatch),
        hasLength(2),
        reason: 'exactly the two the export knows about',
      );
    });

    test('a genuinely new rewatch still lands on a re-import', () async {
      await applier.apply([
        Auto(
          theOffice(
            watches: const [
              s1e1,
              ImportWatch(season: 1, episode: 1, isRewatch: true),
            ],
          ),
        ),
      ]);

      final second = await applier.apply([
        Auto(
          theOffice(
            watches: const [
              s1e1,
              ImportWatch(season: 1, episode: 1, isRewatch: true),
              ImportWatch(season: 1, episode: 1, isRewatch: true),
            ],
          ),
        ),
      ]);

      expect(second.rewatchesAdded, 1, reason: 'the deficit, not the total');
      expect((await allEvents()).where((e) => e.isRewatch), hasLength(2));
    });
  });

  group("the user's own facts win", () {
    test(
      'an existing rating and status survive a conflicting import',
      () async {
        await applier.apply([
          Auto(theOffice(status: TrackStatus.dropped, rating: 3)),
        ]);

        await applier.apply([
          Auto(theOffice(status: TrackStatus.completed, rating: 10)),
        ]);

        final item = (await allItems()).single;
        expect(item.trackStatus, TrackStatus.dropped);
        expect(item.rating, 3);
      },
    );

    test('a null rating is filled, never clobbered', () async {
      await applier.apply([Auto(theOffice())]);
      final summary = await applier.apply([Auto(theOffice(rating: 8))]);

      final item = (await allItems()).single;
      expect(item.rating, 8);
      expect(item.ratedAt, isNotNull);
      expect(summary.itemsUpdated, 1);
    });

    test('watch history the export omits is never deleted', () async {
      await applier.apply([
        Auto(theOffice(watches: const [s1e1, s1e2])),
      ]);

      // A second, thinner export (say IMDb, which carries no episodes at all).
      await applier.apply([Auto(theOffice())]);

      expect(await allEvents(), hasLength(2));
      expect((await allItems()).single.watchedCount, 2);
    });
  });

  group('id-block dedupe', () {
    test(
      'a tvdb-only row absorbs the imdb and tmdb ids of a later import',
      () async {
        await applier.apply([Auto(theOffice())]);

        final summary = await applier.apply([
          Auto(theOffice(imdbId: 'tt0386676', tmdbId: 2316)),
        ]);

        final item = (await allItems()).single;
        expect(summary.itemsAdded, 0);
        expect(summary.itemsUpdated, 1);
        expect(item.imdbId, 'tt0386676');
        expect(item.tmdbId, 2316);
        expect(item.tvdbId, 73244);
      },
    );

    test(
      'a backend match supplies ids and artwork the export lacked',
      () async {
        const hit = MediaSearchResult(
          kind: MediaKind.movie,
          title: 'The Social Network',
          tmdbId: 37799,
          imdbId: 'tt1285016',
          year: 2010,
          posterPath: '/poster.jpg',
        );
        const record = ImportRecord(
          mediaType: MediaType.movie,
          title: 'The Social Network',
          year: 2010,
        );

        await applier.apply([const Auto(record, hit)]);

        final item = (await allItems()).single;
        expect(item.tmdbId, 37799);
        expect(item.imdbId, 'tt1285016');
        expect(item.posterPath, '/poster.jpg');
      },
    );

    test('an id collision skips one record and applies the rest', () async {
      // `tt111` belongs to a row that does *not* carry tmdb 500, and tmdb 500
      // belongs to another row. Filling both onto the imdb match violates the
      // unique index — the record must roll back whole, not half-write.
      await applier.apply([
        const Auto(
          ImportRecord(
            mediaType: MediaType.movie,
            title: 'Heat',
            year: 1995,
            imdbId: 'tt111',
          ),
        ),
        const Auto(
          ImportRecord(
            mediaType: MediaType.movie,
            title: 'Collateral',
            year: 2004,
            tmdbId: 500,
          ),
        ),
      ]);

      final summary = await applier.apply([
        const Auto(
          ImportRecord(
            mediaType: MediaType.movie,
            title: 'Heat',
            year: 1995,
            imdbId: 'tt111',
            tmdbId: 500,
          ),
        ),
        Auto(theOffice()),
      ]);

      expect(summary.skippedRows, 1);
      expect(summary.itemsAdded, 1, reason: 'The Office still lands');
      expect(await allItems(), hasLength(3));

      final heat = (await allItems()).firstWhere((i) => i.title == 'Heat');
      expect(heat.tmdbId, isNull, reason: 'rolled back, not half-written');
    });
  });

  group('resolution kinds', () {
    test('an ambiguous record is queued, not applied', () async {
      final summary = await applier.apply([
        Ambiguous(theOffice(watches: const [s1e1]), const []),
      ]);

      expect(summary.ambiguous, 1);
      expect(summary.itemsAdded, 0);
      expect(await allItems(), isEmpty);
    });

    test(
      'an unresolved record still lands with the ids it carries (US-13)',
      () async {
        // The metadata API being down must never cost the user their history.
        final summary = await applier.apply([
          Unresolved(theOffice(watches: const [s1e1]), 'offline'),
        ]);

        expect(summary.itemsAdded, 1);
        expect(summary.watchEventsAdded, 1);
        expect((await allItems()).single.tvdbId, 73244);
        expect((await allItems()).single.posterPath, isNull);
      },
    );
  });

  group('watch history shape', () {
    test('per-episode watch dates survive the bulk write', () async {
      // Local, not UTC: drift stores `dateTime()` as unix seconds and reads it
      // back local, and `DateTime ==` compares `isUtc` too.
      final d1 = DateTime(2024, 3);
      final d2 = DateTime(2024, 5, 9);

      await applier.apply([
        Auto(
          theOffice(
            watches: [
              ImportWatch(season: 1, episode: 1, watchedAt: d1),
              ImportWatch(season: 1, episode: 2, watchedAt: d2),
            ],
          ),
        ),
      ]);

      final events = await allEvents();
      expect(
        events.map((e) => (e.episodeNumber, e.watchedAt)),
        containsAll([(1, d1), (2, d2)]),
      );
    });

    test(
      'a movie watch stores null coordinates, not a half-null row',
      () async {
        await applier.apply([
          const Auto(
            ImportRecord(
              mediaType: MediaType.movie,
              title: 'Parasite',
              year: 2019,
              watches: [ImportWatch()],
            ),
          ),
        ]);

        final event = (await allEvents()).single;
        expect(event.seasonNumber, isNull);
        expect(event.episodeNumber, isNull);
        expect((await allItems()).single.watchedCount, 1);
      },
    );

    test(
      'a tv watch missing a coordinate is dropped, not half-written',
      () async {
        final summary = await applier.apply([
          Auto(theOffice(watches: const [ImportWatch(season: 1)])),
        ]);

        expect(summary.watchEventsAdded, 0);
        expect(await allEvents(), isEmpty);
      },
    );

    test(
      'status defaults follow the history when the export is silent',
      () async {
        await applier.apply([
          Auto(theOffice(watches: const [s1e1])),
          const Auto(
            ImportRecord(mediaType: MediaType.tv, title: 'Andor', tvdbId: 1),
          ),
          const Auto(
            ImportRecord(
              mediaType: MediaType.movie,
              title: 'Heat',
              year: 1995,
              watches: [ImportWatch()],
            ),
          ),
        ]);

        final items = await allItems();
        expect(
          items.firstWhere((i) => i.tvdbId == 73244).trackStatus,
          TrackStatus.watching,
        );
        expect(
          items.firstWhere((i) => i.title == 'Andor').trackStatus,
          TrackStatus.watchlist,
        );
        expect(
          items.firstWhere((i) => i.title == 'Heat').trackStatus,
          TrackStatus.completed,
        );
      },
    );
  });
}
