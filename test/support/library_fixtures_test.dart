import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

import 'library_fixtures.dart';

/// The fixtures are only worth having if they really do go through the
/// production write path — a helper that quietly set `watchedCount` itself
/// would reintroduce exactly the "tests assert states the app can't produce"
/// hole it exists to close. These pin that.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test(
    'seedShow derives progress columns rather than accepting them',
    () async {
      final show = await seedShow(db, watched: const [(1, 1), (1, 2), (1, 3)]);

      expect(show.watchedCount, 3);
      expect(show.lastWatchedSeason, 1);
      expect(show.lastWatchedEpisode, 3);
    },
  );

  test('seedShow leaves an unwatched show at zero progress', () async {
    final show = await seedShow(db);

    expect(show.watchedCount, 0);
    expect(show.lastWatchedSeason, isNull);
    expect(show.lastWatchedEpisode, isNull);
  });

  test('seedShow dedupes like the app: same title twice is one row', () async {
    await seedShow(db);
    await seedShow(db);

    expect(await db.libraryDao.getAll(), hasLength(1));
  });

  test(
    'seedShow marks idempotently — a repeated coordinate is one row',
    () async {
      final show = await seedShow(db, watched: const [(1, 1), (1, 1)]);

      expect(show.watchedCount, 1);
    },
  );

  test('seedMovie watched:true marks the (null, null) coordinate', () async {
    final movie = await seedMovie(db, watched: true, runtimeMinutes: 155);
    final events = await db.libraryDao.watchEventsFor(movie.id);

    expect(movie.watchedCount, 1);
    expect(events.single.seasonNumber, isNull);
    expect(events.single.episodeNumber, isNull);
    expect(
      events.single.runtimeMinutes,
      155,
      reason: 'a movie snapshots its own runtime, as the detail screen does',
    );
  });

  test(
    'seedShow does not invent an episode runtime from the show average',
    () async {
      final show = await seedShow(
        db,
        runtimeMinutes: 50,
        watched: const [(1, 1)],
      );
      final events = await db.libraryDao.watchEventsFor(show.id);

      expect(
        events.single.runtimeMinutes,
        isNull,
        reason:
            'the show average is not the episode runtime; stats must not '
            'read a fabricated snapshot as though it were measured',
      );
    },
  );

  test(
    'seedRawItem can fabricate the broken state the repair tests need',
    () async {
      final id = await seedRawItem(
        db,
        LibraryItemsCompanion.insert(
          mediaType: MediaType.tv,
          recordedSource: MetadataSourceKind.tmdb,
          title: 'Broken',
          trackStatus: TrackStatus.watching,
          addedAt: fixtureNow,
          updatedAt: fixtureNow,
          watchedCount: const Value(99),
        ),
      );

      expect((await db.libraryDao.getItem(id))!.watchedCount, 99);

      await db.libraryDao.recomputeDenormalized(id);

      expect((await db.libraryDao.getItem(id))!.watchedCount, 0);
    },
  );
}
