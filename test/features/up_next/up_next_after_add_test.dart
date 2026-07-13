import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/detail/data/add_to_library.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';

/// Adding a show must put it in the Up Next queue **immediately** — no manual
/// refresh, no waiting for the once-a-day `TrackedShowSync`.
///
/// The bug this pins: `watchQueue` builds the queue from `cachedShowDetails`,
/// which is **cache-only** — it never hits the network. `addToLibrary` used to
/// fetch its snapshot straight from the `MetadataSource`, bypassing the SWR
/// cache entirely, so a freshly added show had *no* row in `CachedMedia` and
/// was silently skipped by the queue. It only appeared once something else
/// happened to warm the cache (a detail view, an import, the daily sync) —
/// which is exactly the "I added a show and it didn't show up" report.
///
/// Adversarial framing: the assertion is on the **queue**, not the cache, and
/// `TrackedShowSync` is never run. A regression that goes back to the bare
/// source still writes a perfectly good `LibraryItems` row — the library grid
/// and stats would look fine — and only this test fails.

/// Serves details, and counts fetches so a cache hit is distinguishable from a
/// refetch. Never the network.
class _FakeSource implements MetadataSource {
  _FakeSource(this.details);

  final MediaDetails details;
  int showDetailCalls = 0;

  @override
  Future<MediaDetails> showDetails(int sourceId) async {
    showDetailCalls++;
    return details;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  const severance = MediaSearchResult(
    kind: MediaKind.tv,
    title: 'Severance',
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
  );

  // Two aired episodes; nothing watched yet, so the queue should offer S1E1.
  const details = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama'],
    seasons: [SeasonInfo(seasonNumber: 1, episodeCount: 2)],
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
    showStatus: 'Returning Series',
    episodeCountTotal: 2,
    lastEpisode: EpisodeInfo(seasonNumber: 1, episodeNumber: 2),
  );

  CachingMetadataRepository repoOver(_FakeSource source) =>
      CachingMetadataRepository(
        source: source,
        sourceKind: MetadataSourceKind.tmdb,
        dao: db.mediaCacheDao,
      );

  /// The queue exactly as `watchQueueProvider` computes it — cache-only, so
  /// this is what the Up Next tab would render right now.
  Future<List<QueueEntry>> queue(CachingMetadataRepository repo) async {
    final items = await db.libraryDao.getAll();
    final shows = showsForQueue(items, MetadataSourceKind.tmdb);
    final cached = await repo.cachedShowDetails([
      for (final s in shows)
        if (s.tmdbId case final int id) id,
    ]);
    return [
      for (final item in shows)
        if (cached[item.tmdbId] case final d?)
          if (nextUnwatchedAired(
                item.lastWatchedSeason,
                item.lastWatchedEpisode,
                d,
              )
              case final next?)
            (
              itemId: item.id,
              showTitle: item.title,
              posterPath: item.posterPath,
              season: next.$1,
              episode: next.$2,
            ),
    ];
  }

  test(
    'a show added from search is in the Up Next queue straight away',
    () async {
      final source = _FakeSource(details);
      final repo = repoOver(source);

      // Nothing tracked → nothing queued.
      expect(await queue(repo), isEmpty);

      await addToLibrary(
        repo: repo,
        sourceKind: MetadataSourceKind.tmdb,
        dao: db.libraryDao,
        result: severance,
        status: TrackStatus.watching,
      );

      // No TrackedShowSync, no detail view, no restart — just the add.
      final entries = await queue(repo);
      expect(
        entries,
        hasLength(1),
        reason: 'the add must warm the queue cache',
      );
      expect(entries.single.showTitle, 'Severance');
      expect(entries.single.season, 1);
      expect(entries.single.episode, 1);
    },
  );

  test(
    'the add leaves the details in the cache, so the queue reads no network',
    () async {
      final source = _FakeSource(details);
      final repo = repoOver(source);

      await addToLibrary(
        repo: repo,
        sourceKind: MetadataSourceKind.tmdb,
        dao: db.libraryDao,
        result: severance,
        status: TrackStatus.watching,
      );

      expect(
        source.showDetailCalls,
        1,
        reason: 'fetched once, for the snapshot',
      );
      // The row the queue depends on actually exists...
      final cached = await repo.cachedShowDetails([95396]);
      expect(cached[95396]?.title, 'Severance');
      // ...and reading the queue again costs no further fetch.
      expect(source.showDetailCalls, 1);
    },
  );

  test(
    'a tracked show with a COLD cache is not queued — the mechanism',
    () async {
      // The other half of the pair: proves the "added → queued" test above is
      // not passing trivially. A perfectly good `LibraryItems` row, inserted
      // without warming the cache, is invisible to the queue. THAT is the old
      // bug — and why the add goes through the SWR repo, not the raw source.
      final now = DateTime(2026, 7, 13);
      await db.libraryDao.insertItem(
        LibraryItemsCompanion.insert(
          mediaType: MediaType.tv,
          recordedSource: MetadataSourceKind.tmdb,
          title: 'Severance',
          trackStatus: TrackStatus.watching,
          addedAt: now,
          updatedAt: now,
          tmdbId: const Value(95396),
        ),
      );

      final repo = repoOver(_FakeSource(details));
      expect(
        await queue(repo),
        isEmpty,
        reason:
            'the row exists, but the queue reads the cache — and it is cold',
      );
    },
  );

  test('a watchlisted show is deliberately NOT queued', () async {
    // Guard against "fix the queue by queueing everything": Up Next is
    // *continue* watching, so an unstarted watchlist entry stays out of it.
    final source = _FakeSource(details);
    final repo = repoOver(source);

    await addToLibrary(
      repo: repo,
      sourceKind: MetadataSourceKind.tmdb,
      dao: db.libraryDao,
      result: severance,
      status: TrackStatus.watchlist,
    );

    expect(await queue(repo), isEmpty);
  });
}
