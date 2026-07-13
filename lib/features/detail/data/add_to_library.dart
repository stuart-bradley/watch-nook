import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// **AD-3 snapshot-at-add.** Adds [result] with the chosen [status], fetching
/// full details **once** to snapshot the offline-stats fields (`genresCsv`,
/// `runtimeMinutes`, `episodeCountTotal`, `showStatus`) onto the row so stats
/// and the grid never depend on the disposable cache. Always sets the required
/// `recordedSource` (= [sourceKind]) plus the matching id column, so a later
/// backend switch can relink by `imdbId`.
///
/// If the details fetch fails (offline at add-time), it still adds the row from
/// what the search hit carries, leaving the stats fields null to backfill on
/// the next detail view (plan §7).
///
/// Returns `created: false` when the title was **already tracked** — the dedupe
/// (`findByIdentity` → `addOrGetItem`) returns that row **untouched**, so the
/// chosen [status] is NOT applied to it. The caller must not claim it added
/// anything: re-adding a title is a no-op, not a status change.
///
/// **Fetches through [repo] (the SWR cache), not the raw source** — so the add
/// leaves the title's details in `CachedMedia`. Up Next reads its queue from
/// that cache alone (`cachedShowDetails`, no network), so a show added against
/// the bare source is *invisible* on the Up Next tab until the once-a-day
/// `TrackedShowSync` happens to warm it. Warming the cache here is what makes a
/// newly added show show up in the queue immediately.
///
/// Lives in the **detail** feature: search now navigates to the detail screen
/// rather than adding on tap, so the Add button there is the only caller.
Future<({LibraryItem item, bool created})> addToLibrary({
  required CachingMetadataRepository repo,
  required MetadataSourceKind sourceKind,
  required LibraryDao dao,
  required MediaSearchResult result,
  required TrackStatus status,
}) async {
  // The id to fetch/store is this backend's own id (matches recordedSource).
  final sourceId = addSourceId(result, sourceKind);

  MediaDetails? details;
  if (sourceId != null) {
    try {
      // `.last`: the revalidated value when there's one, the cached value when
      // the cache is fresh (the detail screen we came from usually just warmed
      // it). Either way the cache write has happened by the time this returns.
      details = result.kind == MediaKind.tv
          ? await repo.showDetails(sourceId).last
          : await repo.movieDetails(sourceId).last;
    } on Object {
      // Offline / fetch error: fall back to the search-hit fields; the stats
      // fields backfill on the next detail view (plan §7). The queue picks the
      // show up once the cache warms.
      details = null;
    }
  }

  final genres = details?.genres ?? const <String>[];
  final now = clock.now();

  // Ask first, so the caller can tell an add from a no-op. `addOrGetItem` below
  // still runs the same check inside its transaction — that's the race guard;
  // this is the *report*. Both read the details-enriched ids (the `imdbId` a
  // TMDB search never carries), so they agree on what "already tracked" means.
  final existing = await dao.findByIdentity(
    mediaType: mediaTypeOf(result.kind),
    imdbId: details?.imdbId ?? result.imdbId,
    tmdbId: result.tmdbId,
    tvdbId: result.tvdbId,
    title: details?.title ?? result.title,
    year: details?.year ?? result.year,
  );
  if (existing != null) return (item: existing, created: false);

  final item = await dao.addOrGetItem(
    LibraryItemsCompanion.insert(
      mediaType: mediaTypeOf(result.kind),
      recordedSource: sourceKind,
      title: details?.title ?? result.title,
      trackStatus: status,
      addedAt: now,
      updatedAt: now,
      tmdbId: Value(result.tmdbId),
      tvdbId: Value(result.tvdbId),
      imdbId: Value(details?.imdbId ?? result.imdbId),
      year: Value(details?.year ?? result.year),
      posterPath: Value(details?.posterPath ?? result.posterPath),
      genresCsv: Value(genres.isEmpty ? null : genres.join(',')),
      runtimeMinutes: Value(details?.runtimeMinutes),
      showStatus: Value(details?.showStatus),
      episodeCountTotal: Value(details?.episodeCountTotal),
    ),
  );
  return (item: item, created: true);
}

/// The backend id to use for an **untracked** search hit — [sourceKind]'s own
/// id column, never the other backend's (the episode-identity invariant). The
/// pre-add twin of `detailSourceId`, which reads the same rule off a tracked
/// row's `recordedSource`.
///
/// INVARIANT: the detail screen previews a search hit with this id and
/// [addToLibrary] stores the row under it — they must agree, or the preview
/// shows one title's seasons and adds another's.
int? addSourceId(MediaSearchResult result, MetadataSourceKind sourceKind) =>
    switch (sourceKind) {
      MetadataSourceKind.tmdb => result.tmdbId,
      MetadataSourceKind.tvdb => result.tvdbId,
    };
