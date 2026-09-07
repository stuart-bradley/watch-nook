import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/library_identity.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';

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
  required CachingMetadataSource repo,
  required MetadataSourceKind sourceKind,
  required LibraryDao dao,
  required MediaSearchResult result,
  required TrackStatus status,
}) async {
  // The reference to fetch/store under: this backend's own id, paired with
  // this backend (so it matches the row's `recordedSource`).
  final target = result.refFor(sourceKind);

  MediaDetails? details;
  if (target != null) {
    try {
      // The plain interface call: freshest available, cache preserved when a
      // revalidation fails. Losing the cached value to a 404-on-refresh would
      // silently drop the AD-3 snapshot and write the row from the thin
      // search-hit fields instead — which is why the cache, not this caller,
      // owns that rule now.
      details = result.kind == MediaKind.tv
          ? await repo.showDetails(target)
          : await repo.movieDetails(target);
    } on Object catch (e, s) {
      // Offline / hard failure with nothing cached: fall back to the search-hit
      // fields; the stats fields backfill on the next detail view (plan §7) and
      // the queue picks the show up once the cache warms.
      //
      // Degrading silently is right for the user, but it must not be silent to
      // US: this swallow absorbs the whole metadata fetch, so a malformed
      // payload lands here and `_addTitle`'s own catch never sees it. Logging
      // is the only reason a #79-class parse failure on the add path is
      // findable at all.
      debugPrint('wn-error: add-to-library details fetch failed: $e\n$s');
    }
  }

  final genres = details?.genres ?? const <String>[];
  final now = clock.now();

  // ONE identity, built by the shared [identityOf] — the same record the
  // membership check uses, so the screen and the dedupe can't disagree about
  // whether this title is already tracked.
  final id = identityOf(result, details);

  // `addOrGetItem` reports created-vs-deduped from **inside** its transaction —
  // the only place that can answer it without racing the insert.
  return dao.addOrGetItem(
    LibraryItemsCompanion.insert(
      mediaType: id.mediaType,
      recordedSource: sourceKind,
      title: id.title,
      trackStatus: status,
      addedAt: now,
      updatedAt: now,
      tmdbId: Value(id.tmdbId),
      tvdbId: Value(id.tvdbId),
      imdbId: Value(id.imdbId),
      year: Value(id.year),
      posterPath: Value(details?.posterPath ?? result.posterPath),
      genresCsv: Value(genres.isEmpty ? null : genres.join(',')),
      runtimeMinutes: Value(details?.runtimeMinutes),
      showStatus: Value(details?.showStatus),
      episodeCountTotal: Value(details?.episodeCountTotal),
    ),
  );
}
