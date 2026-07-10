import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// TheMovieDB v3 API root.
const _apiBase = 'https://api.themoviedb.org/3';

/// TMDB image CDN root. `imageUrl` inserts a size bucket between this and the
/// backend-relative poster/backdrop path.
const _imageBase = 'https://image.tmdb.org/t/p';

/// [MetadataSource] backed by TheMovieDB v3 (ADR-1).
///
/// Detail calls inline `append_to_response` so a show or movie resolves in a
/// single round-trip (external ids + next-episode for shows). TMDB is
/// aired-order native, so `seasonEpisodes` needs no season-type param —
/// unlike TVDB (ADR-4 episode-identity invariant).
///
/// Auth defaults to the v3 `api_key` query param; passing a v4 read token
/// switches to `Authorization: Bearer` (TMDB rate-limits per IP not per key,
/// so the shared embedded key is fine — see #8).
///
/// This impl only fetches, parses, and **normalizes**. It throws
/// [MetadataException] on a non-2xx response and lets parse errors propagate;
/// turning `429`/`500` into a cache fallback is the SWR wrapper's job (#13),
/// so the source never silently swallows a failure.
class TmdbSource implements MetadataSource {
  TmdbSource({
    required http.Client client,
    required String apiKey,
    String readToken = '',
  }) : _client = client,
       _apiKey = apiKey,
       _readToken = readToken,
       // Only fall back to the v4 Bearer token when no v3 key is configured.
       _useV4 = apiKey.isEmpty && readToken.isNotEmpty;

  final http.Client _client;
  final String _apiKey;
  final String _readToken;
  final bool _useV4;

  Map<String, String>? get _authHeaders =>
      _useV4 ? {'Authorization': 'Bearer $_readToken'} : null;

  Uri _uri(String path, [Map<String, String> query = const {}]) =>
      Uri.parse('$_apiBase$path').replace(
        queryParameters: {
          if (!_useV4) 'api_key': _apiKey,
          ...query,
        },
      );

  Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final res = await _client.get(_uri(path, query), headers: _authHeaders);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw MetadataException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @override
  Future<List<MediaSearchResult>> search(
    String query, {
    MediaKind? kind,
  }) async {
    // ponytail: page 1 only — add paging if search UX needs it.
    final path = switch (kind) {
      MediaKind.movie => '/search/movie',
      MediaKind.tv => '/search/tv',
      null => '/search/multi',
    };
    final json = await _getJson(path, {'query': query});
    final results = (json['results'] as List?) ?? const [];
    return results
        .cast<Map<String, dynamic>>()
        .map((r) => _searchResult(r, kind))
        .whereType<MediaSearchResult>()
        .toList();
  }

  /// Maps one TMDB search row. For `/search/multi` [narrowed] is null, so the
  /// row's own `media_type` picks the kind — `person` rows resolve to null and
  /// are filtered out by the caller.
  MediaSearchResult? _searchResult(
    Map<String, dynamic> r,
    MediaKind? narrowed,
  ) {
    final kind = narrowed ?? _kindFromMediaType(r['media_type'] as String?);
    if (kind == null) return null;
    final isTv = kind == MediaKind.tv;
    return MediaSearchResult(
      kind: kind,
      tmdbId: r['id'] as int?,
      title: (isTv ? r['name'] : r['title']) as String? ?? '',
      year: _year((isTv ? r['first_air_date'] : r['release_date']) as String?),
      posterPath: r['poster_path'] as String?,
      overview: r['overview'] as String?,
      originCountry: _originCountry(r),
    );
  }

  /// TV rows carry `origin_country` (a code array); movie rows don't, so this
  /// is empty for films. Disambiguates same-titled shows in the import picker.
  List<String> _originCountry(Map<String, dynamic> r) =>
      ((r['origin_country'] as List?) ?? const []).whereType<String>().toList();

  MediaKind? _kindFromMediaType(String? mediaType) => switch (mediaType) {
    'movie' => MediaKind.movie,
    'tv' => MediaKind.tv,
    _ => null,
  };

  @override
  Future<MediaDetails> movieDetails(int sourceId) async {
    final json = await _getJson('/movie/$sourceId', {
      'append_to_response': 'external_ids',
    });
    return MediaDetails(
      kind: MediaKind.movie,
      tmdbId: json['id'] as int?,
      title: json['title'] as String? ?? '',
      genres: _genres(json),
      seasons: const [],
      imdbId: _imdbId(json),
      year: _year(json['release_date'] as String?),
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      overview: json['overview'] as String?,
      runtimeMinutes: json['runtime'] as int?,
    );
  }

