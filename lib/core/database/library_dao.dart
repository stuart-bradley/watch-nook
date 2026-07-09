import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

part 'library_dao.g.dart';

/// Data access for [LibraryItems] (+ read of its [WatchEvents]) and the
/// denormalized-progress maintenance the whole M2 grid relies on.
///
/// **Denormalized maintenance is one function** ([recomputeDenormalized],
/// AD-4): `watchedCount` and `lastWatched*` are derived from [WatchEvents] and
/// rewritten after every watch write (#19/#20 call it inside their
/// transactions). The grid then reads only those columns — **no cross-domain
/// join per card** (the #15 acceptance). See the "watched = idempotent toggle"
/// invariant in CLAUDE.md: `watchedCount` counts **non-rewatch** rows only; a
/// rewatch never inflates it or moves `lastWatched*`.
@DriftAccessor(tables: [LibraryItems, WatchEvents])
class LibraryDao extends DatabaseAccessor<AppDatabase> with _$LibraryDaoMixin {
  /// Creates a [LibraryDao].
  LibraryDao(super.attachedDatabase);

  // --- reads ---------------------------------------------------------------

  /// Get every library item.
  Future<List<LibraryItem>> getAll() => select(libraryItems).get();

  /// Watch every library item (repaints on any write).
  Stream<List<LibraryItem>> watchAll() => select(libraryItems).watch();

