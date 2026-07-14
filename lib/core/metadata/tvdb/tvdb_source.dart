import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// TheTVDB v4 API root.
const _apiBase = 'https://api4.thetvdb.com/v4';

/// TheTVDB aired/broadcast season type. **INVARIANT (ADR-4):** episode identity
/// is pinned to AIRED order, so `TvdbSource` requests this season type when
/// listing episodes — the aired `(season, episode)` coordinates are what
/// `WatchEvents` stores and what a backend switch reconciles by air-date. Using
/// `dvd`/`absolute` here would silently scramble watched flags. `default` is
/// TVDB's aired/broadcast order (confirmed live by `bin/api_smoke.dart`, #8).
const _airedSeasonType = 'default';

/// How long a login token is trusted before a **proactive** re-login. TheTVDB
/// tokens last ~1 month; refreshing well inside that avoids a guaranteed 401 on
/// the first call after expiry. A token that goes stale early is still caught
/// **reactively** by the 401-refresh path, so this is only an optimization.
const _tokenTtl = Duration(days: 24);

/// [MetadataSource] backed by TheTVDB v4 (ADR-1).
///
/// Unlike TMDB there is no `append_to_response`: a show resolves in **separate
/// calls** — the extended series record (metadata, genres, remote ids, the bare
/// `nextAired` date) plus the aired-order episodes list (per-season counts and
/// the real next-episode). Auth is a login-token exchange (`POST /login` with
/// the api key) cached in memory; the token is re-fetched proactively past
/// [_tokenTtl] and reactively on any 401 (re-login once, then retry).
///
/// This impl only fetches, parses, and **normalizes**. It throws
/// [MetadataException] on a non-2xx response (after the one 401 retry) and lets
/// parse errors propagate; turning `429`/`500` into a cache fallback is the SWR
/// wrapper's job (#13), so the source never silently swallows a failure.
class TvdbSource implements MetadataSource {
  TvdbSource({
    required http.Client client,
    required String apiKey,
    Clock clock = const Clock(),
  }) : _client = client,
       _apiKey = apiKey,
       _clock = clock;

  final http.Client _client;
  final String _apiKey;
  final Clock _clock;

  String? _token;
  DateTime? _tokenAt;

  // --- auth ------------------------------------------------------------------

  bool get _tokenStale {
    final at = _tokenAt;
    return at == null || _clock.now().difference(at) >= _tokenTtl;
  }

  /// A valid bearer token, logging in if the cache is empty or aged past
  /// [_tokenTtl].
  Future<String> _ensureToken() async {
    final token = _token;
    if (token != null && !_tokenStale) return token;
    return _login();
  }