  @override
  Future<MediaDetails> showDetails(int sourceId) async {
    final json = await _getJson('/tv/$sourceId', {
      'append_to_response': 'external_ids,next_episode_to_air',
    });
    final next = json['next_episode_to_air'] as Map<String, dynamic>?;
    return MediaDetails(
      kind: MediaKind.tv,
      tmdbId: json['id'] as int?,
      title: json['name'] as String? ?? '',
      genres: _genres(json),
      seasons: ((json['seasons'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(_season)
          .toList(),
      imdbId: _imdbId(json),
      year: _year(json['first_air_date'] as String?),
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      overview: json['overview'] as String?,
      runtimeMinutes: _firstRuntime(json['episode_run_time']),
      showStatus: json['status'] as String?,
      episodeCountTotal: json['number_of_episodes'] as int?,
      nextEpisode: next == null ? null : _episode(next),
    );
  }

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(
    int showSourceId,
    int seasonNumber,
  ) async {
    // TMDB returns a season's episodes in aired order natively (ADR-4) — no
    // season-type parameter, unlike TVDB.
    final json = await _getJson('/tv/$showSourceId/season/$seasonNumber');
    return ((json['episodes'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_episode)
        .toList();
  }

  @override
  Future<List<UpcomingEpisode>> upcomingForTracked(
    List<int> showSourceIds,
  ) async {
    // TMDB exposes a single `next_episode_to_air` per show, so upcoming is just
    // each tracked show's next dated episode.
    // ponytail: sequential per-show detail calls; the SWR cache (#13) fronts
    // this and tracked-show counts are small — batch only if it ever bites.
    final upcoming = <UpcomingEpisode>[];
    for (final id in showSourceIds) {
      final details = await showDetails(id);
      final next = details.nextEpisode;
      final airDate = next?.airDate;
      if (next == null || airDate == null) continue;
      upcoming.add(
        UpcomingEpisode(
          episode: next,
          airDate: airDate,
          tmdbId: details.tmdbId,
          imdbId: details.imdbId,
        ),
      );
    }
    return upcoming;
  }

  @override
  Future<MediaSearchResult?> resolveByExternalId(
    String id, {
    ExternalIdKind kind = ExternalIdKind.imdb,
  }) async {
    final json = await _getJson('/find/$id', {
      'external_source': kind.tmdbSource,
    });
    final tv = (json['tv_results'] as List?) ?? const [];
    if (tv.isNotEmpty) {
      return _findResult(
        tv.first as Map<String, dynamic>,
        MediaKind.tv,
        id,
        kind,
      );
    }
    final movie = (json['movie_results'] as List?) ?? const [];
    if (movie.isNotEmpty) {
      return _findResult(
        movie.first as Map<String, dynamic>,
        MediaKind.movie,
        id,
        kind,
      );
    }
    return null;
  }

  /// Stamps the queried external id back onto the hit under the *right* field —
  /// an IMDb lookup sets `imdbId`, a TVDB lookup sets `tvdbId` — so a TV Time
  /// import keeps a stable link and never re-derives it as an IMDb id.
  MediaSearchResult _findResult(
    Map<String, dynamic> r,
    MediaKind kind,
    String externalId,
    ExternalIdKind idKind,
  ) {
    final isTv = kind == MediaKind.tv;
    return MediaSearchResult(
      kind: kind,
      tmdbId: r['id'] as int?,
      imdbId: idKind == ExternalIdKind.imdb ? externalId : null,
      tvdbId: idKind == ExternalIdKind.tvdb ? int.tryParse(externalId) : null,
      title: (isTv ? r['name'] : r['title']) as String? ?? '',
      year: _year((isTv ? r['first_air_date'] : r['release_date']) as String?),
      posterPath: r['poster_path'] as String?,
      overview: r['overview'] as String?,
      originCountry: _originCountry(r),
    );
  }

  @override
  String imageUrl(String path, ImageSize size) =>
      '$_imageBase/${_bucket(size)}$path';

  String _bucket(ImageSize size) => switch (size) {
    ImageSize.small => 'w185',
    ImageSize.medium => 'w342',
    ImageSize.large => 'w500',
    ImageSize.original => 'original',
  };

  @override
  Attribution attribution() => const Attribution(
    // TMDB terms require this EXACT notice (verbatim) AND the logo — do not
    // paraphrase or drop either (issue #53 / attribution invariant / TMDB API
    // terms). The logo is the official primary-short wordmark.
    notice:
        'This product uses TMDB and the TMDB APIs but is not endorsed, '
        'certified, or otherwise approved by TMDB.',
    linkUrl: 'https://www.themoviedb.org/',
    logoAsset: 'assets/branding/tmdb_logo.png',
  );

  // --- parsing helpers -------------------------------------------------------

  List<String> _genres(Map<String, dynamic> json) =>
      ((json['genres'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map((g) => g['name'] as String?)
          .whereType<String>()
          .toList();

  /// IMDb id from the inlined `external_ids` (shows/movies) or the top-level
  /// `imdb_id` (movies expose it directly). Empty strings normalize to null.
  String? _imdbId(Map<String, dynamic> json) {
    final ext = json['external_ids'] as Map<String, dynamic>?;
    final id = (ext?['imdb_id'] as String?) ?? (json['imdb_id'] as String?);
    return (id == null || id.isEmpty) ? null : id;
  }

  /// TMDB gives TV runtime as an `episode_run_time` list; take the first.
  int? _firstRuntime(Object? runtimes) =>
      (runtimes is List && runtimes.isNotEmpty) ? runtimes.first as int? : null;

  int? _year(String? date) => (date == null || date.length < 4)
      ? null
      : int.tryParse(date.substring(0, 4));

  SeasonInfo _season(Map<String, dynamic> s) => SeasonInfo(
    seasonNumber: s['season_number'] as int,
    episodeCount: s['episode_count'] as int,
    name: s['name'] as String?,
  );

  EpisodeInfo _episode(Map<String, dynamic> e) {
    final air = e['air_date'] as String?;
    return EpisodeInfo(
      seasonNumber: e['season_number'] as int,
      episodeNumber: e['episode_number'] as int,
      title: e['name'] as String?,
      airDate: (air == null || air.isEmpty) ? null : DateTime.parse(air),
      overview: e['overview'] as String?,
      runtimeMinutes: e['runtime'] as int?,
    );
  }
}
