import 'package:flutter/foundation.dart';

/// Backend-neutral kind of a title. Distinct from the DB's `MediaType` (an
/// adapter maps between them) so the metadata layer never imports Drift.
enum MediaKind {
  movie,
  tv;

  /// Parses the persisted enum name. Throws `ArgumentError` (an `Error`) on an
  /// unknown value — see the `TypeError`/`Error` gotcha in CLAUDE.md; callers
  /// that parse cache payloads guard with `on Object`.
  static MediaKind fromName(String name) => MediaKind.values.byName(name);
}

/// Which external-id namespace an id belongs to, for a source's
/// `resolveByExternalId`. IMDb is universal; a **TVDB** id comes
/// from a TV Time export and maps to a TMDB title via TMDB's
/// `/find?external_source=tvdb_id` — the rung that stops TV Time shows falling
/// to fuzzy title search under the TMDB backend.
enum ExternalIdKind {
  imdb('imdb_id'),
  tvdb('tvdb_id');

  const ExternalIdKind(this.tmdbSource);

  /// The value TMDB's `/find` endpoint expects for `external_source`.
  final String tmdbSource;
}

/// Whether a freeform backend `showStatus` means the show has finished airing.
///
/// A heuristic: both providers phrase it differently ("Ended", "Canceled",
/// "Completed"). Anything unrecognised counts as **still airing** — the safe
/// default in both consumers (refresh the cache more often; keep polling for
/// upcoming episodes).
///
/// INVARIANT: this is the single reading of `showStatus`. Consumers are
/// `CachingMetadataRepository._ttl` (ADR-7 TTL tier) and the upcoming filter
/// (#21, which skips ended-`completed` shows). Add a phrasing here, not there.
bool showHasEnded(String? showStatus) {
  final s = (showStatus ?? '').toLowerCase();
  return s.contains('ended') || s.contains('cancel') || s.contains('completed');
}

/// Requested image size. The interface is size-bucketed so callers are
/// backend-agnostic: `TmdbSource` maps these to TMDB's `w185/w342/w500/original`
/// buckets; `TvdbSource` returns full URLs and ignores the size (ADR-1/ADR-7).
enum ImageSize { small, medium, large, original }

/// A search hit — the minimal shape needed to render a result row and to add a
/// title to the library. Both providers' searches normalize to this.
@immutable
class MediaSearchResult {
  const MediaSearchResult({
    required this.kind,
    required this.title,
    this.tmdbId,
    this.tvdbId,
    this.imdbId,
    this.year,
    this.posterPath,
    this.overview,
    this.originCountry = const [],
  });

  /// Round-trips through the cache `payload`. `as`-casts throw `TypeError` on a
  /// wrong-typed field (CLAUDE.md gotcha) so malformed cache is rejected, not
  /// silently coerced.
  factory MediaSearchResult.fromJson(Map<String, dynamic> json) =>
      MediaSearchResult(
        kind: MediaKind.fromName(json['kind'] as String),
        title: json['title'] as String,
        tmdbId: json['tmdbId'] as int?,
        tvdbId: json['tvdbId'] as int?,
        imdbId: json['imdbId'] as String?,
        year: json['year'] as int?,
        posterPath: json['posterPath'] as String?,
        overview: json['overview'] as String?,
        // Older cache payloads predate this field — default, don't throw.
        originCountry:
            (json['originCountry'] as List?)?.cast<String>() ?? const [],
      );

  final MediaKind kind;
  final String title;

  /// TheMovieDB id, if this hit carries one.
  final int? tmdbId;

  /// TheTVDB id, if this hit carries one.
  final int? tvdbId;

  /// IMDb id — the universal join key used to relink across backends (ADR-4).
  final String? imdbId;

  /// Release / first-air year.
  final int? year;

  /// Poster image path (backend-relative; resolve via `imageUrl`).
  final String? posterPath;
  final String? overview;

  /// ISO-3166-1 origin-country codes (e.g. `['US']`, `['JP']`). Disambiguates
  /// same-titled candidates in the import picker (multiple regional versions).
  final List<String> originCountry;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'title': title,
    'tmdbId': tmdbId,
    'tvdbId': tvdbId,
    'imdbId': imdbId,
    'year': year,
    'posterPath': posterPath,
    'overview': overview,
    'originCountry': originCountry,
  };
}

/// Full details for a movie or show — the search fields plus everything the
/// detail screen and the cache-promoted columns need (ADR-7). Flat (not
/// composed of [MediaSearchResult]) so every field serializes independently.
@immutable
class MediaDetails {
  const MediaDetails({
    required this.kind,
    required this.title,
    required this.genres,
    required this.seasons,
    this.tmdbId,
    this.tvdbId,
    this.imdbId,
    this.year,
    this.posterPath,
    this.overview,
    this.backdropPath,
    this.runtimeMinutes,
    this.showStatus,
    this.episodeCountTotal,
    this.nextEpisode,
    this.lastEpisode,
  });

