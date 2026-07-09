import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';

/// #34 acceptance — **the figures survive a cache eviction.**
///
/// This is the adversarial test for AD-M5-3 and the "two data domains"
/// invariant (CLAUDE.md): stats read facts snapshotted onto the *user-owned*
/// tables, never the disposable cache. The day someone "optimizes"
/// `watchAllEvents()` by joining `CachedMedia` for a nicer runtime or a richer
/// genre list, this test goes red — because a TTL eviction, an offline boot or
/// a fresh restore would then blank the user's stats.
void main() {
  late AppDatabase db;
  late LibraryDao dao;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = LibraryDao(db);
  });
  tearDown(() => db.close());

  final now = DateTime(2026, 7, 9, 12);

  Future<StatsSnapshot> snapshot() async =>
      statsFrom(await dao.watchAllEvents().first, now);

  test('wiping both cache tables leaves every figure identical', () async {
    // A show and a film, both fully snapshotted at add-time.
    final show = await dao.addOrGetItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Severance',
        trackStatus: TrackStatus.watching,
        addedAt: now,
        updatedAt: now,
        tmdbId: const Value(95396),
        year: const Value(2022),
        genresCsv: const Value('Drama,Sci-Fi'),
        runtimeMinutes: const Value(45),
      ),
    );
    final film = await dao.addOrGetItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.movie,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Dune',
        trackStatus: TrackStatus.completed,
        addedAt: now,
        updatedAt: now,
        tmdbId: const Value(438631),
        year: const Value(2021),
        genresCsv: const Value('Sci-Fi'),
        runtimeMinutes: const Value(155),
      ),
    );

    await dao.markWatched(
      show.id,
      season: 1,
      episode: 1,
      watchedAt: now,
      runtimeMinutes: 45,
    );
    await dao.markWatched(
      show.id,
      season: 1,
      episode: 2,
      watchedAt: DateTime(2026, 7, 8, 12),
      runtimeMinutes: 47,
    );
    await dao.logRewatch(
      show.id,
      season: 1,
      episode: 1,
      watchedAt: now,
      runtimeMinutes: 45,
    );
    await dao.markWatched(film.id, watchedAt: now, runtimeMinutes: 155);

    // The cache is populated, as it would be after browsing these titles.
    await db
        .into(db.cachedMedia)
        .insert(
          CachedMediaCompanion.insert(
            source: MetadataSourceKind.tmdb,
            mediaType: MediaType.tv,
            sourceId: 95396,
            payload: '{}',
            fetchedAt: now,
            title: 'Severance',
            year: const Value(2022),
            genresCsv: const Value('Drama,Sci-Fi'),
            runtimeMinutes: const Value(45),
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
            fetchedAt: now,
            runtimeMinutes: const Value(45),
          ),
        );

    final before = await snapshot();

    // Sanity: the snapshot is non-trivial, so "identical" below means
    // something.
    expect(before.episodesWatched, 2);
    expect(before.moviesWatched, 1);
    expect(before.rewatches, 1);
    expect(before.timeWatched, const Duration(minutes: 45 + 47 + 45 + 155));
    expect(before.streakDays, 2);
    expect(before.byGenre, const [
      StatBucket('Sci-Fi', 4), // 3 Severance events + Dune
      StatBucket('Drama', 3),
    ]);
    expect(before.byDecade, const [StatBucket('2020s', 4)]);
    expect(before.hasMissingData, isFalse);

    // Evict the whole disposable domain — a TTL sweep, or a restore that only
    // brings back the user tables.
    await db.delete(db.cachedMedia).go();
    await db.delete(db.cachedEpisodes).go();
    expect(await db.select(db.cachedMedia).get(), isEmpty);
    expect(await db.select(db.cachedEpisodes).get(), isEmpty);

    expect(await snapshot(), before);
  });
}
