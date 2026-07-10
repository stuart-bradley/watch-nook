import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

part 'media_cache_dao.g.dart';

/// Data access for the **disposable** metadata cache (`CachedMedia`,
/// `CachedEpisodes`). Pure cache reads/writes — the stale-while-revalidate
/// policy (TTL, refetch, error fallback) lives in `CachingMetadataRepository`,
/// which owns this DAO. See the cache-domain invariant in `tables.dart`.
@DriftAccessor(tables: [CachedMedia, CachedEpisodes])
class MediaCacheDao extends DatabaseAccessor<AppDatabase>
    with _$MediaCacheDaoMixin {
  /// Creates a [MediaCacheDao].
  MediaCacheDao(super.attachedDatabase);

  /// The cached details row for a title, or null on a cold cache.
  Future<CachedMediaData?> getMedia(
    MetadataSourceKind source,
    MediaType mediaType,
    int sourceId,
  ) =>
      (select(cachedMedia)..where(
            (t) =>
                t.source.equalsValue(source) &
                t.mediaType.equalsValue(mediaType) &
                t.sourceId.equals(sourceId),
          ))
          .getSingleOrNull();

  /// Upsert one details row (PK `source,mediaType,sourceId`) — a re-fetch of
  /// the same title replaces the previous cache in place.
  Future<void> upsertMedia(CachedMediaCompanion row) =>
      into(cachedMedia).insertOnConflictUpdate(row);

  /// The cached episodes for one season of a show, in aired order (ADR-4).
  Future<List<CachedEpisode>> getEpisodes(
    MetadataSourceKind source,
    int showSourceId,
    int seasonNumber,
  ) =>
      (select(cachedEpisodes)
            ..where(
              (t) =>
                  t.source.equalsValue(source) &
                  t.showSourceId.equals(showSourceId) &
                  t.seasonNumber.equals(seasonNumber),
            )
            ..orderBy([(t) => OrderingTerm(expression: t.episodeNumber)]))
          .get();

  /// Replace one season's cached episodes atomically: delete the old rows then
  /// insert the fresh set, so an episode dropped upstream doesn't linger.
  Future<void> replaceSeasonEpisodes(
    MetadataSourceKind source,
    int showSourceId,
    int seasonNumber,
    List<CachedEpisodesCompanion> rows,
  ) => transaction(() async {
    await (delete(cachedEpisodes)..where(
          (t) =>
              t.source.equalsValue(source) &
              t.showSourceId.equals(showSourceId) &
              t.seasonNumber.equals(seasonNumber),
        ))
        .go();
    await batch((b) => b.insertAll(cachedEpisodes, rows));
  });

  /// Wipes the entire disposable cache (both tables). Used by the GDPR
  /// delete-all; everything here re-fetches on demand, so this is always safe.
  Future<void> clearAll() => transaction(() async {
    await delete(cachedEpisodes).go();
    await delete(cachedMedia).go();
  });
}
