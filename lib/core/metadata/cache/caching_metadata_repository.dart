import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/media_cache_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// Stale-while-revalidate cache over a [MetadataSource] (ADR-7, US-13).
///
/// Every read is a stream that **emits the cached value first** (instant,
/// offline-safe) and then, only if the cache is missing or stale, revalidates
/// over the network and emits the fresh value. The load-bearing invariant:
///
/// > A revalidation failure NEVER blanks a screen that already has cache.
///
/// Once a cached value has been emitted, a failed refetch is swallowed and the
/// (stale) cache stands — an error surfaces only on a cold cache plus a failed
/// fetch. Transient backend errors (`429`/`500`) keep the cache; other HTTP
/// codes (e.g. `404` — title genuinely gone) propagate. That split is pinned in
/// the exception doc in `metadata_exception.dart`.
///
/// This is a one-shot cache→revalidate stream, not a live `.watch()`
/// subscription: it emits at most twice (cache, then fresh) and completes.
/// Live repaint-on-external-write (the on-resume refresh) is M2's concern.
// ponytail: one-shot SWR; upgrade to a live cache `.watch()` when the
// resume-refresh that would repaint it actually exists (M2).
class CachingMetadataRepository {
  /// Wraps [source] (whose backend is [sourceKind]) with a [dao]-backed cache.
  /// [clock] drives TTL staleness — inject a fixed clock in tests.
  CachingMetadataRepository({
    required MetadataSource source,
    required MetadataSourceKind sourceKind,
    required MediaCacheDao dao,
    Clock clock = const Clock(),
  }) : _source = source,
       _sourceKind = sourceKind,
       _dao = dao,
       _clock = clock;

  final MetadataSource _source;
  final MetadataSourceKind _sourceKind;
  final MediaCacheDao _dao;
  final Clock _clock;

  // ADR-7 TTL-by-volatility. An ended show / released movie rarely changes; an
  // airing show gains episodes and air dates. Image TTL (60d) is enforced by
  // PosterCacheManager, not here.
  static const _endedTtl = Duration(days: 30);
  static const _airingTtl = Duration(hours: 12); // within ADR-7's 6–24h band.

  /// Cache-first details for a show ([sourceId] is this backend's own id).
  Stream<MediaDetails> showDetails(int sourceId) =>
      _details(MediaType.tv, sourceId, () => _source.showDetails(sourceId));

  /// Cache-first details for a movie ([sourceId] is this backend's own id).
  Stream<MediaDetails> movieDetails(int sourceId) =>
      _details(MediaType.movie, sourceId, () => _source.movieDetails(sourceId));

  Stream<MediaDetails> _details(
    MediaType type,
    int sourceId,
    Future<MediaDetails> Function() fetch,
  ) async* {
    final cached = await _dao.getMedia(_sourceKind, type, sourceId);
    if (cached != null) {
      yield MediaDetails.fromJson(
        jsonDecode(cached.payload) as Map<String, dynamic>,
      );
    }

    final ttl = _ttl(type, cached?.showStatus);
    if (cached != null && !_isStale(cached.fetchedAt, ttl)) return; // fresh

    try {
      final fresh = await fetch();
      await _dao.upsertMedia(_mediaRow(type, sourceId, fresh));
      yield fresh;
    } on MetadataException catch (e) {
      // Non-transient (404/401/…) always propagates; a transient error keeps
      // the cache we already emitted, or propagates on a cold cache.
      if (!_transient(e.statusCode) || cached == null) rethrow;
    } on Object {
      // Offline/socket/parse failure: fall back to the (stale) cache already
      // emitted; surface only when the cache was cold.
      if (cached == null) rethrow;
    }
  }

