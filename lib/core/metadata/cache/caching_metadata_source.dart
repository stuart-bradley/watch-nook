import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/media_cache_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';

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
class CachingMetadataSource implements MetadataSource {
  /// Wraps [source] (whose backend is [sourceKind]) with a [dao]-backed cache.
  /// [clock] drives TTL staleness — inject a fixed clock in tests.
  CachingMetadataSource({
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

  /// The freshest details available for a show — the [MetadataSource]
  /// contract, satisfied over the cache.
  ///
  /// Revalidates a stale or missing entry and returns the fresh value; falls
  /// back to what was cached when the refresh fails, and only throws when
  /// there was nothing cached to fall back to.
  ///
  /// That fallback is the whole reason this is not `watchDetails(...).last`.
  /// A non-transient failure (a 404 on refresh) propagates *after* the cached
  /// value has been emitted, and `Stream.last` forwards the error — throwing
  /// away perfectly good details it had already been handed. The add path used
  /// to reconstruct this loop itself, in a ten-line comment; it belongs here.
  @override
  Future<MediaDetails> showDetails(SourceRef ref) =>
      _newest(watchDetails(MediaType.tv, ref));

  /// The freshest details available for a movie. See [showDetails].
  @override
  Future<MediaDetails> movieDetails(SourceRef ref) =>
      _newest(watchDetails(MediaType.movie, ref));

  /// The freshest aired-order episodes available for one season (ADR-4).
  /// Same cache-preserving contract as [showDetails].
  @override
  Future<List<EpisodeInfo>> seasonEpisodes(SourceRef show, int seasonNumber) =>
      _newest(watchSeasonEpisodes(show, seasonNumber));

  /// **Only the revalidated value**, never the cache alone — and so it throws
  /// when the refresh fails.
  ///
  /// For the daily tracked-show sync, whose entire job is to pull fresh
  /// episode counts, status and next-air. [showDetails] would hand it back the
  /// stale value it already has and it would write that over itself once a
  /// day; a caller that wants a refresh must be able to tell one didn't
  /// happen.
  Future<MediaDetails> revalidatedShowDetails(SourceRef ref) =>
      watchDetails(MediaType.tv, ref).last;

  /// The cached season if there is one, fetching **only** when it is cold —
  /// never waiting on a revalidation.
  ///
  /// For bulk-mark, which walks every season of a show: waiting for each
  /// season's refetch made a whole-show mark appear to do nothing until you
  /// reloaded (the write sat behind N round-trips, and aborted offline). A
  /// warmed show marks instantly; a cold season still fetches.
  Future<List<EpisodeInfo>> cachedOrFetchedEpisodes(
    SourceRef show,
    int seasonNumber,
  ) => watchSeasonEpisodes(show, seasonNumber).first;

  /// Keeps the newest emission and re-raises only on a cold stream.
  static Future<T> _newest<T>(Stream<T> stream) async {
    T? newest;
    try {
      await for (final value in stream) {
        newest = value;
      }
    } on Object {
      if (newest == null) rethrow;
    }
    return newest!;
  }

  // --- uncached, delegated straight through -------------------------------
  //
  // Search and relink are one-shot user actions against live data; caching a
  // query would only ever serve a stale answer to a new question. They are
  // here so callers have ONE interface and one provider, not because the cache
  // has anything to add.

  @override
  Future<List<MediaSearchResult>> search(String query, {MediaKind? kind}) =>
      _source.search(query, kind: kind);

  @override
  Future<MediaSearchResult?> resolveByExternalId(
    String id, {
    ExternalIdKind kind = ExternalIdKind.imdb,
  }) => _source.resolveByExternalId(id, kind: kind);

  @override
  String imageUrl(String path, ImageSize size) => _source.imageUrl(path, size);

  @override
  Attribution attribution() => _source.attribution();

  // --- the streaming forms -------------------------------------------------

  /// Cache-then-fresh details: emits the cached value **first** (instant,
  /// offline-safe) and then, only if the cache was missing or stale, the
  /// revalidated one. For a screen that should paint immediately and update in
  /// place.
  Stream<MediaDetails> watchDetails(MediaType type, SourceRef ref) => _details(
    type,
    ref,
    () => type == MediaType.movie
        ? _source.movieDetails(ref)
        : _source.showDetails(ref),
  );

  Stream<MediaDetails> _details(
    MediaType type,
    SourceRef ref,
    Future<MediaDetails> Function() fetch,
  ) async* {
    // Guarded HERE, before the try below, and not left to the wrapped source:
    // the catch-alls that keep a stale cache alive on a network failure would
    // otherwise swallow a foreign reference and serve whatever this backend
    // had cached under the other backend's id — silently, which is exactly the
    // wrong-title bug the reference exists to prevent.
    final sourceId = ref.idFor(_sourceKind);
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

  /// Cache-**only** show details for many [shows] in one query — no
  /// network, no revalidation. The watch queue recomputes on every library
  /// write, so it reads all its shows this way (one round-trip, decode-once)
  /// instead of an N+1 of per-show `showDetails(...).first`. A cold title is
  /// absent from the map (the tracked-show sync warms it, and the queue
  /// recomputes when it has); a corrupt/legacy payload is skipped, not fatal.
  Future<Map<int, MediaDetails>> cachedShowDetails(
    Iterable<SourceRef> shows,
  ) async {
    // Guarded like every other lookup. This one keys the cache by `_sourceKind`
    // and a caller-supplied id, so a foreign id does not miss — it returns
    // ANOTHER title's `nextEpisode`/`lastEpisode` markers, which is precisely
    // what bulk-mark uses to decide what has aired and what the queue uses to
    // decide what you are up to.
    final ids = [for (final show in shows) show.idFor(_sourceKind)];
    final rows = await _dao.getManyMedia(_sourceKind, MediaType.tv, ids);
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

  /// Cache-then-fresh aired-order episodes for one season (ADR-4). The
  /// episode twin of [watchDetails].
  Stream<List<EpisodeInfo>> watchSeasonEpisodes(
    SourceRef show,
    int seasonNumber,
  ) async* {
    // Guarded before the cache read, for the reason in [_details].
    final showSourceId = show.idFor(_sourceKind);
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
      final fresh = await _source.seasonEpisodes(show, seasonNumber);
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
