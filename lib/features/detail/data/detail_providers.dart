import 'package:flutter_riverpod/flutter_riverpod.dart';
// StreamProviderFamily lives in the misc barrel, not the main one.
import 'package:flutter_riverpod/misc.dart'
    show FutureProviderFamily, StreamProviderFamily;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/library_item_ids.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

part 'detail_providers.g.dart';

/// The tracked row behind `/title/:id`, live so the detail screen repaints when
/// a watch write recomputes the denormalized columns (#19). Plain
/// `StreamProvider` (not `@riverpod`) because it exposes a Drift-generated row
/// (CLAUDE.md convention). Emits null when the id isn't tracked.
final StreamProviderFamily<LibraryItem?, int> libraryItemProvider =
    StreamProvider.family<LibraryItem?, int>(
      (ref, id) => ref.watch(libraryDaoProvider).watchItem(id),
    );

/// Live watched aired `(season, episode)` coordinates for one tracked item —
/// the per-episode toggle's state (#19). DB-backed, so it repaints the moment a
/// watch write lands. Plain `StreamProvider` (CLAUDE.md convention: no
/// `@riverpod` over Drift-generated types, and this reads a Drift table).
final StreamProviderFamily<Set<(int, int)>, int> watchedEpisodesProvider =
    StreamProvider.family<Set<(int, int)>, int>(
      (ref, itemId) =>
          ref.watch(libraryDaoProvider).watchWatchedEpisodes(itemId),
    );

/// How the library identifies a title — as much of it as the caller knows. A
/// record, so it works as a provider family key (structural equality).
typedef TitleIdentity = ({
  MediaType mediaType,
  String? imdbId,
  int? tmdbId,
  int? tvdbId,
  String title,
  int? year,
});

/// The identity of a **search hit**, as much of it as the hit itself carries.
///
/// Note what's missing: a TMDB search result has no `imdbId` (only its details
/// do). So this is the *weak* identity — good enough for the search list's "in
/// your library" badge and its tap-time routing, but the detail screen
/// re-resolves with the details-enriched fields before it decides a title is
/// untracked. See [trackedItemProvider].
TitleIdentity identityOfHit(MediaSearchResult result) => (
  mediaType: mediaTypeOf(result.kind),
  imdbId: result.imdbId,
  tmdbId: result.tmdbId,
  tvdbId: result.tvdbId,
  title: result.title,
  year: result.year,
);

/// The tracked row for a title, if the library already has it — the preview
/// screen's "am I actually untracked?" check (US-3) and the search list's
/// "already in your library" badge.
///
/// **Cached, not live.** It answers a question about *membership*, which only
/// the add path changes while a search list is on screen — so that path
/// invalidates this family rather than every row holding a Drift subscription
/// to the whole library.
///
/// **INVARIANT: feed this the same identity the add-time dedupe gets.** Both
/// run the same `LibraryDao.findByIdentity` cascade, so if the preview is given
/// a *weaker* identity than the add is, the two disagree — the preview offers
/// "Add to library" for a title that is already tracked, and the add then
/// silently returns the existing row untouched.
///
/// Concretely: TMDB's `search` never returns an `imdbId`, only its **details**
/// do — and `imdbId` is the strongest key in the cascade, the only one that
/// matches an imdb-keyed import (Trakt / TV Time) whose title spelling or year
/// differs from the search hit. So callers pass the **details-enriched** ids,
/// which is why this is re-resolved once the details land rather than once at
/// tap time.
final FutureProviderFamily<LibraryItem?, TitleIdentity> trackedItemProvider =
    FutureProvider.family<LibraryItem?, TitleIdentity>(
      (ref, id) => ref
          .watch(libraryDaoProvider)
          .findByIdentity(
            mediaType: id.mediaType,
            imdbId: id.imdbId,
            tmdbId: id.tmdbId,
            tvdbId: id.tvdbId,
            title: id.title,
            year: id.year,
          ),
    );

/// The backend id to fetch this row's metadata with — **this row's own**
/// `recordedSource` id, never the other backend's (the episode-identity
/// invariant). Null for a row with no id for its source (offline add / import):
/// the detail screen then renders the stored row alone. Delegates to the
/// canonical [LibraryItemSourceId.sourceIdFor].
int? detailSourceId(LibraryItem item) => item.sourceIdFor(item.recordedSource);

/// Cache-first details for the detail screen (#18). Goes through
/// `metadataRepositoryProvider` (SWR), so it emits the cached value instantly
/// and a stale-cache refetch failure never blanks the screen (US-13).
@riverpod
Stream<MediaDetails> titleDetails(Ref ref, MediaType type, int sourceId) {
  final repo = ref.watch(metadataRepositoryProvider);
  return type == MediaType.movie
      ? repo.movieDetails(sourceId)
      : repo.showDetails(sourceId);
}

/// Cache-first aired-order episodes for one season (ADR-4). Watched lazily —
/// only when its season tile is expanded — so opening a 20-season show doesn't
/// fan out 20 fetches.
@riverpod
Stream<List<EpisodeInfo>> seasonEpisodes(
  Ref ref,
  int showSourceId,
  int seasonNumber,
) => ref
    .watch(metadataRepositoryProvider)
    .seasonEpisodes(
      showSourceId,
      seasonNumber,
    );
