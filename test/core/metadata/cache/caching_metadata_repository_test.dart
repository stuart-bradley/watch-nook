import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/media_cache_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// #13 — the stale-while-revalidate cache over a `MetadataSource`. These tests
/// pin the **load-bearing invariant** (a revalidation failure never blanks a
/// screen that already has cache), the ADR-7 TTL-by-volatility split, and the
/// transient-vs-fatal error branch. Time is injected via a fixed [Clock] so the
/// staleness maths is deterministic; the cache is a real in-memory Drift DB
/// (not a mock) so the DAO's own queries ride along.

/// A `MetadataSource` stand-in: returns the configured value, or throws
/// [throwable] if set, and counts calls so a test can prove the network was (or
/// wasn't) hit. Unused interface members throw via [noSuchMethod].
class _FakeSource implements MetadataSource {
  MediaDetails? show;
  MediaDetails? movie;
  List<EpisodeInfo>? episodes;
  Exception? throwable;
  int showCalls = 0;
  int movieCalls = 0;
  int episodeCalls = 0;

  @override
  Future<MediaDetails> showDetails(int sourceId) async {
    showCalls++;
    final e = throwable;
    if (e != null) throw e;
    return show!;
  }

  @override
  Future<MediaDetails> movieDetails(int sourceId) async {
    movieCalls++;
    final e = throwable;
    if (e != null) throw e;
    return movie!;
  }

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(
    int showSourceId,
    int seasonNumber,
  ) async {
    episodeCalls++;
    final e = throwable;
    if (e != null) throw e;
    return episodes!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  // The cache is seeded at [base]; a repo's clock is `base + age`, so a row's
  // staleness equals the `age` passed to [repo]. Airing TTL is 12h, ended 30d.
  final base = DateTime.utc(2026);
  late AppDatabase db;
  late MediaCacheDao dao;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = db.mediaCacheDao;
  });
  tearDown(() => db.close());

  CachingMetadataRepository repo(_FakeSource src, {required Duration age}) =>
      CachingMetadataRepository(
        source: src,
        sourceKind: MetadataSourceKind.tmdb,
        dao: dao,
        clock: Clock.fixed(base.add(age)),
      );

  MediaDetails showModel({required String title, String? status}) =>
      MediaDetails(
        kind: MediaKind.tv,
        title: title,
        genres: const ['Drama'],
        seasons: const [SeasonInfo(seasonNumber: 1, episodeCount: 9)],
        tmdbId: 95396,
        imdbId: 'tt11280740',
        year: 2022,
        showStatus: status,
        nextEpisode: EpisodeInfo(
          seasonNumber: 2,
          episodeNumber: 1,
          airDate: DateTime.utc(2027, 1, 15),
        ),
      );

  EpisodeInfo ep(int n) => EpisodeInfo(
    seasonNumber: 1,
    episodeNumber: n,
    title: 'E$n',
    airDate: DateTime.utc(2022, 2, 10 + n),
  );

  // `status` drives the promoted `showStatus` COLUMN, which the TTL branch
  // reads (not the payload) — see CachingMetadataRepository._ttl.
  Future<void> seedShow({
    required int id,
    required MediaDetails details,
    String? status,
  }) => dao.upsertMedia(
    CachedMediaCompanion.insert(
      source: MetadataSourceKind.tmdb,
      mediaType: MediaType.tv,
      sourceId: id,
      payload: jsonEncode(details.toJson()),
      fetchedAt: base,
      title: details.title,
      showStatus: Value(status),
    ),
  );

  Future<void> seedEpisodes({
    required int showId,
    required int season,
    required List<EpisodeInfo> eps,
  }) => dao.replaceSeasonEpisodes(
    MetadataSourceKind.tmdb,
    showId,
    season,
    eps
        .map(
          (e) => CachedEpisodesCompanion.insert(
            source: MetadataSourceKind.tmdb,
            showSourceId: showId,
            seasonNumber: e.seasonNumber,
            episodeNumber: e.episodeNumber,
            fetchedAt: base,
            title: Value(e.title),
            airDate: Value(e.airDate),
          ),
        )
        .toList(),
  );

  group('CachingMetadataRepository · details SWR', () {
    test('cold cache → fetches, persists, and emits the fresh value', () async {
      final src = _FakeSource()..show = showModel(title: 'Severance');

      final out = await repo(
        src,
        age: Duration.zero,
      ).showDetails(95396).toList();

      expect(out.map((d) => d.title), ['Severance']);
      expect(src.showCalls, 1);
      // Persisted so the next read is a cache hit.
      final row = await dao.getMedia(
        MetadataSourceKind.tmdb,
        MediaType.tv,
        95396,
      );
      expect(row, isNotNull);
    });

    test('fresh cache → serves cache and never touches the network', () async {
      await seedShow(id: 95396, details: showModel(title: 'Cached'));
      final src = _FakeSource(); // .show unset → would throw if fetched

      final out = await repo(
        src,
        age: const Duration(hours: 11), // < 12h airing TTL → fresh
      ).showDetails(95396).toList();

      expect(out.map((d) => d.title), ['Cached']);
      expect(src.showCalls, 0);
    });

    test(
      'stale cache → emits stale then fresh and replaces the cache',
      () async {
        await seedShow(id: 95396, details: showModel(title: 'Stale'));
        final src = _FakeSource()..show = showModel(title: 'Fresh');

        final out = await repo(
          src,
          age: const Duration(hours: 13), // > 12h → stale
        ).showDetails(95396).toList();

        expect(out.map((d) => d.title), ['Stale', 'Fresh']);
        expect(src.showCalls, 1);
        final row = await dao.getMedia(
          MetadataSourceKind.tmdb,
          MediaType.tv,
          95396,
        );
        expect(
          (jsonDecode(row!.payload) as Map<String, dynamic>)['title'],
          'Fresh', // cache overwritten with the revalidated value
        );
      },
    );

    test(
      'stale cache + transient 500 → keeps serving stale, no error (INVARIANT)',
      () async {
        await seedShow(id: 95396, details: showModel(title: 'Stale'));
        final src = _FakeSource()
          ..throwable = const MetadataException(500, 'x');

        final out = await repo(
          src,
          age: const Duration(hours: 13),
        ).showDetails(95396).toList();

        expect(out.map((d) => d.title), ['Stale']); // never blanked
        expect(src.showCalls, 1); // it did try to revalidate
      },
    );

    test(
      'stale cache + offline error → keeps serving stale, no error (INVARIANT)',
      () async {
        await seedShow(id: 95396, details: showModel(title: 'Stale'));
        final src = _FakeSource()..throwable = Exception('offline');

        final out = await repo(
          src,
          age: const Duration(hours: 13),
        ).showDetails(95396).toList();

        expect(out.map((d) => d.title), ['Stale']);
      },
    );

    test(
      'cold cache + transient error → propagates (nothing to serve)',
      () async {
        final src = _FakeSource()
          ..throwable = const MetadataException(500, 'x');

        await expectLater(
          repo(src, age: Duration.zero).showDetails(95396),
          emitsError(isA<MetadataException>()),
        );
      },
    );

    test('non-transient 404 → emits stale then propagates the error', () async {
      // 404 = the title is genuinely gone, so surface it even over stale cache.
      await seedShow(id: 95396, details: showModel(title: 'Stale'));
      final src = _FakeSource()
        ..throwable = const MetadataException(404, 'gone');

      await expectLater(
        repo(src, age: const Duration(hours: 13)).showDetails(95396),
        emitsInOrder([
          isA<MediaDetails>(),
          emitsError(isA<MetadataException>()),
        ]),
      );
    });

    test(
      'TTL volatility → ended show stays fresh where airing goes stale',
      () async {
        await seedShow(
          id: 1,
          details: showModel(title: 'Ended'),
          status: 'Ended',
        );
        await seedShow(
          id: 2,
          details: showModel(title: 'Airing'),
        ); // null → airing
        final src = _FakeSource()..show = showModel(title: 'Refetched');

        // 13h old: airing TTL (12h) is blown; ended TTL (30d) is not.
        final ended = await repo(
          src,
          age: const Duration(hours: 13),
        ).showDetails(1).toList();
        expect(ended.map((d) => d.title), ['Ended']);
        expect(src.showCalls, 0); // ended → no network

        final airing = await repo(
          src,
          age: const Duration(hours: 13),
        ).showDetails(2).toList();
        expect(airing.map((d) => d.title), ['Airing', 'Refetched']);
        expect(src.showCalls, 1); // airing → refetched
      },
    );
  });

  group(
    'CachingMetadataRepository · cachedShowDetails (batch, cache-only)',
    () {
      test('reads many in one query, skips cold + corrupt, never hits the '
          'source', () async {
        final src = _FakeSource();
        await seedShow(id: 100, details: showModel(title: 'A'));
        await seedShow(id: 200, details: showModel(title: 'B'));
        // A corrupt/legacy payload must be skipped, not sink the whole batch.
        await dao.upsertMedia(
          CachedMediaCompanion.insert(
            source: MetadataSourceKind.tmdb,
            mediaType: MediaType.tv,
            sourceId: 300,
            payload: '{ not json',
            fetchedAt: base,
            title: 'C',
          ),
        );

        final out = await repo(
          src,
          age: Duration.zero,
        ).cachedShowDetails([100, 200, 300, 999]);

        expect(out.keys.toSet(), {100, 200}); // 300 corrupt, 999 cold
        expect(out[100]!.title, 'A');
        expect(out[200]!.title, 'B');
        expect(src.showCalls, 0, reason: 'cache-only — never revalidates');
      });

      test('an empty id list returns an empty map', () async {
        final out = await repo(
          _FakeSource(),
          age: Duration.zero,
        ).cachedShowDetails(const []);
        expect(out, isEmpty);
      });
    },
  );

  group('CachingMetadataRepository · seasonEpisodes SWR', () {
    test('cold cache → fetches, persists aired order, and emits', () async {
      final src = _FakeSource()..episodes = [ep(1), ep(2), ep(3)];

      final out = await repo(
        src,
        age: Duration.zero,
      ).seasonEpisodes(95396, 1).toList();

      expect(out.single.map((e) => e.episodeNumber), [1, 2, 3]);
      expect(src.episodeCalls, 1);
      final rows = await dao.getEpisodes(MetadataSourceKind.tmdb, 95396, 1);
      expect(rows.map((r) => r.episodeNumber), [1, 2, 3]);
    });

    test(
      'stale cache + transient error → keeps cached episodes (INVARIANT)',
      () async {
        await seedEpisodes(showId: 95396, season: 1, eps: [ep(1), ep(2)]);
        final src = _FakeSource()
          ..throwable = const MetadataException(500, 'x');

        final out = await repo(
          src,
          age: const Duration(hours: 13),
        ).seasonEpisodes(95396, 1).toList();

        expect(out.single.map((e) => e.episodeNumber), [1, 2]); // not blanked
        expect(src.episodeCalls, 1);
      },
    );
  });
}
