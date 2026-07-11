import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/library/data/tracked_show_sync.dart';

/// The tracked-show sync backfills the per-show metadata an import can't fetch
/// (episode count, show status, poster) onto the library rows — the data the
/// derived "Up to date" category and the progress labels depend on. It must be
/// fault-tolerant: one offline show can't sink the whole pass.
class _FakeRepo implements CachingMetadataRepository {
  _FakeRepo(this.byId);

  final Map<int, MediaDetails> byId;
  int calls = 0;

  @override
  Stream<MediaDetails> showDetails(int sourceId) {
    calls++;
    final d = byId[sourceId];
    return d == null ? Stream.error(StateError('offline')) : Stream.value(d);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A source that always returns [fresh], counting fetches — to prove the
/// refresh path actually revalidates a stale cache rather than serving it.
class _FakeSource implements MetadataSource {
  _FakeSource(this.fresh);

  final MediaDetails fresh;
  int calls = 0;

  @override
  Future<MediaDetails> showDetails(int sourceId) async {
    calls++;
    return fresh;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  MediaDetails details({
    int? total,
    String? status,
    int? runtime,
    List<String> genres = const [],
  }) => MediaDetails(
    kind: MediaKind.tv,
    title: 'Show',
    genres: genres,
    seasons: const [],
    episodeCountTotal: total,
    showStatus: status,
    runtimeMinutes: runtime,
    posterPath: '/p.jpg',
  );

  Future<int> seedShow({
    int tmdbId = 100,
    MediaType type = MediaType.tv,
    TrackStatus status = TrackStatus.watching,
  }) => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: type,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Show $tmdbId',
      trackStatus: status,
      addedAt: DateTime(2026),
      updatedAt: DateTime(2026),
      tmdbId: Value(tmdbId),
    ),
  );

  TrackedShowSync syncWith(_FakeRepo repo) => TrackedShowSync(
    dao: db.libraryDao,
    repo: repo,
    backend: MetadataSourceKind.tmdb,
  );

  test('writes episode count, status and poster onto tracked shows', () async {
    await seedShow();
    await syncWith(
      _FakeRepo({100: details(total: 19, status: 'Returning Series')}),
    ).refresh();

    final item = (await db.libraryDao.getAll()).single;
    expect(item.episodeCountTotal, 19);
    expect(item.showStatus, 'Returning Series');
    expect(item.posterPath, '/p.jpg');
  });

  test('backfills per-episode runtime and genres onto the item', () async {
    // Imports carry neither runtime nor genres, so stats read 0h with no genre
    // breakdown until the refresh enriches the item. The `item.runtimeMinutes`
    // fallback then estimates hours, and `genresCsv` feeds the genre breakdown.
    await seedShow();
    await syncWith(
      _FakeRepo({
        100: details(total: 10, runtime: 42, genres: ['Drama', 'Sci-Fi']),
      }),
    ).refresh();

    final item = (await db.libraryDao.getAll()).single;
    expect(item.runtimeMinutes, 42);
    expect(item.genresCsv, 'Drama,Sci-Fi');
  });

  test('a detail with no runtime leaves an existing runtime intact', () async {
    // Absent, not null: a partial detail must not clobber a known runtime.
    final id = await seedShow();
    await db.libraryDao.updateManyItems([
      (id, const LibraryItemsCompanion(runtimeMinutes: Value(50))),
    ]);

    await syncWith(_FakeRepo({100: details(total: 10)})).refresh();

    expect((await db.libraryDao.getAll()).single.runtimeMinutes, 50);
  });

  test('an offline/unknown show is skipped, not fatal to the pass', () async {
    await seedShow(); // tmdbId 100, resolvable
    await seedShow(tmdbId: 999); // errors

    await syncWith(_FakeRepo({100: details(total: 10)})).refresh();

    final items = await db.libraryDao.getAll();
    expect(items.firstWhere((i) => i.tmdbId == 100).episodeCountTotal, 10);
    expect(items.firstWhere((i) => i.tmdbId == 999).episodeCountTotal, isNull);
  });

  test('never touches movies or dropped shows', () async {
    await seedShow(tmdbId: 5, type: MediaType.movie);
    await seedShow(tmdbId: 6, status: TrackStatus.dropped);
    final repo = _FakeRepo({5: details(total: 1), 6: details(total: 1)});

    await syncWith(repo).refresh();

    expect(repo.calls, 0);
  });

  test('a stale cache is revalidated, not served back (uses .last)', () async {
    // The bug this guards: `.first` on the SWR stream takes the cached value
    // and cancels before the refetch runs, so the daily/manual refresh silently
    // writes the stale count back. This drives a *real* repository over a stale
    // cache and asserts the fresh value lands.
    await seedShow(); // tmdbId 100, watching TV
    await db.mediaCacheDao.upsertMedia(
      CachedMediaCompanion.insert(
        source: MetadataSourceKind.tmdb,
        mediaType: MediaType.tv,
        sourceId: 100,
        payload: jsonEncode(
          details(total: 10, status: 'Returning Series').toJson(),
        ),
        // Fetched 9 days ago — well past the 12h airing TTL, so stale.
        fetchedAt: DateTime(2026, 7),
        title: 'Show',
        showStatus: const Value('Returning Series'),
      ),
    );
    final source = _FakeSource(details(total: 19, status: 'Returning Series'));
    final repo = CachingMetadataRepository(
      source: source,
      sourceKind: MetadataSourceKind.tmdb,
      dao: db.mediaCacheDao,
      clock: Clock.fixed(DateTime(2026, 7, 10, 12)),
    );

    await TrackedShowSync(
      dao: db.libraryDao,
      repo: repo,
      backend: MetadataSourceKind.tmdb,
    ).refresh();

    expect(source.calls, 1, reason: 'a stale cache must be revalidated');
    final item = (await db.libraryDao.getAll()).single;
    expect(
      item.episodeCountTotal,
      19,
      reason: 'the refresh must write the fresh count, not the stale cache',
    );
  });

  group('shouldDailySync (launch throttle)', () {
    final now = DateTime(2026, 7, 10, 12);

    test('due when never synced', () {
      expect(shouldDailySync(now, null), isTrue);
    });

    test('due exactly a day later (the boundary runs)', () {
      expect(
        shouldDailySync(now, now.subtract(const Duration(days: 1))),
        isTrue,
      );
    });

    test('not due within the day', () {
      expect(
        shouldDailySync(now, now.subtract(const Duration(hours: 23))),
        isFalse,
      );
    });
  });
}
