import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';

/// The single provider-agnostic metadata gateway (ADR-1). Two impls —
/// `TmdbSource` (#10) and `TvdbSource` (#11) — do the provider-specific HTTP
/// and parsing and emit the normalized models in `models/`. UI/features
/// **never** call an HTTP client directly: they go through this interface
/// (CLAUDE.md), and the active impl is chosen at runtime from
/// `RemoteConfigService.backend`, so flipping the backend swaps sources with
/// no code change.
///
/// All ids passed in ([movieDetails]/[showDetails]/[seasonEpisodes]) are
/// [SourceRef]s, which carry the backend that minted them. An impl handed a
/// reference from the *other* backend throws rather than answering it: ids are
/// namespaced per backend, so the wrong catalogue does not reject a foreign id
/// — it returns a different title. The reference type is what makes that
/// pairing checkable instead of conventional.
/// [resolveByExternalId] is the exception: it takes an external id (IMDb, or a
/// TVDB id from a TV Time import) and maps it to this source (ADR-4).
abstract interface class MetadataSource {
  /// Full-text search for titles. [kind] narrows to movies or shows; null
  /// searches both.
  Future<List<MediaSearchResult>> search(String query, {MediaKind? kind});

  /// Full details for a movie by [ref] — which must be this source's own.
  Future<MediaDetails> movieDetails(SourceRef ref);

  /// Full details for a show by [ref] — this source's own — including the next
  /// episode to air and season summaries.
  Future<MediaDetails> showDetails(SourceRef ref);

  /// Aired-order episodes for one season of a show (ADR-4 — never
  /// absolute/DVD numbering).
  Future<List<EpisodeInfo>> seasonEpisodes(SourceRef show, int seasonNumber);

  /// Relinks a title to this source by an external id. [kind] selects the id
  /// namespace: IMDb (the universal join key for a backend switch, ADR-4) or
  /// TVDB (a TV Time export id, mapped to a TMDB title so it need not fall to
  /// fuzzy title search). Returns null when the source can't match it.
  Future<MediaSearchResult?> resolveByExternalId(
    String id, {
    ExternalIdKind kind = ExternalIdKind.imdb,
  });

  /// Builds a full image URL from a backend-relative [path]. TMDB maps [size]
  /// to its width buckets; TVDB returns full URLs and ignores [size].
  String imageUrl(String path, ImageSize size);

  /// Per-source attribution — mandatory display on the detail screen.
  Attribution attribution();
}
