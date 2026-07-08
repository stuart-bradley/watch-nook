import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/switch/backend_switch_service.dart';

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
  Future<MediaSearchResult?> resolveByExternalId(String imdbId) async {
    if (throwOnResolve) throw Exception('network down');
    return resolve[imdbId];
  }

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int showId, int season) =>
      Future.value(episodes[(showId, season)] ?? const []);

  @override
  Future<List<MediaSearchResult>> search(String query, {MediaKind? kind}) =>
      throw UnimplementedError();
  @override
  Future<MediaDetails> movieDetails(int sourceId) => throw UnimplementedError();
  @override
  Future<MediaDetails> showDetails(int sourceId) => throw UnimplementedError();
  @override
  Future<List<UpcomingEpisode>> upcomingForTracked(List<int> ids) =>
      throw UnimplementedError();
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
  }) => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.tv,
      recordedSource: MetadataSourceKind.tmdb,
      title: title,
      trackStatus: TrackStatus.watching,
      addedAt: now,
      updatedAt: now,
      tmdbId: Value(tmdbId),
      imdbId: Value(imdbId),
    ),
  );

  Future<void> watch(int itemId, int season, int episode) =>
      db.into(db.watchEvents).insert(
        WatchEventsCompanion.insert(
          libraryItemId: itemId,
          seasonNumber: Value(season),
          episodeNumber: Value(episode),
        ),
      );

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
    test('remaps ids to the new backend, keeps watched coords, clears flag',
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
    });

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
      final id = await db.libraryDao.insertItem(
        LibraryItemsCompanion.insert(
          mediaType: MediaType.movie,
          recordedSource: MetadataSourceKind.tmdb,
          title: 'EEAAO',
          trackStatus: TrackStatus.completed,
          addedAt: now,
          updatedAt: now,
          tmdbId: const Value(545611),
          imdbId: const Value('tt6710474'),
        ),
      );
      await db.into(db.watchEvents).insert(
            WatchEventsCompanion.insert(libraryItemId: id),
          );

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

    test('a row already on the new backend is skipped untouched', () async {
      final id = await db.libraryDao.insertItem(
        LibraryItemsCompanion.insert(
          mediaType: MediaType.tv,
          recordedSource: MetadataSourceKind.tvdb,
          title: 'Already TVDB',
          trackStatus: TrackStatus.watching,
          addedAt: now,
          updatedAt: now,
          tvdbId: const Value(1),
        ),
      );

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
      final before = (await db.libraryDao.watchEventsFor(id))
          .map((e) => (e.seasonNumber, e.episodeNumber))
          .toSet();

      final report = await service(source).switchAll();
      expect(report.flagged, 1);

      final item = await reload(id);
      expect(item.relinkFailed, isTrue);
      if (idsRelinked) {
        expect(item.recordedSource, MetadataSourceKind.tvdb);
      } else {
        expect(item.recordedSource, MetadataSourceKind.tmdb,
            reason: 'cannot relink → ids/source left intact');
        expect(item.tvdbId, isNull);
      }

      final after = (await db.libraryDao.watchEventsFor(id))
          .map((e) => (e.seasonNumber, e.episodeNumber))
          .toSet();
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

    test('episode-count divergence (watched ep missing upstream) → flagged',
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
    });

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
}
