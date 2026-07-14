import 'package:drift/drift.dart';

/// Whether a library entry is a movie or a TV show. Stored as the enum name
/// (textEnum). A movie has no `WatchEvents` season/episode; a TV show does.
enum MediaType {
  /// A film — a single watchable unit (no seasons/episodes).
  movie,

  /// A TV show — tracked by aired-order season/episode.
  tv,
}

/// Which metadata backend a library row was recorded against. Stored as the
/// enum name (textEnum). Pinned per-row (`recordedSource`) so a later backend
/// switch can relink by `imdbId` and reconcile by air-date without silently
/// scrambling watched flags. See the "episode identity" invariant in CLAUDE.md.
enum MetadataSourceKind {
  /// TheMovieDB.
  tmdb,

  /// TheTVDB.
  tvdb,
}

/// The user's tracking status for a title. Stored as the enum name (textEnum).
enum TrackStatus {
  /// Wants to watch — not started.
  watchlist,

  /// Currently watching.
  watching,

  /// Finished the whole thing.
  completed,

  /// Paused.
  onHold,

  /// Abandoned.
  dropped,
}

/// A tracked title the user owns. **User-owned domain** (ADR-3): exported and
/// auto-backed-up, never in the disposable cache. Denormalized progress fields
/// (`watchedCount`, `lastWatched*`) exist at v1 but their maintenance logic
/// lands with the watched-semantics issues (#15/#19/#20) — see CLAUDE.md.
@TableIndex(name: 'library_items_track_status', columns: {#trackStatus})
@TableIndex(
  name: 'library_items_media_tmdb',
  columns: {#mediaType, #tmdbId},
  unique: true,
)
@TableIndex(
  name: 'library_items_media_tvdb',
  columns: {#mediaType, #tvdbId},
  unique: true,
)
@TableIndex(name: 'library_items_imdb', columns: {#imdbId}, unique: true)
class LibraryItems extends Table {
  /// Surrogate primary key.
  IntColumn get id => integer().autoIncrement()();

  /// Movie or TV show.
  TextColumn get mediaType => textEnum<MediaType>()();

  /// TheMovieDB id, if known. Unique per `mediaType` (NULLs are distinct in
  /// SQLite, so untitled/manual entries don't collide).
  IntColumn get tmdbId => integer().nullable()();

  /// TheTVDB id, if known. Unique per `mediaType`.
  IntColumn get tvdbId => integer().nullable()();

  /// IMDb id (universal join key for backend relinking). Unique.
  TextColumn get imdbId => text().nullable()();

  /// The backend this row's ids were recorded against.
  TextColumn get recordedSource => textEnum<MetadataSourceKind>()();

  /// Display title.
  TextColumn get title => text()();

  /// Release / first-air year.
  IntColumn get year => integer().nullable()();

  /// Poster image path (backend-relative).
  TextColumn get posterPath => text().nullable()();

  /// Comma-separated genres, snapshotted at add-time for offline stats.
  TextColumn get genresCsv => text().nullable()();

  /// Runtime minutes, snapshotted at add-time for offline stats.
  IntColumn get runtimeMinutes => integer().nullable()();

  /// The user's tracking status.
  TextColumn get trackStatus => textEnum<TrackStatus>()();

  /// Backend show status (e.g. "Returning Series", "Ended"). Freeform.
  TextColumn get showStatus => text().nullable()();

  /// Total aired episodes, if known (for progress display).
  IntColumn get episodeCountTotal => integer().nullable()();

  /// Denormalized count of watched (non-rewatch) episodes/movie. Maintained on
  /// every watch write so the library grid never does a cross-domain join.
  IntColumn get watchedCount => integer().withDefault(const Constant(0))();

  /// Season of the most recently watched episode.
  IntColumn get lastWatchedSeason => integer().nullable()();

  /// Episode number of the most recently watched episode.
  IntColumn get lastWatchedEpisode => integer().nullable()();

  /// User rating, 0–10.
  IntColumn get rating => integer().nullable()();

  /// When the rating was set.
  DateTimeColumn get ratedAt => dateTime().nullable()();

  /// When the item was added to the library.
  DateTimeColumn get addedAt => dateTime()();

  /// When the item was last modified.
  DateTimeColumn get updatedAt => dateTime()();

  /// Set true when a backend relink hits an anomaly (absolute-numbered/anime,
  /// specials) and episodes could not be safely reconciled by air-date.
  BoolColumn get relinkFailed => boolean().withDefault(const Constant(false))();
}

/// A single watched (or rewatched) record. **User-owned domain**. One
/// non-rewatch row per `(item, season, episode)` is the idempotent "watched"
/// marker; `isRewatch = true` rows append a rewatch. See the watched-semantics
/// invariant in CLAUDE.md (#19 lands the maintenance logic).
@TableIndex(
  name: 'watch_events_item_season_episode',
  columns: {#libraryItemId, #seasonNumber, #episodeNumber},
)
@TableIndex(name: 'watch_events_watched_at', columns: {#watchedAt})
class WatchEvents extends Table {
  /// Surrogate primary key.
  IntColumn get id => integer().autoIncrement()();

  /// The library item this event belongs to. Cascades on delete.
  IntColumn get libraryItemId =>
      integer().references(LibraryItems, #id, onDelete: KeyAction.cascade)();

  /// Aired-order season number. Null for a movie.
  IntColumn get seasonNumber => integer().nullable()();

  /// Aired-order episode number. Null for a movie.
  IntColumn get episodeNumber => integer().nullable()();

  /// When it was watched. Null = watched, date unknown.
  DateTimeColumn get watchedAt => dateTime().nullable()();

  /// Runtime minutes, snapshotted at mark-time for offline stats.
  IntColumn get runtimeMinutes => integer().nullable()();

  /// True for a logged rewatch (appended); false for the first watch.
  BoolColumn get isRewatch => boolean().withDefault(const Constant(false))();
}

// ---------------------------------------------------------------------------
// CACHE DOMAIN (ADR-3/ADR-7) — landed at schema v2 (#13).
//
// INVARIANT: these two tables are **disposable**. They are re-fetchable from
// the metadata API and are NEVER exported or auto-backed-up (`ExportData` reads
// only the user-owned tables above — see the "two data domains" invariant in
// CLAUDE.md). Wiping them loses nothing the user owns. Keep it that way: do not
// join user data into them, and do not add either to any export/backup path.
// ---------------------------------------------------------------------------

/// Stale-while-revalidate cache of one movie/show's normalized details. The
/// full `MediaDetails` JSON lives in [payload] (round-tripped for the detail
/// screen); the promoted columns duplicate the few fields list/grid queries
/// need so they never have to decode JSON per row (ADR-7).
///
/// Identity is the backend's own id: `(source, mediaType, sourceId)` — a title
/// recorded against TMDB and the same title against TVDB are distinct cache
/// rows (different ids), joined only by [imdbId] on a backend switch.
class CachedMedia extends Table {
  /// Which backend this row was fetched from.
  TextColumn get source => textEnum<MetadataSourceKind>()();

  /// Movie or TV show.
  TextColumn get mediaType => textEnum<MediaType>()();

  /// The backend's own id for this title (TMDB id or TVDB id per [source]).
  IntColumn get sourceId => integer()();

  /// IMDb id (universal join key), if the backend supplied one.
  TextColumn get imdbId => text().nullable()();

  /// Raw `MediaDetails.toJson()` — the source of truth the detail screen
  /// deserializes. The promoted columns below are derived from this at write.
  TextColumn get payload => text()();

  /// When this row was fetched — the SWR TTL clock reads this (ADR-7).
  DateTimeColumn get fetchedAt => dateTime()();

  // Promoted (denormalized) fields — cheap list/grid reads without decoding
  // [payload]. Populated from [MediaDetails] on every upsert.
  TextColumn get title => text()();
  IntColumn get year => integer().nullable()();
  TextColumn get posterPath => text().nullable()();
  TextColumn get backdropPath => text().nullable()();
  TextColumn get overview => text().nullable()();
  TextColumn get showStatus => text().nullable()();

  /// Next episode's air date (promoted from `nextEpisode.airDate`).
  ///
  /// Currently **written but never read**. It was promoted so the Upcoming
  /// list could read it without decoding [payload], but a row there also needs
  /// the season, episode and title — which are not promoted — so Upcoming
  /// decodes the payload it already has in hand (see `upcomingFor`). Kept
  /// because it costs nothing and a date-only query may still want it; do not
  /// trust it as a source of truth without checking who reads it.
  DateTimeColumn get nextAirDate => dateTime().nullable()();
  IntColumn get runtimeMinutes => integer().nullable()();
  TextColumn get genresCsv => text().nullable()();

  @override
  Set<Column> get primaryKey => {source, mediaType, sourceId};
}

/// Stale-while-revalidate cache of a show's **aired-order** episodes (ADR-4).
/// Keyed by the backend's own show id + aired `(season, episode)` — the same
/// coordinates `WatchEvents` stores, so a cached episode lines up with its
/// watched marker without translation.
@TableIndex(name: 'cached_episodes_show', columns: {#source, #showSourceId})
class CachedEpisodes extends Table {
  /// Which backend this row was fetched from.
  TextColumn get source => textEnum<MetadataSourceKind>()();

  /// The backend's own show id.
  IntColumn get showSourceId => integer()();

  /// Aired-order season number (ADR-4). Season 0 is specials.
  IntColumn get seasonNumber => integer()();

  /// Aired-order episode number within the season.
  IntColumn get episodeNumber => integer()();

  TextColumn get title => text().nullable()();
  DateTimeColumn get airDate => dateTime().nullable()();
  TextColumn get overview => text().nullable()();
  IntColumn get runtimeMinutes => integer().nullable()();

  /// When this row was fetched — the SWR TTL clock reads this (ADR-7).
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {
    source,
    showSourceId,
    seasonNumber,
    episodeNumber,
  };
}
