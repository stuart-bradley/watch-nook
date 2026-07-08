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
  BoolColumn get relinkFailed =>
      boolean().withDefault(const Constant(false))();
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
