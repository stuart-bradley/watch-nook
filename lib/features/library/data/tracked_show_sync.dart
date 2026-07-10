import 'package:drift/drift.dart' show Value;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart'
    show sourceIdOf;

part 'tracked_show_sync.g.dart';

/// Max concurrent detail fetches during a sync — the TMDB per-IP guard. A warm
/// library is cache-first (instant); this only paces the cold post-import pass.
const _syncConcurrency = 6;

/// Builds the [TrackedShowSync] for the active backend.
@Riverpod(keepAlive: true)
TrackedShowSync trackedShowSync(Ref ref) => TrackedShowSync(
  dao: ref.watch(libraryDaoProvider),
  repo: ref.watch(metadataRepositoryProvider),
  backend: metadataSourceKindOf(ref.watch(activeMetadataBackendProvider)),
);

/// Refreshes the per-show metadata an import can't fetch — `episodeCountTotal`,
/// `showStatus`, poster — onto the tracked `LibraryItems` rows, so the grid's
/// progress labels ("3 left") and the derived **Up to date** category are
/// accurate. Cache-first per show (a warm library is cheap), bounded, and
/// per-show fault-tolerant (an offline / 404 show is skipped, not fatal). All
/// writes land in one transaction, so the grid and Up Next recompute once.
class TrackedShowSync {
  TrackedShowSync({
    required this.dao,
    required this.repo,
    required this.backend,
  });

  final LibraryDao dao;
  final CachingMetadataRepository repo;
  final MetadataSourceKind backend;

  Future<void> refresh() async {
    final items = await dao.getAll();
    final shows = [
      for (final item in items)
        if (item.mediaType == MediaType.tv &&
            item.recordedSource == backend &&
            item.trackStatus != TrackStatus.dropped)
          item,
    ];

    final patches = <(int, LibraryItemsCompanion)>[];
    for (var i = 0; i < shows.length; i += _syncConcurrency) {
      final batch = shows.skip(i).take(_syncConcurrency);
      final results = await Future.wait(batch.map(_patchFor));
      patches.addAll(results.whereType<(int, LibraryItemsCompanion)>());
    }
    if (patches.isNotEmpty) await dao.updateManyItems(patches);
  }

  Future<(int, LibraryItemsCompanion)?> _patchFor(LibraryItem item) async {
    final sourceId = sourceIdOf(item, backend);
    if (sourceId == null) return null;
    try {
      final d = await repo.showDetails(sourceId).first;
      return (
        item.id,
        LibraryItemsCompanion(
          episodeCountTotal: Value(d.episodeCountTotal),
          showStatus: Value(d.showStatus),
          // Don't clobber an existing poster with null on a partial detail.
          posterPath: d.posterPath != null
              ? Value(d.posterPath)
              : const Value.absent(),
        ),
      );
    } on Object {
      return null;
    }
  }
}
