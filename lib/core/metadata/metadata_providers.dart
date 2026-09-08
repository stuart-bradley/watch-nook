import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_source.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/tmdb/tmdb_source.dart';
import 'package:watch_nook/core/metadata/tvdb/tvdb_source.dart';

part 'metadata_providers.g.dart';

// The AD-2 metadata wiring — the gap #16 closes. UI/features consume these
// providers only: never an HTTP client or a concrete source directly (the
// provider-agnostic rule in CLAUDE.md). All `keepAlive` (app-lifetime).

/// Shared HTTP client for every metadata call. Closed when the container tears
/// down so sockets don't leak.
@Riverpod(keepAlive: true)
http.Client httpClient(Ref ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
}

/// The **raw**, uncached source for the active backend, built from the current
/// config keys (AD-2). Rebuilds if the backend or its keys change.
///
/// Not for app code: it is the thing [metadataProvider] wraps, and reading it
/// directly is how a caller silently opts out of the offline guarantee (ADR-7,
/// US-13) — a screen fed from here blanks when the network does. Every
/// consumer takes [metadataProvider], which satisfies the same interface. A
/// lint-as-test (`test/core/metadata/one_metadata_provider_test.dart`) holds
/// `lib/` to that; tests override this one to inject a fake backend, which is
/// exactly what it is still public for.
@Riverpod(keepAlive: true)
MetadataSource activeMetadataSource(Ref ref) {
  final config = ref.watch(remoteConfigServiceProvider).current();
  final client = ref.watch(httpClientProvider);
  return switch (ref.watch(activeMetadataBackendProvider)) {
    MetadataBackend.tmdb => TmdbSource(
      client: client,
      apiKey: config.tmdbApiKey,
      readToken: config.tmdbReadToken,
    ),
    MetadataBackend.tvdb => TvdbSource(
      client: client,
      apiKey: config.tvdbApiKey,
    ),
  };
}

/// **The** metadata gateway for app code (AD-2, ADR-7): a [MetadataSource]
/// whose three detail lookups are stale-while-revalidate over the local cache
/// and whose search/relink pass straight through.
///
/// One provider and one interface, so no call site has to know whether it is
/// holding the cached thing or the raw thing — the difference used to be a
/// convention about which of two stream emissions to take.
@Riverpod(keepAlive: true)
CachingMetadataSource metadata(Ref ref) => CachingMetadataSource(
  source: ref.watch(activeMetadataSourceProvider),
  // The cache keys every row by this value and `RemoteImage` compares against
  // it, so they must be the same answer — which is what [metadataSourceKindOf]
  // over the single backend provider buys.
  sourceKind: metadataSourceKindOf(ref.watch(activeMetadataBackendProvider)),
  dao: ref.watch(mediaCacheDaoProvider),
);

/// The active backend as the DB's per-row [MetadataSourceKind] — the value a
/// stored row's `recordedSource` must match for its ids and artwork to mean
/// anything (see `SourceRef` / `ArtworkRef`).
///
/// The two enums are **one concept with two representations** and stay two
/// types for a layering reason (ADR-9). This is the only converter between
/// them.
///
/// Deliberately a **function, not a provider** (ADR-9). It used to be a derived
/// provider, which meant two overridable answers to "what backend are we on?" —
/// and a harness that overrode only one got rows cached under one backend and
/// compared against another. A function cannot be overridden, so
/// [activeMetadataBackendProvider] is the single injection point and the
/// split-brain is unrepresentable.
MetadataSourceKind metadataSourceKindOf(MetadataBackend backend) =>
    switch (backend) {
      MetadataBackend.tmdb => MetadataSourceKind.tmdb,
      MetadataBackend.tvdb => MetadataSourceKind.tvdb,
    };

/// Bridges the metadata layer's [MediaKind] to the DB's [MediaType].
MediaType mediaTypeOf(MediaKind kind) => switch (kind) {
  MediaKind.movie => MediaType.movie,
  MediaKind.tv => MediaType.tv,
};