  /// Cache-**only** show details for many [sourceIds] in one query — no
  /// network, no revalidation. The watch queue recomputes on every library
  /// write, so it reads all its shows this way (one round-trip, decode-once)
  /// instead of an N+1 of per-show `showDetails(...).first`. A cold title is
  /// absent from the map (the tracked-show sync warms it, and the queue
  /// recomputes when it has); a corrupt/legacy payload is skipped, not fatal.
  Future<Map<int, MediaDetails>> cachedShowDetails(
    Iterable<int> sourceIds,
  ) async {
    final rows = await _dao.getManyMedia(
      _sourceKind,
      MediaType.tv,
      sourceIds.toList(),
    );
    final out = <int, MediaDetails>{};
    for (final row in rows) {
      try {
        out[row.sourceId] = MediaDetails.fromJson(
          jsonDecode(row.payload) as Map<String, dynamic>,
        );
      } on Object {
        // Skip a corrupt/legacy payload; one bad row can't sink the queue.
      }
    }
    return out;
  }

  /// Cache-first aired-order episodes for one season (ADR-4).
  Stream<List<EpisodeInfo>> seasonEpisodes(
    int showSourceId,
    int seasonNumber,
  ) async* {
    final cached = await _dao.getEpisodes(
      _sourceKind,
      showSourceId,
      seasonNumber,
    );
    if (cached.isNotEmpty) yield cached.map(_episodeFromRow).toList();

    // Episodes belong to an airing show → the shorter TTL. Gate on the oldest
    // row so a partially-stale season refreshes.
    final oldest = cached.isEmpty
        ? null
        : cached
              .map((e) => e.fetchedAt)
              .reduce((a, b) => a.isBefore(b) ? a : b);
    if (oldest != null && !_isStale(oldest, _airingTtl)) return; // fresh

    try {
      final fresh = await _source.seasonEpisodes(showSourceId, seasonNumber);
      await _dao.replaceSeasonEpisodes(
        _sourceKind,
        showSourceId,
        seasonNumber,
        fresh.map((e) => _episodeRow(showSourceId, e)).toList(),
      );
      yield fresh;
    } on MetadataException catch (e) {
      if (!_transient(e.statusCode) || cached.isEmpty) rethrow;
    } on Object {
      if (cached.isEmpty) rethrow;
    }
  }

  Duration _ttl(MediaType type, String? showStatus) {
    if (type == MediaType.movie) return _endedTtl;
    // Anything not clearly ended/cancelled gets the airing TTL — the safe
    // default (refresh more often rather than serve a stale schedule).
    return showHasEnded(showStatus) ? _endedTtl : _airingTtl;
  }

  bool _isStale(DateTime fetchedAt, Duration ttl) =>
      _clock.now().difference(fetchedAt) >= ttl;

  bool _transient(int statusCode) => statusCode == 429 || statusCode == 500;

  CachedMediaCompanion _mediaRow(
    MediaType type,
    int sourceId,
    MediaDetails d,
  ) => CachedMediaCompanion.insert(
    source: _sourceKind,
    mediaType: type,
    sourceId: sourceId,
    payload: jsonEncode(d.toJson()),
    fetchedAt: _clock.now(),
    title: d.title,
    imdbId: Value(d.imdbId),
    year: Value(d.year),
    posterPath: Value(d.posterPath),
    backdropPath: Value(d.backdropPath),
    overview: Value(d.overview),
    showStatus: Value(d.showStatus),
    nextAirDate: Value(d.nextEpisode?.airDate),
    runtimeMinutes: Value(d.runtimeMinutes),
    genresCsv: Value(d.genres.isEmpty ? null : d.genres.join(',')),
  );

  CachedEpisodesCompanion _episodeRow(int showSourceId, EpisodeInfo e) =>
      CachedEpisodesCompanion.insert(
        source: _sourceKind,
        showSourceId: showSourceId,
        seasonNumber: e.seasonNumber,
        episodeNumber: e.episodeNumber,
        fetchedAt: _clock.now(),
        title: Value(e.title),
        airDate: Value(e.airDate),
        overview: Value(e.overview),
        runtimeMinutes: Value(e.runtimeMinutes),
      );

  EpisodeInfo _episodeFromRow(CachedEpisode r) => EpisodeInfo(
    seasonNumber: r.seasonNumber,
    episodeNumber: r.episodeNumber,
    title: r.title,
    airDate: r.airDate,
    overview: r.overview,
    runtimeMinutes: r.runtimeMinutes,
  );
}
