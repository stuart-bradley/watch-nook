import 'package:flutter_riverpod/flutter_riverpod.dart';
// StreamProviderFamily lives in the misc barrel, not the main one.
import 'package:flutter_riverpod/misc.dart' show StreamProviderFamily;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
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

/// The backend id to fetch this row's metadata with — **this row's own**
/// `recordedSource` id, never the other backend's (the episode-identity
/// invariant). Null for a row with no id for its source (offline add / import):
/// the detail screen then renders the stored row alone.
int? detailSourceId(LibraryItem item) => switch (item.recordedSource) {
  MetadataSourceKind.tmdb => item.tmdbId,
  MetadataSourceKind.tvdb => item.tvdbId,
};

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