  /// One item by id, or null.
  Future<LibraryItem?> getItem(int id) =>
      (select(libraryItems)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Watch one item by id — the detail screen's live row, so it repaints when a
  /// watch write recomputes the denormalized columns (#19) or the rating
  /// changes. Emits null once the item is deleted.
  Stream<LibraryItem?> watchItem(int id) =>
      (select(libraryItems)..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// The library grid stream, optionally narrowed to a [status] and/or [type].
  /// Filters on the indexed denormalized columns and repaints on any write.
  /// Most-recently-updated first so freshly-touched titles surface at the top.
  Stream<List<LibraryItem>> watchLibrary({
    TrackStatus? status,
    MediaType? type,
  }) {
    final query = select(libraryItems);
    if (status != null) {
      query.where((t) => t.trackStatus.equalsValue(status));
    }
    if (type != null) {
      query.where((t) => t.mediaType.equalsValue(type));
    }
    query.orderBy([
      (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
    ]);
    return query.watch();
  }

  /// Find an existing row that is the **same title**, for add-dedupe. Cascades
  /// from the strongest identity to the weakest: `imdbId` (universal
  /// key) → `(mediaType, tmdbId)` → `(mediaType, tvdbId)` → `(mediaType, title,
  /// year)`. Same tmdb/tvdb id under a **different** `mediaType` is NOT a match
  /// (a movie and a show can share an id across catalogues).
  Future<LibraryItem?> findByIdentity({
    required MediaType mediaType,
    String? imdbId,
    int? tmdbId,
    int? tvdbId,
    String? title,
    int? year,
  }) async {
    if (imdbId != null) {
      final hit = await (select(
        libraryItems,
      )..where((t) => t.imdbId.equals(imdbId))).getSingleOrNull();
      if (hit != null) return hit;
    }
    if (tmdbId != null) {
      final hit =
          await (select(libraryItems)..where(
                (t) =>
                    t.mediaType.equalsValue(mediaType) &
                    t.tmdbId.equals(tmdbId),
              ))
              .getSingleOrNull();
      if (hit != null) return hit;
    }
    if (tvdbId != null) {
      final hit =
          await (select(libraryItems)..where(
                (t) =>
                    t.mediaType.equalsValue(mediaType) &
                    t.tvdbId.equals(tvdbId),
              ))
              .getSingleOrNull();
      if (hit != null) return hit;
    }
    if (title != null) {
      // Weakest match — no unique index, so take the first if several collide.
      final hits =
          await (select(libraryItems)..where(
                (t) =>
                    t.mediaType.equalsValue(mediaType) &
                    t.title.equals(title) &
                    (year == null ? t.year.isNull() : t.year.equals(year)),
              ))
              .get();
      return hits.firstOrNull;
    }
    return null;
  }

  /// Every [WatchEvents] row for one item — the backend-switch reconciliation
  /// (#14) reads these to check watched coordinates line up on the new backend.
  Future<List<WatchEvent>> watchEventsFor(int libraryItemId) => (select(
    watchEvents,
  )..where((t) => t.libraryItemId.equals(libraryItemId))).get();

  /// Live set of **watched** aired `(season, episode)` coordinates for one item
  /// — the detail screen's per-episode toggle state (#19). Rewatch rows are
  /// excluded (they're extra viewings of an already-watched episode, not a
  /// separate watched marker), as are a movie's null coordinates — a movie's
  /// watched-ness is `LibraryItems.watchedCount`.
  Stream<Set<(int, int)>> watchWatchedEpisodes(int libraryItemId) =>
      (select(watchEvents)..where(
            (t) =>
                t.libraryItemId.equals(libraryItemId) &
                t.isRewatch.equals(false) &
                t.seasonNumber.isNotNull() &
                t.episodeNumber.isNotNull(),
          ))
          .watch()
          .map(
            (rows) => {
              for (final r in rows) (r.seasonNumber!, r.episodeNumber!),
            },
          );

  // --- writes --------------------------------------------------------------

  /// Insert a library item, returning the generated id. Low-level — most
  /// callers want [addOrGetItem], which dedupes.
  Future<int> insertItem(LibraryItemsCompanion entry) =>
      into(libraryItems).insert(entry);

  /// Add [entry], or return the existing row if the same title is already
  /// tracked ([findByIdentity]) — the add flow's dedupe (#16 acceptance:
  /// re-adding must not duplicate). Runs in one transaction so the
  /// find-then-insert can't race a duplicate in.
  Future<LibraryItem> addOrGetItem(LibraryItemsCompanion entry) =>
      transaction(() async {
        final existing = await findByIdentity(
          mediaType: entry.mediaType.value,
          imdbId: entry.imdbId.present ? entry.imdbId.value : null,
          tmdbId: entry.tmdbId.present ? entry.tmdbId.value : null,
          tvdbId: entry.tvdbId.present ? entry.tvdbId.value : null,
          title: entry.title.present ? entry.title.value : null,
          year: entry.year.present ? entry.year.value : null,
        );
        if (existing != null) return existing;
        final id = await into(libraryItems).insert(entry);
        return (select(
          libraryItems,
        )..where((t) => t.id.equals(id))).getSingle();
      });

  /// Patch one item by id. Used by the backend-switch service to relink ids /
  /// set `relinkFailed` without rewriting the whole row.
  Future<void> updateItem(int id, LibraryItemsCompanion patch) =>
      (update(libraryItems)..where((t) => t.id.equals(id))).write(patch);

  /// Change the tracking status, stamping [now] onto `updatedAt`.
  Future<void> updateStatus(
    int id,
    TrackStatus status, {
    required DateTime now,
  }) => (update(libraryItems)..where((t) => t.id.equals(id))).write(
    LibraryItemsCompanion(
      trackStatus: Value(status),
      updatedAt: Value(now),
    ),
  );

  /// Set (or clear, with null) the user rating. Stamps `ratedAt`/`updatedAt`
  /// with [now]; clearing the rating clears `ratedAt` too.
  Future<void> updateRating(int id, int? rating, {required DateTime now}) =>
      (update(libraryItems)..where((t) => t.id.equals(id))).write(
        LibraryItemsCompanion(
          rating: Value(rating),
          ratedAt: Value(rating == null ? null : now),
          updatedAt: Value(now),
        ),
      );

  /// Delete an item; its [WatchEvents] cascade away (foreign_keys = ON).
  Future<void> deleteItem(int id) =>
      (delete(libraryItems)..where((t) => t.id.equals(id))).go();

  // --- watch writes (#19) --------------------------------------------------
  //
  // The three legal mutations of watched state. Each runs in one transaction
  // and ends in [recomputeDenormalized] (AD-4), so no caller has to reason
  // about which writes may skip it. See the "watched = idempotent toggle"
  // invariant in CLAUDE.md. A movie passes null [season]/[episode].

  /// **Mark watched** — ensures exactly **one** non-rewatch row for
  /// `(itemId, season, episode)`. A double-tap is a no-op, so a retry, a bulk
  /// re-run (#20) and a re-import all converge on the same single marker.
  ///
  /// [runtimeMinutes] is snapshotted onto the row at mark-time: stats read
  /// these facts and must never depend on the disposable cache (CLAUDE.md).
  Future<void> markWatched(
    int itemId, {
    int? season,
    int? episode,
    DateTime? watchedAt,
    int? runtimeMinutes,
  }) => transaction(() async {
    final already =
        await (select(watchEvents)..where(
              (t) =>
                  _sameEpisode(t, itemId, season, episode) & t.isRewatch.not(),
            ))
            .get();
    if (already.isNotEmpty) return; // idempotent — already watched.

    await into(watchEvents).insert(
      WatchEventsCompanion.insert(
        libraryItemId: itemId,
        seasonNumber: Value(season),
        episodeNumber: Value(episode),
        watchedAt: Value(watchedAt),
        runtimeMinutes: Value(runtimeMinutes),
      ),
    );
    await recomputeDenormalized(itemId);
  });

  /// **Log a rewatch** — *appends* an `isRewatch = true` row. The first watch's
  /// date survives, and `watchedCount`/`lastWatched*` are unmoved (they count
  /// non-rewatch rows only), so logging a rewatch of a *later* episode than
  /// you've reached never fakes progress.
  Future<void> logRewatch(
    int itemId, {
    int? season,
    int? episode,
    DateTime? watchedAt,
    int? runtimeMinutes,
  }) => transaction(() async {
    await into(watchEvents).insert(
      WatchEventsCompanion.insert(
        libraryItemId: itemId,
        seasonNumber: Value(season),
        episodeNumber: Value(episode),
        watchedAt: Value(watchedAt),
        runtimeMinutes: Value(runtimeMinutes),
        isRewatch: const Value(true),
      ),
    );
    await recomputeDenormalized(itemId);
  });

  /// **Unwatch** — deletes **all** rows for `(itemId, season, episode)`,
  /// rewatches included. Un-marking an episode can't leave orphan rewatches of
  /// an episode the user says they never watched.
  Future<void> unwatch(int itemId, {int? season, int? episode}) =>
      transaction(() async {
        await (delete(
          watchEvents,
        )..where((t) => _sameEpisode(t, itemId, season, episode))).go();
        await recomputeDenormalized(itemId);
      });

  /// Matches one item's rows at one aired coordinate. A movie's null
  /// season/episode needs `IS NULL`, not `= NULL` (which matches nothing in
  /// SQLite) — so a movie's rows would silently never be found.
  Expression<bool> _sameEpisode(
    $WatchEventsTable t,
    int itemId,
    int? season,
    int? episode,
  ) =>
      t.libraryItemId.equals(itemId) &
      (season == null
          ? t.seasonNumber.isNull()
          : t.seasonNumber.equals(season)) &
      (episode == null
          ? t.episodeNumber.isNull()
          : t.episodeNumber.equals(episode));

  /// **Recompute the denormalized progress columns** from [WatchEvents] (AD-4).
  /// The single source of truth: `watchedCount` = number of **non-rewatch**
  /// rows; `lastWatched(Season|Episode)` = the max aired `(season, episode)`
  /// coordinate among non-rewatch rows (null for a movie or an empty history).
  /// Called in the same transaction after each watch write; grid stays
  /// join-free.
  Future<void> recomputeDenormalized(int itemId) async {
    final watched =
        await (select(watchEvents)..where(
              (t) => t.libraryItemId.equals(itemId) & t.isRewatch.equals(false),
            ))
            .get();

    int? lastSeason;
    int? lastEpisode;
    for (final e in watched) {
      final s = e.seasonNumber;
      final ep = e.episodeNumber;
      if (s == null || ep == null) continue; // movie / no coordinate
      if (lastSeason == null ||
          s > lastSeason ||
          (s == lastSeason && ep > lastEpisode!)) {
        lastSeason = s;
        lastEpisode = ep;
      }
    }

    await (update(libraryItems)..where((t) => t.id.equals(itemId))).write(
      LibraryItemsCompanion(
        watchedCount: Value(watched.length),
        lastWatchedSeason: Value(lastSeason),
        lastWatchedEpisode: Value(lastEpisode),
      ),
    );
  }
}
