import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/library/unverified_position.dart';

import '../../support/library_fixtures.dart' as seed;

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
    DateTime? at,
    int? year,
    TrackStatus status = TrackStatus.watching,
  }) => LibraryItemsCompanion.insert(
    mediaType: MediaType.tv,
    recordedSource: MetadataSourceKind.tmdb,
    title: title,
    trackStatus: status,
    addedAt: at ?? now,
    updatedAt: at ?? now,
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

  /// Membership goes through the production write, so a DAO test cannot seed a
  /// row the app itself could not add.
  Future<int> add(LibraryItemsCompanion entry) async =>
      (await db.libraryDao.addOrGetItem(entry)).item.id;

  /// Raw insert, bypassing the dedupe cascade. Only for tests whose SUBJECT is
  /// that bypass — the unique-index constraint below — or which must fabricate
  /// damaged rows for the repair to fix.
  Future<int> addRaw(LibraryItemsCompanion entry) =>
      seed.seedRawItem(db, entry);

  /// Writes a watch row raw, skipping the idempotent marker semantics and the
  /// recompute that follows them. That is the point: the group below exists to
  /// point `recomputeDenormalized` at rows the marker path would never leave
  /// behind, and you cannot test a repair without damage.
  Future<void> insertWatch(
    int itemId, {
    int? season,
    int? episode,
    bool rewatch = false,
  }) => seed.seedRawWatch(
    db,
    itemId,
    season: season,
    episode: episode,
    isRewatch: rewatch,
  );

  group('LibraryDao round-trip', () {
    test('insert → getAll reads the row back with defaults applied', () async {
      final id = await add(aShow());

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
      await add(aShow());
      final items = await db.libraryDao.watchAll().first;
      expect(items.map((i) => i.title), ['Severance']);
    });

    test('getItem returns the row, or null for an unknown id', () async {
      final id = await add(aShow());
      expect((await db.libraryDao.getItem(id))?.title, 'Severance');
      expect(await db.libraryDao.getItem(999999), isNull);
    });
  });

  group('restore (the replace protocol, AD-4)', () {
    RestoreItem entry(
      LibraryItemsCompanion item, {
      List<(int, int)> watched = const [],
    }) => (
      item: item,
      watches: [
        for (final (season, episode) in watched)
          (
            season: season,
            episode: episode,
            watchedAt: now,
            runtimeMinutes: null,
            isRewatch: false,
          ),
      ],
    );

    test('rebuilds the derived columns it was never handed', () async {
      final written = await db.libraryDao.restore([
        entry(aShow(), watched: const [(1, 1), (1, 2)]),
        entry(aMovie()),
      ]);

      expect((written.items, written.watchEvents), (2, 2));
      final show = (await db.libraryDao.getAll()).firstWhere(
        (i) => i.title == 'Severance',
      );
      expect(
        (show.watchedCount, show.lastWatchedSeason, show.lastWatchedEpisode),
        (2, 1, 2),
        reason:
            'the backup carries watch events, not progress columns — the '
            'restore has to derive them or every restored row reads 0 watched '
            'over a full history',
      );
    });

    test('replaces: what was there before is gone', () async {
      await add(aShow(title: 'Before'));

      await db.libraryDao.restore([entry(aShow(title: 'After'))]);

      expect(
        (await db.libraryDao.getAll()).map((i) => i.title),
        ['After'],
        reason: 'a restore replaces; only an import merges',
      );
    });

    test('a failure part-way leaves the original library untouched', () async {
      // Two rows sharing an imdbId violate the unique index — but only on the
      // SECOND insert, after the wipe and the first insert have already
      // happened. Without one transaction around the whole protocol the user
      // would be left with a half-restored library and their original gone:
      // the worst outcome the restore path has, and silent.
      await add(aShow(title: 'Keep', imdbId: 'tt0000001'));

      await expectLater(
        db.libraryDao.restore([
          entry(aShow(title: 'New A', tmdbId: 1, imdbId: 'tt9999999')),
          entry(aShow(title: 'New B', tmdbId: 2, imdbId: 'tt9999999')),
        ]),
        throwsA(anything),
      );

      expect((await db.libraryDao.getAll()).map((i) => i.title), ['Keep']);
    });
  });

  group('recomputeDenormalized (AD-4 — the join-free progress primitive)', () {
    test(
      'watchedCount counts non-rewatch rows only; a rewatch never inflates it '
      'nor moves lastWatched forward',
      () async {
        final id = await add(aShow());
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
        final id = await add(aShow());
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
      final id = await add(aShow());
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
      final id = await add(aMovie());
      await insertWatch(id); // null season/episode

      await db.libraryDao.recomputeDenormalized(id);

      final item = (await db.libraryDao.getItem(id))!;
      expect(item.watchedCount, 1);
      expect(item.lastWatchedSeason, isNull);
      expect(item.lastWatchedEpisode, isNull);
    });

    test('an empty history resets progress to zero/null', () async {
      final id = await add(aShow());
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

  group('watch writes (#19 — the idempotent-toggle invariant)', () {
    Future<List<WatchEvent>> events(int itemId) =>
        db.libraryDao.watchEventsFor(itemId);

    test(
      'markWatched is idempotent — a double-tap adds no second row',
      () async {
        final id = await add(aShow());
        await db.libraryDao.markWatched(id, season: 1, episode: 1);
        await db.libraryDao.markWatched(id, season: 1, episode: 1);

        expect(await events(id), hasLength(1));
        final item = (await db.libraryDao.getItem(id))!;
        expect(item.watchedCount, 1);
        expect(item.lastWatchedSeason, 1);
        expect(item.lastWatchedEpisode, 1);
      },
    );

    test(
      'markWatched snapshots watchedAt + runtimeMinutes onto the row',
      () async {
        final id = await add(aShow());
        final at = DateTime(2026, 7, 9, 21, 30);
        await db.libraryDao.markWatched(
          id,
          season: 1,
          episode: 1,
          watchedAt: at,
          runtimeMinutes: 47,
        );

        final row = (await events(id)).single;
        expect(row.watchedAt, at);
        // Stats read this snapshot, never the disposable cache.
        expect(row.runtimeMinutes, 47);
        expect(row.isRewatch, isFalse);
      },
    );

    test(
      'logRewatch appends without raising watchedCount or advancing progress',
      () async {
        final id = await add(aShow());
        await db.libraryDao.markWatched(id, season: 1, episode: 1);
        // A rewatch of a LATER episode: a naive "any row advances progress"
        // implementation would jump lastWatched* to S1E9 and count 2.
        await db.libraryDao.logRewatch(id, season: 1, episode: 9);

        expect(await events(id), hasLength(2));
        final item = (await db.libraryDao.getItem(id))!;
        expect(item.watchedCount, 1);
        expect(item.lastWatchedSeason, 1);
        expect(item.lastWatchedEpisode, 1);
      },
    );

    test(
      'logRewatch keeps the first watch date — it never rewrites it',
      () async {
        final id = await add(aShow());
        final first = DateTime(2020);
        await db.libraryDao.markWatched(
          id,
          season: 1,
          episode: 1,
          watchedAt: first,
        );
        await db.libraryDao.logRewatch(
          id,
          season: 1,
          episode: 1,
          watchedAt: DateTime(2026),
        );

        final rows = await events(id);
        expect(rows.where((e) => !e.isRewatch).single.watchedAt, first);
        expect(rows.where((e) => e.isRewatch).single.watchedAt, DateTime(2026));
      },
    );

    test(
      'unwatch removes the rewatch rows too, not just the first watch',
      () async {
        final id = await add(aShow());
        await db.libraryDao.markWatched(id, season: 1, episode: 1);
        await db.libraryDao.logRewatch(id, season: 1, episode: 1);
        await db.libraryDao.logRewatch(id, season: 1, episode: 1);
        expect(await events(id), hasLength(3));

        await db.libraryDao.unwatch(id, season: 1, episode: 1);

        // No orphan rewatches of an episode the user says they never watched.
        expect(await events(id), isEmpty);
        final item = (await db.libraryDao.getItem(id))!;
        expect(item.watchedCount, 0);
        expect(item.lastWatchedSeason, isNull);
        expect(item.lastWatchedEpisode, isNull);
      },
    );

    test('unwatch touches only its own episode; progress falls back', () async {
      final id = await add(aShow());
      await db.libraryDao.markWatched(id, season: 1, episode: 1);
      await db.libraryDao.markWatched(id, season: 1, episode: 2);
      await db.libraryDao.markWatched(id, season: 2, episode: 1);

      await db.libraryDao.unwatch(id, season: 2, episode: 1);

      expect(await events(id), hasLength(2));
      final item = (await db.libraryDao.getItem(id))!;
      expect(item.watchedCount, 2);
      expect(item.lastWatchedSeason, 1);
      expect(item.lastWatchedEpisode, 2);
    });

    test('an episode number is scoped to its season — S1E1 ≠ S2E1', () async {
      final id = await add(aShow());
      await db.libraryDao.markWatched(id, season: 1, episode: 1);
      // Same episode number, different season: a second, distinct marker.
      await db.libraryDao.markWatched(id, season: 2, episode: 1);
      expect(await events(id), hasLength(2));

      await db.libraryDao.unwatch(id, season: 1, episode: 1);
      final left = (await events(id)).single;
      expect(left.seasonNumber, 2);
    });

    test(
      'a movie marks/unwatches on null coordinates (IS NULL, not = NULL)',
      () async {
        final id = await add(aMovie());
        await db.libraryDao.markWatched(id, runtimeMinutes: 155);
        // `= NULL` matches nothing in SQLite, so a broken predicate inserts
        // a second row here instead of no-opping.
        await db.libraryDao.markWatched(id, runtimeMinutes: 155);

        expect(await events(id), hasLength(1));
        var item = (await db.libraryDao.getItem(id))!;
        expect(item.watchedCount, 1);
        expect(item.lastWatchedSeason, isNull);

        await db.libraryDao.unwatch(id); // ...and would delete nothing here.
        expect(await events(id), isEmpty);
        item = (await db.libraryDao.getItem(id))!;
        expect(item.watchedCount, 0);
      },
    );

    test(
      'writes are scoped to their item — a sibling show is untouched',
      () async {
        final a = await add(aShow());
        final b = await add(
          aShow(title: 'Other', tmdbId: 777),
        );
        await db.libraryDao.markWatched(a, season: 1, episode: 1);

        // The same coordinate on another item is a distinct marker...
        await db.libraryDao.markWatched(b, season: 1, episode: 1);
        expect(await events(a), hasLength(1));
        expect(await events(b), hasLength(1));

        // ...and unwatching one must not delete the other's row.
        await db.libraryDao.unwatch(a, season: 1, episode: 1);
        expect(await events(a), isEmpty);
        expect(await events(b), hasLength(1));
        expect((await db.libraryDao.getItem(b))!.watchedCount, 1);
      },
    );

    test(
      'watchWatchedEpisodes emits watched coords, excluding rewatches',
      () async {
        final id = await add(aShow());
        await db.libraryDao.markWatched(id, season: 1, episode: 1);
        await db.libraryDao.logRewatch(id, season: 1, episode: 1);
        // A rewatch of an episode never marked watched must not appear watched.
        await db.libraryDao.logRewatch(id, season: 4, episode: 2);

        expect(await db.libraryDao.watchWatchedEpisodes(id).first, {(1, 1)});
      },
    );

    test('watchWatchedEpisodes omits a movie null coordinate', () async {
      final id = await add(aMovie());
      await db.libraryDao.markWatched(id);
      expect(await db.libraryDao.watchWatchedEpisodes(id).first, isEmpty);
    });
  });

  // The first and only way this flag has ever been cleared by a person. Its
  // whole promise is that the user's history was never modified, so the write
  // that clears it must not be the one that starts modifying it.
  group('dismissUnverifiedPosition', () {
    test('clears the flag for the named row only', () async {
      final target = await seed.seedShow(
        db,
        title: 'Checked',
        tmdbId: 1,
        relinkFailed: true,
        watched: const [(1, 1)],
      );
      final sibling = await seed.seedShow(
        db,
        title: 'Still Unverified',
        tmdbId: 2,
        relinkFailed: true,
        watched: const [(1, 1)],
      );

      await db.libraryDao.dismissUnverifiedPosition(target.id);

      expect((await db.libraryDao.getItem(target.id))!.relinkFailed, isFalse);
      expect(
        (await db.libraryDao.getItem(sibling.id))!.relinkFailed,
        isTrue,
        reason: 'a human looked at one title, not at every title',
      );
    });

    test('changes nothing else about the row', () async {
      final item = await seed.seedShow(
        db,
        tvdbId: 371980,
        imdbId: 'tt11280740',
        relinkFailed: true,
        watched: const [(1, 1), (1, 2)],
      );
      final eventsBefore = await db.libraryDao.watchEventsFor(item.id);

      await db.libraryDao.dismissUnverifiedPosition(item.id);

      final after = (await db.libraryDao.getItem(item.id))!;
      expect(after, item.copyWith(relinkFailed: false));
      expect(
        await db.libraryDao.watchEventsFor(item.id),
        eventsBefore,
        reason: 'the switch never touched watch history, and neither does this',
      );
      expect(
        after.updatedAt,
        item.updatedAt,
        reason:
            'acknowledging a question is not watching something — stamping '
            'would jump the title up the grid recency order for a no-op',
      );
    });

    test('afterwards the row is indistinguishable from a healthy one', () {
      // Every surface reads the same predicate, so this is the whole of what
      // "the marker is gone from the grid and from Up Next" means.
      final dismissed = LibraryItem(
        id: 1,
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Severance',
        trackStatus: TrackStatus.watching,
        lastWatchedSeason: 2,
        lastWatchedEpisode: 4,
        watchedCount: 7,
        addedAt: now,
        updatedAt: now,
        relinkFailed: false,
      );
      expect(hasUnverifiedPosition(dismissed), isFalse);
      expect(
        hasUnverifiedPosition(dismissed.copyWith(relinkFailed: true)),
        isTrue,
        reason: 'sanity: the flag is what the predicate turns on',
      );
    });
  });

  group('watchLibrary (filtered grid stream)', () {
    test('narrows to the requested status and type', () async {
      await add(aShow(title: 'Watching TV'));
      await add(
        aShow(
          title: 'On watchlist',
          tmdbId: 111,
          status: TrackStatus.watchlist,
        ),
      );
      await add(aMovie(title: 'Completed Movie'));

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

      await add(aShow());
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

      expect(second.item.id, first.item.id); // same row returned
      expect(await db.libraryDao.getAll(), hasLength(1)); // not duplicated
      // The original title wins — the existing row is returned untouched.
      expect(second.item.title, 'Severance');

      // And it reports which it did. This is the ONLY place that can answer
      // that atomically (the check is inside the insert's transaction), so a
      // caller must never re-run the cascade to find out — the UI's "Added X to
      // Watching" hangs off this flag, and a wrong one lies to the user.
      expect(first.created, isTrue);
      expect(second.created, isFalse);
    });

    test('findByIdentity matches by imdbId even when tmdbId differs', () async {
      await add(
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
      await add(aShow(tmdbId: 500));
      final hit = await db.libraryDao.findByIdentity(
        mediaType: MediaType.movie, // different type, same id
        tmdbId: 500,
      );
      expect(hit, isNull);
    });

    test('falls back to (mediaType, title, year) when no ids match', () async {
      await add(
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
      final id = await add(aShow());
      final later = DateTime(2026, 7, 8);
      await db.libraryDao.updateStatus(id, TrackStatus.completed, now: later);

      final item = (await db.libraryDao.getItem(id))!;
      expect(item.trackStatus, TrackStatus.completed);
      expect(item.updatedAt, later);
    });

    test('updateRating sets then clears rating + ratedAt', () async {
      final id = await add(aShow());
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
      final id = await add(aShow());
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
      final id = await add(aShow());
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
      // Raw on purpose: addOrGetItem would dedupe rather than let the index
      // fire, and the index is the subject here.
      await addRaw(aShow());
      expect(
        () => addRaw(aShow(title: 'Severance (dupe)')),
        throwsA(isA<SqliteException>()),
      );
      // But two rows with a NULL tmdbId are allowed (NULLs are distinct).
      await addRaw(aShow(title: 'Manual A', tmdbId: null));
      await addRaw(aShow(title: 'Manual B', tmdbId: null));
      expect(await db.libraryDao.getAll(), hasLength(3));
    });
  });

  group('markManyWatched (#20 — bulk is a batch of idempotent marks)', () {
    Future<List<WatchEvent>> events(int itemId) =>
        db.libraryDao.watchEventsFor(itemId);

    EpisodeMark ep(int s, int e, [int? runtime]) =>
        (season: s, episode: e, runtimeMinutes: runtime);

    test(
      're-running a bulk mark inserts nothing — no inflated count',
      () async {
        final id = await add(aShow());
        final marks = [ep(1, 1), ep(1, 2), ep(1, 3)];

        expect(await db.libraryDao.markManyWatched(id, marks), 3);
        expect(await db.libraryDao.markManyWatched(id, marks), 0);

        expect(await events(id), hasLength(3));
        final item = (await db.libraryDao.getItem(id))!;
        expect(item.watchedCount, 3);
        expect(item.lastWatchedSeason, 1);
        expect(item.lastWatchedEpisode, 3);
      },
    );

    test(
      'a duplicate coordinate within one call collapses to one row',
      () async {
        final id = await add(aShow());
        expect(
          await db.libraryDao.markManyWatched(id, [ep(1, 1), ep(1, 1)]),
          1,
        );
        expect(await events(id), hasLength(1));
        expect((await db.libraryDao.getItem(id))!.watchedCount, 1);
      },
    );

    test('bulk over a partly-watched season fills only the gaps', () async {
      final id = await add(aShow());
      await db.libraryDao.markWatched(
        id,
        season: 1,
        episode: 2,
        watchedAt: DateTime(2020),
      );

      expect(
        await db.libraryDao.markManyWatched(id, [
          ep(1, 1),
          ep(1, 2),
          ep(1, 3),
        ], watchedAt: now),
        2,
      );

      final rows = await events(id);
      expect(rows, hasLength(3));
      // The pre-existing marker keeps its own (earlier) watch date.
      final e2 = rows.singleWhere((r) => r.episodeNumber == 2);
      expect(e2.watchedAt, DateTime(2020));
      expect((await db.libraryDao.getItem(id))!.watchedCount, 3);
    });

    test('a rewatch marker does not stand in for a watched marker', () async {
      final id = await add(aShow());
      // A rewatch of an episode with no first-watch row: bulk must still insert
      // the real marker, or `watchedCount` stays 0 forever.
      await db.libraryDao.logRewatch(id, season: 1, episode: 1);

      expect(await db.libraryDao.markManyWatched(id, [ep(1, 1)]), 1);
      expect((await db.libraryDao.getItem(id))!.watchedCount, 1);
    });

    test(
      'runtime is snapshotted per episode, and an empty bulk no-ops',
      () async {
        final id = await add(aShow());
        expect(await db.libraryDao.markManyWatched(id, const []), 0);
        expect(await events(id), isEmpty);

        await db.libraryDao.markManyWatched(id, [ep(1, 1, 57), ep(1, 2)]);
        final rows = await events(id);
        expect(
          rows.singleWhere((r) => r.episodeNumber == 1).runtimeMinutes,
          57,
        );
        expect(
          rows.singleWhere((r) => r.episodeNumber == 2).runtimeMinutes,
          isNull,
        );
      },
    );

    test(
      'writes are scoped to their item — a sibling show is untouched',
      () async {
        final a = await add(aShow());
        final b = await add(
          aShow(title: 'Other', tmdbId: 777),
        );
        await db.libraryDao.markWatched(b, season: 1, episode: 1);

        await db.libraryDao.markManyWatched(a, [ep(1, 1), ep(1, 2)]);

        expect(await events(b), hasLength(1));
        expect((await db.libraryDao.getItem(b))!.watchedCount, 1);
        expect((await db.libraryDao.getItem(a))!.watchedCount, 2);
      },
    );
  });

  // `watchLibrary` documents "most-recently-updated first so freshly-touched
  // titles surface at the top". Only the status and rating writes used to stamp
  // `updatedAt`, so the app's commonest write — marking an episode — left the
  // title exactly where it was, and nothing in the suite noticed.
  group('watchLibrary recency ordering', () {
    late int stale;

    setUp(() async {
      stale = await add(aShow(title: 'Stale', tmdbId: 1, at: DateTime(2026)));
      await add(aShow(title: 'Fresh', tmdbId: 2, at: DateTime(2026, 6)));
    });

    Future<List<String>> titles() async =>
        (await db.libraryDao.watchLibrary().first).map((i) => i.title).toList();

    Future<void> at(DateTime when, Future<void> Function() write) =>
        withClock(Clock.fixed(when), write);

    test('starts most-recently-updated first', () async {
      expect(await titles(), ['Fresh', 'Stale']);
    });

    test('marking an episode lifts its title to the top', () async {
      await at(
        DateTime(2026, 12),
        () => db.libraryDao.markWatched(stale, season: 1, episode: 1),
      );

      expect(await titles(), ['Stale', 'Fresh']);
    });

    test('bulk-marking lifts its title to the top', () async {
      await at(
        DateTime(2026, 12),
        () async => db.libraryDao.markManyWatched(stale, [
          (season: 1, episode: 1, runtimeMinutes: null),
        ]),
      );

      expect(await titles(), ['Stale', 'Fresh']);
    });

    test('logging a rewatch lifts its title to the top', () async {
      await at(
        DateTime(2026, 12),
        () => db.libraryDao.logRewatch(stale, season: 1, episode: 1),
      );

      expect(await titles(), ['Stale', 'Fresh']);
    });

    test('un-marking lifts its title to the top', () async {
      // The setup mark is pinned BEFORE Fresh: left on the ambient clock it
      // would stamp today, putting Stale on top before `unwatch` ran at all —
      // and the assertion would pass with `unwatch`'s stamp deleted. Verified
      // by deleting it and watching this go red.
      await at(
        DateTime(2026, 2),
        () => db.libraryDao.markWatched(stale, season: 1, episode: 1),
      );
      expect(await titles(), ['Fresh', 'Stale']);

      await at(
        DateTime(2026, 12),
        () => db.libraryDao.unwatch(stale, season: 1, episode: 1),
      );

      expect(await titles(), ['Stale', 'Fresh']);
    });
  });
}
