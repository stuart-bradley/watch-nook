import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

/// Seeding helpers for tests that need a library.
///
/// **Reach for [seedShow] / [seedMovie].** They go through the same DAO writes
/// the app itself uses — `addOrGetItem` for membership, `markWatched` for
/// progress — so the rows they produce are rows the app can actually produce.
/// In particular `watchedCount` / `lastWatched*` are **computed** by
/// `recomputeDenormalized`, never handed in: a fixture cannot invent a progress
/// state the real code would never write, which is exactly the class of bug a
/// test is supposed to catch rather than encode.
///
/// [seedRawItem] / [seedRawWatch] bypass all of that and write rows directly.
/// They exist for the handful of DAO tests that must fabricate *broken* state
/// on purpose — `recomputeDenormalized` is designed to be pointed at arbitrary
/// rows and repair them, and you cannot test a repair without damage. If you
/// are reaching for a raw helper anywhere else, you probably want the
/// production-path one above.

/// The fixed timestamp fixtures use unless told otherwise. Tests that care
/// about ordering or recency should pass their own `now`.
final DateTime fixtureNow = DateTime(2026);

/// Seeds a tracked TV show and returns the stored row.
///
/// [watched] marks aired `(season, episode)` coordinates through the real
/// `markWatched` path, so progress columns are derived, not asserted into
/// place. [rating] goes through `updateRating` for the same reason.
Future<LibraryItem> seedShow(
  AppDatabase db, {
  String title = 'Severance',
  int? tmdbId = 95396,
  int? tvdbId,
  String? imdbId,
  int? year,
  MetadataSourceKind source = MetadataSourceKind.tmdb,
  TrackStatus status = TrackStatus.watching,
  String? posterPath,
  String? genresCsv,
  int? runtimeMinutes,
  String? showStatus,
  int? episodeCountTotal,
  int? rating,
  DateTime? now,
  List<(int season, int episode)> watched = const [],
}) => _seed(
  db,
  mediaType: MediaType.tv,
  title: title,
  tmdbId: tmdbId,
  tvdbId: tvdbId,
  imdbId: imdbId,
  year: year,
  source: source,
  status: status,
  posterPath: posterPath,
  genresCsv: genresCsv,
  runtimeMinutes: runtimeMinutes,
  showStatus: showStatus,
  episodeCountTotal: episodeCountTotal,
  rating: rating,
  now: now,
  watched: watched,
);

/// Seeds a tracked movie and returns the stored row.
///
/// A movie's watch coordinate is `(null, null)`, so progress is a bool, not a
/// list: [watched] true marks it through `markWatched`.
Future<LibraryItem> seedMovie(
  AppDatabase db, {
  String title = 'Dune',
  int? tmdbId = 438631,
  int? tvdbId,
  String? imdbId,
  int? year,
  MetadataSourceKind source = MetadataSourceKind.tmdb,
  TrackStatus status = TrackStatus.completed,
  String? posterPath,
  String? genresCsv,
  int? runtimeMinutes,
  int? rating,
  DateTime? now,
  bool watched = false,
}) => _seed(
  db,
  mediaType: MediaType.movie,
  title: title,
  tmdbId: tmdbId,
  tvdbId: tvdbId,
  imdbId: imdbId,
  year: year,
  source: source,
  status: status,
  posterPath: posterPath,
  genresCsv: genresCsv,
  runtimeMinutes: runtimeMinutes,
  rating: rating,
  now: now,
  watched: watched ? const [(null, null)] : const [],
);

Future<LibraryItem> _seed(
  AppDatabase db, {
  required MediaType mediaType,
  required String title,
  required int? tmdbId,
  required int? tvdbId,
  required String? imdbId,
  required int? year,
  required MetadataSourceKind source,
  required TrackStatus status,
  required String? posterPath,
  required String? genresCsv,
  required int? runtimeMinutes,
  required int? rating,
  required DateTime? now,
  required List<(int?, int?)> watched,
  String? showStatus,
  int? episodeCountTotal,
}) async {
  final dao = db.libraryDao;
  final stamp = now ?? fixtureNow;

  final (:item, created: _) = await dao.addOrGetItem(
    LibraryItemsCompanion.insert(
      mediaType: mediaType,
      recordedSource: source,
      title: title,
      trackStatus: status,
      addedAt: stamp,
      updatedAt: stamp,
      tmdbId: Value(tmdbId),
      tvdbId: Value(tvdbId),
      imdbId: Value(imdbId),
      year: Value(year),
      posterPath: Value(posterPath),
      genresCsv: Value(genresCsv),
      runtimeMinutes: Value(runtimeMinutes),
      showStatus: Value(showStatus),
      episodeCountTotal: Value(episodeCountTotal),
    ),
  );

  for (final (season, episode) in watched) {
    await dao.markWatched(
      item.id,
      season: season,
      episode: episode,
      watchedAt: stamp,
      // Faithful to the two production mark sites: a movie snapshots its own
      // runtime (detail_screen), an episode snapshots the *episode's* runtime,
      // which a fixture has no business inventing from the show average.
      runtimeMinutes: mediaType == MediaType.movie ? runtimeMinutes : null,
    );
  }
  if (rating != null) await dao.updateRating(item.id, rating, now: stamp);

  return (await dao.getItem(item.id))!;
}

/// Writes a `LibraryItems` row directly, bypassing `addOrGetItem`'s dedupe and
/// every derived-column rule. **Only** for tests that must fabricate state the
/// app cannot produce — chiefly the `recomputeDenormalized` repair tests, which
/// need wrong `watchedCount` / `lastWatched*` values to repair. Everything else
/// wants [seedShow] or [seedMovie].
Future<int> seedRawItem(AppDatabase db, LibraryItemsCompanion entry) =>
    db.libraryDao.insertItem(entry);

/// Writes a `WatchEvents` row directly, bypassing the idempotent
/// `markWatched` marker semantics and the denormalized recompute that follows
/// it. Same warning as [seedRawItem]: this exists so a test can *create* the
/// inconsistency it then asserts gets repaired.
Future<int> seedRawWatch(
  AppDatabase db,
  int itemId, {
  int? season,
  int? episode,
  DateTime? watchedAt,
  int? runtimeMinutes,
  bool isRewatch = false,
}) => db.into(db.watchEvents).insert(
  WatchEventsCompanion.insert(
    libraryItemId: itemId,
    seasonNumber: Value(season),
    episodeNumber: Value(episode),
    watchedAt: Value(watchedAt),
    runtimeMinutes: Value(runtimeMinutes),
    isRewatch: Value(isRewatch),
  ),
);