  Future<String> _login() async {
    final res = await _client.post(
      Uri.parse('$_apiBase/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'apikey': _apiKey}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw MetadataException(res.statusCode, res.body);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final token = _dataOf(body)['token'] as String?;
    if (token == null || token.isEmpty) {
      throw MetadataException(res.statusCode, 'login: no token in response');
    }
    _token = token;
    _tokenAt = _clock.now();
    return token;
  }

  Map<String, String> _authHeader(String token) => {
    'Authorization': 'Bearer $token',
  };

  /// GETs [path], authing with the cached token and transparently re-logging in
  /// **once** on a 401 (the token expired between calls) before retrying — the
  /// token-refresh behaviour the live probe (#8) confirmed. Any other non-2xx
  /// throws [MetadataException] so the SWR wrapper (#13) can fall to cache.
  Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final uri = Uri.parse(
      '$_apiBase$path',
    ).replace(queryParameters: query.isEmpty ? null : query);

    var res = await _client.get(
      uri,
      headers: _authHeader(await _ensureToken()),
    );
    if (res.statusCode == 401) {
      // Cached token was rejected — re-login once and retry the same request.
      res = await _client.get(uri, headers: _authHeader(await _login()));
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw MetadataException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // --- MetadataSource --------------------------------------------------------

  @override
  Future<List<MediaSearchResult>> search(
    String query, {
    MediaKind? kind,
  }) async {
    // ponytail: page 1 only — add paging if search UX needs it.
    final json = await _getJson('/search', {
      'query': query,
      if (kind != null) 'type': _searchType(kind),
    });
    return ((json['data'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_searchResult)
        .whereType<MediaSearchResult>()
        .toList();
  }

  @override
  Future<MediaDetails> movieDetails(int sourceId) async {
    final data = _dataOf(await _getJson('/movies/$sourceId/extended'));
    return MediaDetails(
      kind: MediaKind.movie,
      tvdbId: _asInt(data['id']),
      title: data['name'] as String? ?? '',
      genres: _genres(data),
      seasons: const [],
      imdbId: _imdbFromRemoteIds(data['remoteIds']),
      year: _asInt(data['year']),
      posterPath: data['image'] as String?,
      overview: data['overview'] as String?,
      runtimeMinutes: _asInt(data['runtime']),
    );
  }

  @override
  Future<MediaDetails> showDetails(int sourceId) async {
    // TVDB has no append_to_response: the extended record carries the show's
    // metadata + a bare `nextAired` date, and a separate aired-order episodes
    // call gives per-season counts and resolves `nextAired` to a real episode.
    final data = _dataOf(await _getJson('/series/$sourceId/extended'));
    final episodes = await _airedEpisodes(sourceId);
    return MediaDetails(
      kind: MediaKind.tv,
      tvdbId: _asInt(data['id']),
      title: data['name'] as String? ?? '',
      genres: _genres(data),
      seasons: _seasonsFrom(episodes),
      imdbId: _imdbFromRemoteIds(data['remoteIds']),
      year: _asInt(data['year']),
      posterPath: data['image'] as String?,
      overview: data['overview'] as String?,
      runtimeMinutes: _asInt(data['averageRuntime']),
      showStatus: (data['status'] as Map<String, dynamic>?)?['name'] as String?,
      episodeCountTotal: episodes.length,
      nextEpisode: _nextEpisode(
        episodes,
        _parseDate(data['nextAired'] as String?),
      ),
    );
  }

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(
    int showSourceId,
    int seasonNumber,
  ) async {
    final season =
        (await _airedEpisodes(
            showSourceId,
          )).where((e) => e.seasonNumber == seasonNumber).toList()
          ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    return season;
  }

  @override
  Future<MediaSearchResult?> resolveByExternalId(
    String id, {
    ExternalIdKind kind = ExternalIdKind.imdb,
  }) async {
    // /search/remoteid resolves any remote id (IMDb, TVDB, Zap2it, …) the same
    // way, so [kind] needs no branch here — the endpoint keys on the id itself.
    final results = (await _getJson('/search/remoteid/$id'))['data'] as List?;
    for (final raw in results ?? const []) {
      final envelope = raw as Map<String, dynamic>;
      final series = envelope['series'] as Map<String, dynamic>?;
      if (series != null) return _remoteIdResult(series, MediaKind.tv, id);
      final movie = envelope['movie'] as Map<String, dynamic>?;
      if (movie != null) return _remoteIdResult(movie, MediaKind.movie, id);
    }
    return null;
  }

  @override
  // TVDB returns fully-qualified artwork URLs, so there are no size buckets to
  // apply — pass the path through and ignore [size] (per the interface doc).
  String imageUrl(String path, ImageSize size) => path;

  @override
  Attribution attribution() => const Attribution(
    // TheTVDB requires a linked metadata credit. No bundled logo yet — the UI
    // renders a linked "TheTVDB" text credit (M2).
    notice: 'Metadata provided by TheTVDB.',
    linkUrl: 'https://www.thetvdb.com/',
  );

  // --- parsing helpers -------------------------------------------------------

  /// Every TVDB v4 response wraps its payload under a top-level `data` key.
  Map<String, dynamic> _dataOf(Map<String, dynamic> body) =>
      body['data'] as Map<String, dynamic>;

  /// Fetches a show's episodes in TVDB aired order (ADR-4 INVARIANT). ponytail:
  /// page 0 only (500 episodes) — covers everything but the longest-running
  /// soaps; paginate if that ceiling is ever hit.
  Future<List<EpisodeInfo>> _airedEpisodes(int showSourceId) async {
    final json = await _getJson(
      '/series/$showSourceId/episodes/$_airedSeasonType',
    );
    final data = json['data'] as Map<String, dynamic>?;
    return ((data?['episodes'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_episode)
        .toList();
  }

  String _searchType(MediaKind kind) =>
      kind == MediaKind.movie ? 'movie' : 'series';

  /// Maps one TVDB search row. Rows that aren't a movie/series (people,
  /// companies) resolve to null and are dropped by the caller.
  MediaSearchResult? _searchResult(Map<String, dynamic> r) {
    final kind = _kindFromType(r['type'] as String?);
    if (kind == null) return null;
    return MediaSearchResult(
      kind: kind,
      tvdbId: _asInt(r['tvdb_id']),
      imdbId: _imdbFromRemoteIds(r['remote_ids']),
      title: r['name'] as String? ?? '',
      year: _asInt(r['year']),
      posterPath: r['image_url'] as String?,
      overview: r['overview'] as String?,
    );
  }

  MediaSearchResult _remoteIdResult(
    Map<String, dynamic> r,
    MediaKind kind,
    String imdbId,
  ) => MediaSearchResult(
    kind: kind,
    tvdbId: _asInt(r['id']),
    imdbId: imdbId,
    title: r['name'] as String? ?? '',
    year: _asInt(r['year']),
    posterPath: r['image'] as String?,
    overview: r['overview'] as String?,
  );

  MediaKind? _kindFromType(String? type) => switch (type) {
    'movie' => MediaKind.movie,
    'series' => MediaKind.tv,
    _ => null,
  };

  List<String> _genres(Map<String, dynamic> data) =>
      ((data['genres'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map((g) => g['name'] as String?)
          .whereType<String>()
          .toList();

  /// IMDb id (the universal join key, ADR-4) from a remote-ids list — entries
  /// are `{id, type, sourceName}`. IMDb ids uniquely start with `tt`, so match
  /// on that rather than the numeric `type`/`sourceName` which vary. The search
  /// and extended endpoints spell the key `remote_ids` vs `remoteIds`, so the
  /// caller passes the right one.
  String? _imdbFromRemoteIds(Object? remoteIds) {
    if (remoteIds is! List) return null;
    for (final raw in remoteIds) {
      if (raw is! Map) continue;
      final id = raw['id'] as String?;
      if (id != null && id.startsWith('tt')) return id;
    }
    return null;
  }

  /// Groups the aired episodes into per-season summaries — TVDB's extended
  /// `seasons` array has no episode counts, so they're derived here. Season 0
  /// (specials) is included; consumers filter if needed.
  List<SeasonInfo> _seasonsFrom(List<EpisodeInfo> episodes) {
    final counts = <int, int>{};
    for (final e in episodes) {
      counts[e.seasonNumber] = (counts[e.seasonNumber] ?? 0) + 1;
    }
    final seasons =
        counts.entries
            .map((e) => SeasonInfo(seasonNumber: e.key, episodeCount: e.value))
            .toList()
          ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    return seasons;
  }

  /// Resolves TVDB's bare `nextAired` date to the matching episode from the
  /// aired-order list, so `nextEpisode` carries real season/episode numbers.
  EpisodeInfo? _nextEpisode(List<EpisodeInfo> episodes, DateTime? nextAired) {
    if (nextAired == null) return null;
    for (final e in episodes) {
      if (e.airDate == nextAired) return e;
    }
    return null;
  }

  EpisodeInfo _episode(Map<String, dynamic> e) => EpisodeInfo(
    seasonNumber: e['seasonNumber'] as int,
    episodeNumber: e['number'] as int,
    title: e['name'] as String?,
    airDate: _parseDate(e['aired'] as String?),
    overview: e['overview'] as String?,
    runtimeMinutes: e['runtime'] as int?,
  );

  /// TVDB serializes some ids/years as strings in search rows but ints in
  /// extended records — accept either.
  int? _asInt(Object? v) => switch (v) {
    int() => v,
    String() => int.tryParse(v),
    _ => null,
  };

  DateTime? _parseDate(String? date) =>
      (date == null || date.isEmpty) ? null : DateTime.parse(date);
}
