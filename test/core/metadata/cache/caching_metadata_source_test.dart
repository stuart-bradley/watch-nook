import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/media_cache_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_source.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';

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
  int searchCalls = 0;

  @override
  Future<List<MediaSearchResult>> search(
    String query, {
    MediaKind? kind,
  }) async {
    searchCalls++;
    return const [];
  }

  @override
  Future<MediaDetails> showDetails(SourceRef ref) async {
    showCalls++;
    final e = throwable;
    if (e != null) throw e;
    return show!;
  }

  @override
  Future<MediaDetails> movieDetails(SourceRef ref) async {
    movieCalls++;
    final e = throwable;
    if (e != null) throw e;
    return movie!;
  }

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(
    SourceRef ref,
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

/// The repository under test wraps a TMDB source, so every reference it is
/// handed must say tmdb — a tvdb one is refused before the cache is even read.
SourceRef _ref(int id) => SourceRef(MetadataSourceKind.tmdb, id);

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

  CachingMetadataSource repo(_FakeSource src, {required Duration age}) =>
      CachingMetadataSource(
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
  // reads (not the payload) — see CachingMetadataSource._ttl.
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

  group('CachingMetadataSource · foreign references', () {
    // The repo's own guard, not the wrapped source's. It has to be here and it
    // has to run BEFORE the cache read: every fetch below is wrapped in a
    // catch-all that keeps a stale cache alive on failure, so a guard left to
    // the source would be swallowed by it and the caller would be handed
    // whatever THIS backend had cached under the other backend's id — the
    // wrong title, silently, which is the whole failure the reference exists
    // to make impossible.
    const foreign = SourceRef(MetadataSourceKind.tvdb, 95396);

    test('a tvdb reference is refused by a tmdb-backed repo', () async {
      final src = _FakeSource()..show = showModel(title: 'Severance');
      final r = repo(src, age: Duration.zero);

      await expectLater(r.showDetails(foreign), throwsArgumentError);
      await expectLater(r.movieDetails(foreign), throwsArgumentError);
      await expectLater(r.seasonEpisodes(foreign, 1), throwsArgumentError);
      await expectLater(
        r.watchDetails(MediaType.tv, foreign),
        emitsError(isArgumentError),
      );
      expect(
        (src.showCalls, src.movieCalls, src.episodeCalls),
        (0, 0, 0),
        reason: 'the wrong catalogue must never be asked in the first place',
      );
    });

    test('a cached row is not served for a foreign reference', () async {
      // The dangerous case: this backend HAS a row under id 95396, so without
      // the guard the stream yields it happily and never even needs the source.
      await seedShow(id: 95396, details: showModel(title: 'Severance'));

      await expectLater(
        repo(_FakeSource(), age: Duration.zero).showDetails(foreign),
        throwsArgumentError,
      );
    });
  });

  group('CachingMetadataSource · the interface over the cache', () {
    test(
      'a 404 on refresh keeps the cached value instead of throwing',
      () async {
        // The trap the add path used to work around by hand. A non-transient
        // failure propagates AFTER the cached value has been emitted, so
        // `Stream.last` would forward the error and throw away details it had
        // already been handed — silently dropping the AD-3 snapshot and writing
        // the row from thin search-hit fields. Proved by deleting the fallback
        // in `_newest` and watching this go red.
        await seedShow(id: 95396, details: showModel(title: 'Cached'));
        final src = _FakeSource()
          ..throwable = const MetadataException(404, 'gone');

        final d = await repo(
          src,
          age: const Duration(days: 40),
        ).showDetails(_ref(95396));

        expect(d.title, 'Cached');
        expect(src.showCalls, 1, reason: 'it did try to refresh');
      },
    );

    test('a cold cache plus a failed fetch still throws', () async {
      final src = _FakeSource()
        ..throwable = const MetadataException(404, 'gone');

      await expectLater(
        repo(src, age: Duration.zero).showDetails(_ref(95396)),
        throwsA(isA<MetadataException>()),
        reason: 'there is nothing to fall back to',
      );
    });

    test('it returns the revalidated value, not the stale one', () async {
      await seedShow(id: 95396, details: showModel(title: 'Stale'));
      final src = _FakeSource()..show = showModel(title: 'Fresh');

      final d = await repo(
        src,
        age: const Duration(days: 40),
      ).showDetails(_ref(95396));

      expect(d.title, 'Fresh');
    });

    test('revalidatedShowDetails refuses to answer with the cache', () async {
      // The daily sync must be able to tell that a refresh did not happen.
      // A 404 propagates even over a warm cache — exactly the split
      // `metadata_exception.dart` pins, and exactly what the sync's old
      // `.last` did. (A transient 429/500 still degrades to cache here, which
      // is the pre-existing behaviour and deliberately unchanged.)
      await seedShow(id: 95396, details: showModel(title: 'Stale'));
      final src = _FakeSource()
        ..throwable = const MetadataException(404, 'gone');

      await expectLater(
        repo(src, age: const Duration(days: 40)).revalidatedShowDetails(
          _ref(95396),
        ),
        throwsA(isA<MetadataException>()),
        reason:
            'showDetails hands back "Stale" here — which the sync would then '
            'write over itself, once a day, forever',
      );
    });

    test(
      'cachedOrFetchedEpisodes takes the cache without revalidating',
      () async {
        await seedEpisodes(showId: 95396, season: 1, eps: [ep(1), ep(2)]);
        final src = _FakeSource()..episodes = [ep(1), ep(2), ep(3)];

        final out = await repo(
          src,
          age: const Duration(days: 40), // stale — a refresh WOULD find e3
        ).cachedOrFetchedEpisodes(_ref(95396), 1);

        expect(out.map((e) => e.episodeNumber), [1, 2]);
        expect(
          src.episodeCalls,
          0,
          reason: 'bulk-mark must not block N seasons on N round-trips',
        );
      },
    );

    test('search and relink pass straight through, uncached', () async {
      final src = _FakeSource();

      await repo(src, age: Duration.zero).search('severance');

      expect(src.searchCalls, 1);
    });
  });

  group('CachingMetadataSource · details SWR', () {
    test('cold cache → fetches, persists, and emits the fresh value', () async {
      final src = _FakeSource()..show = showModel(title: 'Severance');

      final out = await repo(
        src,
        age: Duration.zero,
      ).watchDetails(MediaType.tv, _ref(95396)).toList();

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
      ).watchDetails(MediaType.tv, _ref(95396)).toList();

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
        ).watchDetails(MediaType.tv, _ref(95396)).toList();

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
        ).watchDetails(MediaType.tv, _ref(95396)).toList();

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
        ).watchDetails(MediaType.tv, _ref(95396)).toList();

        expect(out.map((d) => d.title), ['Stale']);
      },
    );

    test(
      'cold cache + transient error → propagates (nothing to serve)',
      () async {
        final src = _FakeSource()
          ..throwable = const MetadataException(500, 'x');

        await expectLater(
          repo(src, age: Duration.zero).watchDetails(MediaType.tv, _ref(95396)),
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
        repo(
          src,
          age: const Duration(hours: 13),
        ).watchDetails(MediaType.tv, _ref(95396)),
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
        ).watchDetails(MediaType.tv, _ref(1)).toList();
        expect(ended.map((d) => d.title), ['Ended']);
        expect(src.showCalls, 0); // ended → no network

        final airing = await repo(
          src,
          age: const Duration(hours: 13),
        ).watchDetails(MediaType.tv, _ref(2)).toList();
        expect(airing.map((d) => d.title), ['Airing', 'Refetched']);
        expect(src.showCalls, 1); // airing → refetched
      },
    );
  });

  group(
    'CachingMetadataSource · cachedShowDetails (batch, cache-only)',
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

  group('CachingMetadataSource · seasonEpisodes SWR', () {
    test('cold cache → fetches, persists aired order, and emits', () async {
      final src = _FakeSource()..episodes = [ep(1), ep(2), ep(3)];

      final out = await repo(
        src,
        age: Duration.zero,
      ).watchSeasonEpisodes(_ref(95396), 1).toList();

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
        ).watchSeasonEpisodes(_ref(95396), 1).toList();

        expect(out.single.map((e) => e.episodeNumber), [1, 2]); // not blanked
        expect(src.episodeCalls, 1);
      },
    );
  });
}