  factory MediaDetails.fromJson(Map<String, dynamic> json) => MediaDetails(
    kind: MediaKind.fromName(json['kind'] as String),
    title: json['title'] as String,
    genres: (json['genres'] as List).cast<String>(),
    seasons: (json['seasons'] as List)
        .map((e) => SeasonInfo.fromJson(e as Map<String, dynamic>))
        .toList(),
    tmdbId: json['tmdbId'] as int?,
    tvdbId: json['tvdbId'] as int?,
    imdbId: json['imdbId'] as String?,
    year: json['year'] as int?,
    posterPath: json['posterPath'] as String?,
    overview: json['overview'] as String?,
    backdropPath: json['backdropPath'] as String?,
    runtimeMinutes: json['runtimeMinutes'] as int?,
    showStatus: json['showStatus'] as String?,
    episodeCountTotal: json['episodeCountTotal'] as int?,
    nextEpisode: json['nextEpisode'] == null
        ? null
        : EpisodeInfo.fromJson(json['nextEpisode'] as Map<String, dynamic>),
    lastEpisode: json['lastEpisode'] == null
        ? null
        : EpisodeInfo.fromJson(json['lastEpisode'] as Map<String, dynamic>),
  );

  final MediaKind kind;
  final String title;

  /// Snapshotted onto `LibraryItems.genresCsv` at add-time for offline stats.
  final List<String> genres;

  /// Season summaries. Empty for a movie.
  final List<SeasonInfo> seasons;

  final int? tmdbId;
  final int? tvdbId;
  final String? imdbId;
  final int? year;
  final String? posterPath;
  final String? overview;
  final String? backdropPath;

  /// Movie or per-episode runtime, if known.
  final int? runtimeMinutes;

  /// Backend show status (e.g. "Returning Series", "Ended"). Freeform.
  final String? showStatus;

  /// Total aired episodes, if known.
  final int? episodeCountTotal;

  /// The next episode to air, if the show has one scheduled.
  final EpisodeInfo? nextEpisode;

  /// The most recently aired episode (TMDB `last_episode_to_air`) — the true
  /// "has aired up to here" boundary. Unlike [nextEpisode] it stays populated
  /// between seasons, so the watch queue can tell an aired next season from a
  /// stubbed-but-unaired one (which has no scheduled [nextEpisode]).
  final EpisodeInfo? lastEpisode;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'title': title,
    'genres': genres,
    'seasons': seasons.map((s) => s.toJson()).toList(),
    'tmdbId': tmdbId,
    'tvdbId': tvdbId,
    'imdbId': imdbId,
    'year': year,
    'posterPath': posterPath,
    'overview': overview,
    'backdropPath': backdropPath,
    'runtimeMinutes': runtimeMinutes,
    'showStatus': showStatus,
    'episodeCountTotal': episodeCountTotal,
    'nextEpisode': nextEpisode?.toJson(),
    'lastEpisode': lastEpisode?.toJson(),
  };
}

/// One season's summary (count for progress; no per-episode detail).
@immutable
class SeasonInfo {
  const SeasonInfo({
    required this.seasonNumber,
    required this.episodeCount,
    this.name,
  });

  factory SeasonInfo.fromJson(Map<String, dynamic> json) => SeasonInfo(
    seasonNumber: json['seasonNumber'] as int,
    episodeCount: json['episodeCount'] as int,
    name: json['name'] as String?,
  );

  /// Aired-order season number (ADR-4). Season 0 is specials.
  final int seasonNumber;
  final int episodeCount;
  final String? name;

  Map<String, dynamic> toJson() => {
    'seasonNumber': seasonNumber,
    'episodeCount': episodeCount,
    'name': name,
  };
}

/// One episode. **Identity is pinned to AIRED order** (ADR-4): `seasonNumber`
/// and `episodeNumber` are the aired-order coordinates that `WatchEvents`
/// stores — never absolute/DVD numbering. See the episode-identity invariant.
@immutable
class EpisodeInfo {
  const EpisodeInfo({
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.airDate,
    this.overview,
    this.runtimeMinutes,
  });

  factory EpisodeInfo.fromJson(Map<String, dynamic> json) => EpisodeInfo(
    seasonNumber: json['seasonNumber'] as int,
    episodeNumber: json['episodeNumber'] as int,
    title: json['title'] as String?,
    airDate: json['airDate'] == null
        ? null
        : DateTime.parse(json['airDate'] as String),
    overview: json['overview'] as String?,
    runtimeMinutes: json['runtimeMinutes'] as int?,
  );

  final int seasonNumber;

  /// Aired-order episode number within [seasonNumber].
  final int episodeNumber;
  final String? title;
  final DateTime? airDate;
  final String? overview;
  final int? runtimeMinutes;

  Map<String, dynamic> toJson() => {
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'title': title,
    'airDate': airDate?.toIso8601String(),
    'overview': overview,
    'runtimeMinutes': runtimeMinutes,
  };
}

/// Per-source attribution. **Mandatory display** on the detail screen: TMDB
/// requires the logo + "not endorsed/certified by TMDB" notice; TheTVDB
/// requires a linked credit. M2 renders this. See the attribution rule.
@immutable
class Attribution {
  const Attribution({
    required this.notice,
    required this.linkUrl,
    this.logoAsset,
  });

  factory Attribution.fromJson(Map<String, dynamic> json) => Attribution(
    notice: json['notice'] as String,
    linkUrl: json['linkUrl'] as String,
    logoAsset: json['logoAsset'] as String?,
  );

  /// The required credit text (e.g. "This product uses the TMDB API but is not
  /// endorsed or certified by TMDB.").
  final String notice;

  /// The provider link the credit must point to.
  final String linkUrl;

  /// Bundled logo asset path, if the provider supplies one.
  final String? logoAsset;

  Map<String, dynamic> toJson() => {
    'notice': notice,
    'linkUrl': linkUrl,
    'logoAsset': logoAsset,
  };
}
