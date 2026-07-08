import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

part 'search_providers.g.dart';

/// Live search results for the active backend (#16). An empty query
/// short-circuits to an empty list (no network); otherwise it goes straight to
/// the source's `search`. Search is **not** cached (unlike details) — it's
/// always live. The keystroke debounce lives in the screen (a UI concern).
@riverpod
Future<List<MediaSearchResult>> searchResults(Ref ref, String query) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  return ref.watch(activeMetadataSourceProvider).search(q);
}

/// **AD-3 snapshot-at-add.** Adds [result] with the chosen [status], fetching
/// full details **once** to snapshot the offline-stats fields (`genresCsv`,
/// `runtimeMinutes`, `episodeCountTotal`, `showStatus`) onto the row so stats
/// and the grid never depend on the disposable cache. Always sets the required
/// `recordedSource` (= [sourceKind]) plus the matching id column, so a later
/// backend switch can relink by `imdbId`.
///
/// If the details fetch fails (offline at add-time), it still adds the row from
/// what the search hit carries, leaving the stats fields null to backfill on
/// the next detail view (plan §7). Dedupes via `addOrGetItem`, so re-adding the
/// same title returns the existing row instead of duplicating it.
Future<LibraryItem> addToLibrary({
  required MetadataSource source,
  required MetadataSourceKind sourceKind,
  required LibraryDao dao,
  required MediaSearchResult result,
  required TrackStatus status,
}) async {
  // The id to fetch/store is this backend's own id (matches recordedSource).
  final sourceId = sourceKind == MetadataSourceKind.tmdb
      ? result.tmdbId
      : result.tvdbId;

  MediaDetails? details;
  if (sourceId != null) {
    try {
      details = result.kind == MediaKind.tv
          ? await source.showDetails(sourceId)
          : await source.movieDetails(sourceId);
    } on Object {
      // Offline / fetch error: fall back to the search-hit fields; the stats
      // fields backfill on the next detail view (plan §7).
      details = null;
    }
  }

  final genres = details?.genres ?? const <String>[];
  final now = clock.now();
  return dao.addOrGetItem(
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
}
