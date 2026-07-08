import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final now = DateTime(2026);

  LibraryItemsCompanion aShow({
    String title = 'Severance',
    int? tmdbId = 95396,
    int? tvdbId,
    String? imdbId,
    int? year,
    TrackStatus status = TrackStatus.watching,
  }) => LibraryItemsCompanion.insert(
    mediaType: MediaType.tv,
    recordedSource: MetadataSourceKind.tmdb,
    title: title,
    trackStatus: status,
    addedAt: now,
    updatedAt: now,
    tmdbId: Value(tmdbId),
    tvdbId: Value(tvdbId),
    imdbId: Value(imdbId),
    year: Value(year),
  );

  LibraryItemsCompanion aMovie({
    String title = 'Dune',
    int? tmdbId = 438631,
    TrackStatus status = TrackStatus.completed,
  }) => LibraryItemsCompanion.insert(
    mediaType: MediaType.movie,
    recordedSource: MetadataSourceKind.tmdb,
    title: title,
    trackStatus: status,
    addedAt: now,
    updatedAt: now,
    tmdbId: Value(tmdbId),
  );

  Future<void> insertWatch(
    int itemId, {
    int? season,
    int? episode,
    bool rewatch = false,
  }) => db
      .into(db.watchEvents)
      .insert(
        WatchEventsCompanion.insert(
          libraryItemId: itemId,
          seasonNumber: Value(season),
          episodeNumber: Value(episode),
          isRewatch: Value(rewatch),
        ),
      );

  group('LibraryDao round-trip', () {
    test('insert → getAll reads the row back with defaults applied', () async {
      final id = await db.libraryDao.insertItem(aShow());

      final all = await db.libraryDao.getAll();
      expect(all, hasLength(1));
      final item = all.single;
      expect(item.id, id);
      expect(item.title, 'Severance');
      expect(item.mediaType, MediaType.tv);
      expect(item.recordedSource, MetadataSourceKind.tmdb);
      expect(item.trackStatus, TrackStatus.watching);
      // Defaults land, not nulls.
      expect(item.watchedCount, 0);
      expect(item.relinkFailed, isFalse);
    });

    test('watchAll emits the current library', () async {
      await db.libraryDao.insertItem(aShow());
      final items = await db.libraryDao.watchAll().first;
      expect(items.map((i) => i.title), ['Severance']);
    });

    test('getItem returns the row, or null for an unknown id', () async {
      final id = await db.libraryDao.insertItem(aShow());
      expect((await db.libraryDao.getItem(id))?.title, 'Severance');
      expect(await db.libraryDao.getItem(999999), isNull);
    });
  });

  group('recomputeDenormalized (AD-4 — the join-free progress primitive)', () {
    test(
      'watchedCount counts non-rewatch rows only; a rewatch never inflates it '
      'nor moves lastWatched forward',
      () async {
        final id = await db.libraryDao.insertItem(aShow());
        await insertWatch(id, season: 1, episode: 1);
        await insertWatch(id, season: 1, episode: 2);
        // A rewatch of a LATER episode: must not raise the count nor advance
        // lastWatched* — it is not a first watch.
        await insertWatch(id, season: 1, episode: 5, rewatch: true);

        await db.libraryDao.recomputeDenormalized(id);

        final item = (await db.libraryDao.getItem(id))!;
        expect(item.watchedCount, 2);
        expect(item.lastWatchedSeason, 1);
        expect(item.lastWatchedEpisode, 2);
      },
    );

    test(
      'lastWatched* is the max AIRED coord — season beats episode',
      () async {
        final id = await db.libraryDao.insertItem(aShow());
        await insertWatch(id, season: 1, episode: 10);
        await insertWatch(id, season: 2, episode: 1);

        await db.libraryDao.recomputeDenormalized(id);

        final item = (await db.libraryDao.getItem(id))!;
        // A naive episode-only max would pick S1E10; the correct max is S2E1.
        expect(item.lastWatchedSeason, 2);
        expect(item.lastWatchedEpisode, 1);
        expect(item.watchedCount, 2);
      },
    );

    test('a partial unwatch moves lastWatched* back to the new max', () async {
      final id = await db.libraryDao.insertItem(aShow());
      await insertWatch(id, season: 1, episode: 1);
      await insertWatch(id, season: 1, episode: 2);
      await insertWatch(id, season: 1, episode: 3);
      await db.libraryDao.recomputeDenormalized(id);
      expect((await db.libraryDao.getItem(id))!.lastWatchedEpisode, 3);

      // Simulate an unwatch of the latest episode, then recompute.
      await (db.delete(
        db.watchEvents,
      )..where((t) => t.episodeNumber.equals(3))).go();
      await db.libraryDao.recomputeDenormalized(id);

      final item = (await db.libraryDao.getItem(id))!;
      expect(item.watchedCount, 2);
      expect(item.lastWatchedSeason, 1);
      expect(item.lastWatchedEpisode, 2);
    });

    test('a movie watch counts once and leaves lastWatched* null', () async {
      final id = await db.libraryDao.insertItem(aMovie());
      await insertWatch(id); // null season/episode

      await db.libraryDao.recomputeDenormalized(id);

      final item = (await db.libraryDao.getItem(id))!;
      expect(item.watchedCount, 1);
      expect(item.lastWatchedSeason, isNull);
      expect(item.lastWatchedEpisode, isNull);
    });

    test('an empty history resets progress to zero/null', () async {
      final id = await db.libraryDao.insertItem(aShow());
      await insertWatch(id, season: 1, episode: 1);
      await db.libraryDao.recomputeDenormalized(id);
      expect((await db.libraryDao.getItem(id))!.watchedCount, 1);

      await (db.delete(
        db.watchEvents,
      )..where((t) => t.libraryItemId.equals(id))).go();
      await db.libraryDao.recomputeDenormalized(id);

      final item = (await db.libraryDao.getItem(id))!;
      expect(item.watchedCount, 0);
      expect(item.lastWatchedSeason, isNull);
      expect(item.lastWatchedEpisode, isNull);
    });
  });

  group('watchLibrary (filtered grid stream)', () {
    test('narrows to the requested status and type', () async {
      await db.libraryDao.insertItem(aShow(title: 'Watching TV'));
      await db.libraryDao.insertItem(
        aShow(
          title: 'On watchlist',
          tmdbId: 111,
          status: TrackStatus.watchlist,
        ),
      );
      await db.libraryDao.insertItem(aMovie(title: 'Completed Movie'));

      expect(
        (await db.libraryDao.watchLibrary(status: TrackStatus.watching).first)
            .map((i) => i.title),
        ['Watching TV'],
      );
      expect(
        (await db.libraryDao.watchLibrary(type: MediaType.movie).first).map(
          (i) => i.title,
        ),
        ['Completed Movie'],
      );
      // No filter → everything.
      expect(await db.libraryDao.watchLibrary().first, hasLength(3));
    });

    test('repaints when a row is written', () async {
      final stream = db.libraryDao.watchLibrary(status: TrackStatus.watching);
      final emissions = <int>[];
      final sub = stream.listen((rows) => emissions.add(rows.length));

      await db.libraryDao.insertItem(aShow());
      await pumpEventQueue();

      expect(emissions.last, 1);
      await sub.cancel();
    });
  });

  group('findByIdentity + addOrGetItem (add-dedupe)', () {
    test('addOrGetItem inserts, then re-adding the title is a no-op', () async {
      final first = await db.libraryDao.addOrGetItem(aShow());
      final second = await db.libraryDao.addOrGetItem(
        aShow(title: 'Severance (re-add)'),
      );

      expect(second.id, first.id); // same row returned
      expect(await db.libraryDao.getAll(), hasLength(1)); // not duplicated
      // The original title wins — the existing row is returned untouched.
      expect(second.title, 'Severance');
    });

    test('findByIdentity matches by imdbId even when tmdbId differs', () async {
      await db.libraryDao.insertItem(
        aShow(tmdbId: 1, imdbId: 'tt1234'),
      );
      final hit = await db.libraryDao.findByIdentity(
        mediaType: MediaType.tv,
        tmdbId: 99, // wrong tmdb id
        imdbId: 'tt1234', // right imdb id
      );
      expect(hit, isNotNull);
    });

    test('same source id under a different mediaType is NOT a match', () async {
      await db.libraryDao.insertItem(aShow(tmdbId: 500));
      final hit = await db.libraryDao.findByIdentity(
        mediaType: MediaType.movie, // different type, same id
        tmdbId: 500,
      );
      expect(hit, isNull);
    });

    test('falls back to (mediaType, title, year) when no ids match', () async {
      await db.libraryDao.insertItem(
        aShow(title: 'Idless', tmdbId: null, year: 2020),
      );
      final hit = await db.libraryDao.findByIdentity(
        mediaType: MediaType.tv,
        title: 'Idless',
        year: 2020,
      );
      expect(hit?.title, 'Idless');
      // A different year is a different title.
      expect(
        await db.libraryDao.findByIdentity(
          mediaType: MediaType.tv,
          title: 'Idless',
          year: 1999,
        ),
        isNull,
      );
    });
  });

  group('status/rating/delete writes', () {
    test('updateStatus changes the status and stamps updatedAt', () async {
      final id = await db.libraryDao.insertItem(aShow());
      final later = DateTime(2026, 7, 8);
      await db.libraryDao.updateStatus(id, TrackStatus.completed, now: later);

      final item = (await db.libraryDao.getItem(id))!;
      expect(item.trackStatus, TrackStatus.completed);
      expect(item.updatedAt, later);
    });

    test('updateRating sets then clears rating + ratedAt', () async {
      final id = await db.libraryDao.insertItem(aShow());
      final rated = DateTime(2026, 7, 8);
      await db.libraryDao.updateRating(id, 8, now: rated);

      var item = (await db.libraryDao.getItem(id))!;
      expect(item.rating, 8);
      expect(item.ratedAt, rated);

      await db.libraryDao.updateRating(id, null, now: DateTime(2026, 7, 9));
      item = (await db.libraryDao.getItem(id))!;
      expect(item.rating, isNull);
      expect(item.ratedAt, isNull);
    });

    test('deleteItem removes the row and cascades its WatchEvents', () async {
      final id = await db.libraryDao.insertItem(aShow());
      await insertWatch(id, season: 1, episode: 1);

      await db.libraryDao.deleteItem(id);

      expect(await db.libraryDao.getItem(id), isNull);
      expect(await db.select(db.watchEvents).get(), isEmpty);
    });
  });

  group('schema & integrity (migration scaffold)', () {
    test('opens at schemaVersion 2 with the cache tables present', () async {
      expect(db.schemaVersion, 2);
      // Forces onCreate + beforeOpen to run, then verifies the file is sound.
      final result = await db.customSelect('PRAGMA integrity_check').get();
      expect(result.single.data.values.first, 'ok');
      // v2 (#13) added the disposable cache tables; a fresh open builds them
      // (createAll). Querying each proves the table exists (a missing table
      // would throw) and starts empty.
      expect(
        await db.mediaCacheDao.getMedia(
          MetadataSourceKind.tmdb,
          MediaType.tv,
          1,
        ),
        isNull,
      );
      expect(
        await db.mediaCacheDao.getEpisodes(MetadataSourceKind.tmdb, 1, 1),
        isEmpty,
      );
    });

    test(
      'beforeOpen enables foreign_keys (not just declares the pragma)',
      () async {
        // Any query opens the connection and runs beforeOpen.
        final rows = await db.customSelect('PRAGMA foreign_keys').get();
        expect(rows.single.data.values.first, 1);
      },
    );
  });

  group('foreign-key enforcement (invariant regression guard)', () {
    test(
      'a WatchEvent referencing a missing LibraryItem is rejected',
      () async {
        // Proves foreign_keys = ON is actually active, not merely set in
        // beforeOpen — a dangling FK must throw, not silently insert.
        expect(
          () => db
              .into(db.watchEvents)
              .insert(WatchEventsCompanion.insert(libraryItemId: 999999)),
          throwsA(isA<SqliteException>()),
        );
      },
    );

    test('deleting a LibraryItem cascades to its WatchEvents', () async {
      final id = await db.libraryDao.insertItem(aShow());
      await db
          .into(db.watchEvents)
          .insert(
            WatchEventsCompanion.insert(
              libraryItemId: id,
              seasonNumber: const Value(1),
              episodeNumber: const Value(1),
            ),
          );
      expect(await db.select(db.watchEvents).get(), hasLength(1));

      await (db.delete(db.libraryItems)..where((t) => t.id.equals(id))).go();

      expect(await db.select(db.watchEvents).get(), isEmpty);
    });

    test('the (mediaType, tmdbId) unique index rejects a duplicate', () async {
      await db.libraryDao.insertItem(aShow());
      expect(
        () => db.libraryDao.insertItem(aShow(title: 'Severance (dupe)')),
        throwsA(isA<SqliteException>()),
      );
      // But two rows with a NULL tmdbId are allowed (NULLs are distinct).
      await db.libraryDao.insertItem(aShow(title: 'Manual A', tmdbId: null));
      await db.libraryDao.insertItem(aShow(title: 'Manual B', tmdbId: null));
      expect(await db.libraryDao.getAll(), hasLength(3));
    });
  });
}
