import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/core/metadata/switch/backend_switch_providers.dart';
import 'package:watch_nook/core/metadata/switch/backend_switch_service.dart';

import '../../../support/library_fixtures.dart' as seed;

/// A fake `MetadataSource` for the new (TVDB) backend: only
/// `resolveByExternalId` and `seasonEpisodes` matter to the switch service;
/// everything else throws if the service ever calls down the wrong path.
class _FakeTvdb implements MetadataSource {
  _FakeTvdb({
    this.resolve = const {},
    this.episodes = const {},
    this.throwOnResolve = false,
  });

  /// imdbId -> the new backend's resolution (carries the tvdbId).
  final Map<String, MediaSearchResult> resolve;

  /// (showSourceId, season) -> aired-order episodes on the new backend.
  final Map<(int, int), List<EpisodeInfo>> episodes;
  final bool throwOnResolve;

  @override
  Future<MediaSearchResult?> resolveByExternalId(
    String id, {
    ExternalIdKind kind = ExternalIdKind.imdb,
  }) async {
    if (throwOnResolve) throw Exception('network down');
    return resolve[id];
  }

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(SourceRef show, int season) =>
      Future.value(episodes[(show.id, season)] ?? const []);

  @override
  Future<List<MediaSearchResult>> search(String query, {MediaKind? kind}) =>
      throw UnimplementedError();
  @override
  Future<MediaDetails> movieDetails(SourceRef ref) =>
      throw UnimplementedError();
  @override
  Future<MediaDetails> showDetails(SourceRef ref) => throw UnimplementedError();
  @override
  String imageUrl(String path, ImageSize size) => throw UnimplementedError();
  @override
  Attribution attribution() => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 7, 8);

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  // A show recorded against TMDB (the old backend), optionally with an imdbId.
  Future<int> addShow({
    String title = 'Severance',
    int tmdbId = 95396,
    String? imdbId = 'tt11280740',
  }) async => (await seed.seedShow(
    db,
    title: title,
    tmdbId: tmdbId,
    imdbId: imdbId,
    now: now,
  )).id;

  Future<void> watch(int itemId, int season, int episode) =>
      db.libraryDao.markWatched(itemId, season: season, episode: episode);

  MediaSearchResult tvdbHit(int tvdbId) => MediaSearchResult(
    kind: MediaKind.tv,
    title: 'Severance',
    tvdbId: tvdbId,
    imdbId: 'tt11280740',
  );

  EpisodeInfo ep(int s, int e, {DateTime? air}) =>
      EpisodeInfo(seasonNumber: s, episodeNumber: e, airDate: air);

  BackendSwitchService service(_FakeTvdb source) => BackendSwitchService(
    db: db,
    newSource: source,
    newKind: MetadataSourceKind.tvdb,
    clock: Clock.fixed(now),
  );

  Future<LibraryItem> reload(int id) async =>
      (await db.libraryDao.getAll()).firstWhere((i) => i.id == id);

  group('happy path — relink + reconcile', () {
    test(
      'remaps ids to the new backend, keeps watched coords, clears flag',
      () async {
        final id = await addShow();
        await watch(id, 1, 1);
        await watch(id, 1, 2);

        final report = await service(
          _FakeTvdb(
            resolve: {'tt11280740': tvdbHit(555)},
            episodes: {
              (555, 1): [ep(1, 1), ep(1, 2), ep(1, 3)],
            },
          ),
        ).switchAll();

        expect(report.relinked, 1);
        expect(report.flagged, 0);

        final item = await reload(id);
        expect(item.recordedSource, MetadataSourceKind.tvdb);
        expect(item.tvdbId, 555);
        expect(item.tmdbId, 95396, reason: 'old id kept, not wiped');
        expect(item.relinkFailed, isFalse);

        // Watched coordinates are untouched — the whole point of the switch.
        final events = await db.libraryDao.watchEventsFor(id);
        expect(
          events.map((e) => (e.seasonNumber, e.episodeNumber)).toSet(),
          {(1, 1), (1, 2)},
        );
      },
    );

    test('air-dates that agree with the old cache reconcile cleanly', () async {
      final id = await addShow();
      await watch(id, 1, 1);
      // Old backend cached this episode's air-date (2022-02-18).
      await db.mediaCacheDao.replaceSeasonEpisodes(
        MetadataSourceKind.tmdb,
        95396,
        1,
        [
          CachedEpisodesCompanion.insert(
            source: MetadataSourceKind.tmdb,
            showSourceId: 95396,
            seasonNumber: 1,
            episodeNumber: 1,
            fetchedAt: now,
            airDate: Value(DateTime(2022, 2, 18)),
          ),
        ],
      );

      await service(
        _FakeTvdb(
          resolve: {'tt11280740': tvdbHit(555)},
          episodes: {
            (555, 1): [ep(1, 1, air: DateTime(2022, 2, 18))],
          },
        ),
      ).switchAll();

      expect((await reload(id)).relinkFailed, isFalse);
    });

    test('a movie relinks with no episode reconciliation', () async {
      final id = (await seed.seedMovie(
        db,
        title: 'EEAAO',
        tmdbId: 545611,
        imdbId: 'tt6710474',
        now: now,
      )).id;
      // A movie's watched coordinate is (null, null).
      await db.libraryDao.markWatched(id);

      await service(
        _FakeTvdb(
          resolve: {
            'tt6710474': const MediaSearchResult(
              kind: MediaKind.movie,
              title: 'EEAAO',
              tvdbId: 999,
            ),
          },
        ),
      ).switchAll();

      final item = await reload(id);
      expect(item.tvdbId, 999);
      expect(item.relinkFailed, isFalse);
    });

    test("a relink drops the old backend's poster path", () async {
      // The whole point of ticket 11, and the case its widget test cannot
      // reach. `LibraryItem.posterRef` tags artwork with `recordedSource` —
      // the field this very write rewrites. Keep the path and the reference
      // starts claiming the NEW backend for a path the OLD one minted, so
      // `RemoteImage`'s mismatch check waves it straight through to a 404 or
      // an unrelated image. For a movie that is permanent: the daily sync only
      // refills TV rows.
      //
      // Proved to fail first by restoring the carried-over path.
      final id = (await seed.seedMovie(
        db,
        title: 'EEAAO',
        tmdbId: 545611,
        imdbId: 'tt6710474',
        posterPath: '/tmdb-only.jpg',
        now: now,
      )).id;

      await service(
        _FakeTvdb(
          resolve: {
            'tt6710474': const MediaSearchResult(
              kind: MediaKind.movie,
              title: 'EEAAO',
              tvdbId: 999,
            ),
          },
        ),
      ).switchAll();

      final item = await reload(id);
      expect(item.recordedSource, MetadataSourceKind.tvdb);
      expect(
        item.posterPath,
        isNull,
        reason:
            'a placeholder until the next fetch refills it is the honest '
            'answer; a TMDB path labelled tvdb is not',
      );
      expect(item.posterRef, isNull);
    });

    test(
      'a flagged-only row keeps its poster, because it kept its backend',
      () async {
        // The control. `_flagOnly` leaves `recordedSource` alone, so the
        // path is still true and dropping it would lose artwork for nothing.
        final id = await addShow(imdbId: null);
        await db.libraryDao.updateItem(
          id,
          const LibraryItemsCompanion(posterPath: Value('/still-tmdb.jpg')),
        );

        await service(_FakeTvdb()).switchAll();

        final item = await reload(id);
        expect(item.recordedSource, MetadataSourceKind.tmdb);
        expect(item.relinkFailed, isTrue);
        expect(item.posterPath, '/still-tmdb.jpg');
      },
    );

    test('a row already on the new backend is skipped untouched', () async {
      final id = (await seed.seedShow(
        db,
        title: 'Already TVDB',
        source: MetadataSourceKind.tvdb,
        tmdbId: null,
        tvdbId: 1,
        now: now,
      )).id;

      final report = await service(_FakeTvdb()).switchAll();

      expect(report.skipped, 1);
      expect((await reload(id)).recordedSource, MetadataSourceKind.tvdb);
    });
  });

  group('anomalies — flag relinkFailed, never scramble WatchEvents', () {
    Future<void> expectFlaggedAndUntouched(
      int id,
      _FakeTvdb source, {
      required bool idsRelinked,
    }) async {
      final before = (await db.libraryDao.watchEventsFor(
        id,
      )).map((e) => (e.seasonNumber, e.episodeNumber)).toSet();

      final report = await service(source).switchAll();
      expect(report.flagged, 1);

      final item = await reload(id);
      expect(item.relinkFailed, isTrue);
      if (idsRelinked) {
        expect(item.recordedSource, MetadataSourceKind.tvdb);
      } else {
        expect(
          item.recordedSource,
          MetadataSourceKind.tmdb,
          reason: 'cannot relink → ids/source left intact',
        );
        expect(item.tvdbId, isNull);
      }

      final after = (await db.libraryDao.watchEventsFor(
        id,
      )).map((e) => (e.seasonNumber, e.episodeNumber)).toSet();
      expect(after, before, reason: 'watch history must be untouched');
    }

    test('no imdbId → cannot relink, ids/source left intact', () async {
      final id = await addShow(imdbId: null);
      await watch(id, 1, 1);
      await expectFlaggedAndUntouched(
        id,
        _FakeTvdb(),
        idsRelinked: false,
      );
    });

    test('new backend does not resolve the imdbId → flagged', () async {
      final id = await addShow();
      await watch(id, 1, 1);
      await expectFlaggedAndUntouched(
        id,
        _FakeTvdb(), // empty resolve → no hit
        idsRelinked: false,
      );
    });

    test('resolve throws (network) → flagged, not scrambled', () async {
      final id = await addShow();
      await watch(id, 1, 1);
      await expectFlaggedAndUntouched(
        id,
        _FakeTvdb(throwOnResolve: true),
        idsRelinked: false,
      );
    });

    test(
      'episode-count divergence (watched ep missing upstream) → flagged',
      () async {
        final id = await addShow();
        await watch(id, 1, 1);
        await watch(id, 1, 3); // new backend only has eps 1 & 2
        await expectFlaggedAndUntouched(
          id,
          _FakeTvdb(
            resolve: {'tt11280740': tvdbHit(555)},
            episodes: {
              (555, 1): [ep(1, 1), ep(1, 2)],
            },
          ),
          idsRelinked: true,
        );
      },
    );

    test('a watched special (season 0) → flagged', () async {
      final id = await addShow();
      await watch(id, 0, 1);
      await expectFlaggedAndUntouched(
        id,
        _FakeTvdb(
          resolve: {'tt11280740': tvdbHit(555)},
          episodes: {
            (555, 0): [ep(0, 1)],
          },
        ),
        idsRelinked: true,
      );
    });

    test('air-date mismatch vs the old cache → flagged', () async {
      final id = await addShow();
      await watch(id, 1, 1);
      await db.mediaCacheDao.replaceSeasonEpisodes(
        MetadataSourceKind.tmdb,
        95396,
        1,
        [
          CachedEpisodesCompanion.insert(
            source: MetadataSourceKind.tmdb,
            showSourceId: 95396,
            seasonNumber: 1,
            episodeNumber: 1,
            fetchedAt: now,
            airDate: Value(DateTime(2022, 2, 18)),
          ),
        ],
      );
      await expectFlaggedAndUntouched(
        id,
        _FakeTvdb(
          resolve: {'tt11280740': tvdbHit(555)},
          episodes: {
            // Same coord, different air-date → points at a different episode.
            (555, 1): [ep(1, 1, air: DateTime(2021, 3, 4))],
          },
        ),
        idsRelinked: true,
      );
    });
  });

  // The two ways a row becomes Unverified are NOT interchangeable, and the
  // difference is entirely in what a *later* relink run does with them. See
  // CONTEXT.md ("How the two interact on a relink") — the second case is the
  // one that looks healthy, and the reason the position marker exists.
  group('the two Unverified outcomes behave differently on a later run', () {
    /// The Settings relink offer's number, read through the provider that
    /// feeds it rather than a copy of its rule.
    Future<int> relinkOfferCount() async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tvdb),
        ],
      );
      addTearDown(container.dispose);
      return container.read(backendMismatchCountProvider.future);
    }

    test('could not relink at all → retried, and still counted', () async {
      // No imdbId, so there is no way to find it on the new backend. Its ids
      // and recordedSource are left alone, which is what keeps it eligible.
      final id = await addShow(imdbId: null);

      final first = await service(_FakeTvdb()).switchAll();
      expect(first.flagged, 1);

      final row = await reload(id);
      expect(row.relinkFailed, isTrue);
      expect(
        row.recordedSource,
        MetadataSourceKind.tmdb,
        reason: 'nothing to point it at, so it stays on the old backend',
      );

      final second = await service(_FakeTvdb()).switchAll();
      expect(
        second.skipped,
        0,
        reason: 'a later run must not skip it — it never moved',
      );
      expect(second.flagged, 1, reason: 'it is tried again, and fails again');
      expect(
        await relinkOfferCount(),
        1,
        reason: 'the Settings offer must not vanish for a retryable row',
      );
    });

    test('relinked but unreconciled → not retried, and not counted', () async {
      final id = await addShow();
      await watch(id, 1, 1);

      // Resolves on the new backend (so the ids move) but the watched
      // coordinate has no counterpart there.
      final source = _FakeTvdb(resolve: {'tt11280740': tvdbHit(555)});
      final first = await service(source).switchAll();
      expect(first.flagged, 1);

      final row = await reload(id);
      expect(row.relinkFailed, isTrue);
      expect(
        row.recordedSource,
        MetadataSourceKind.tvdb,
        reason: 'the show was found, so the row moved to the new backend',
      );

      final second = await service(source).switchAll();
      expect(
        second.skipped,
        1,
        reason: 'already on the active backend — every later run skips it',
      );
      expect(second.flagged, 0);
      expect(
        await relinkOfferCount(),
        0,
        reason:
            'not stranded, so the offer cannot reach it; only a dismiss can',
      );
    });
  });
}
