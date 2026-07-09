import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
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

/// The concrete [MetadataSource] for the active backend, built from the current
/// config keys (AD-2). Rebuilds if the backend or its keys change.
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

/// The SWR cache over [activeMetadataSourceProvider] (AD-2). Detail screens
/// read through this (cache-first); search and relink hit the source directly.
@Riverpod(keepAlive: true)
CachingMetadataRepository metadataRepository(Ref ref) {
  final backend = ref.watch(activeMetadataBackendProvider);
  return CachingMetadataRepository(
    source: ref.watch(activeMetadataSourceProvider),
    sourceKind: metadataSourceKindOf(backend),
    dao: ref.watch(mediaCacheDaoProvider),
  );
}

/// Bridges the config's [MetadataBackend] to the DB's per-row
/// [MetadataSourceKind] (stamped onto `LibraryItems.recordedSource`).
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
