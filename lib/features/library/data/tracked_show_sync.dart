import 'package:drift/drift.dart' show Value;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/library_item_ids.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';

part 'tracked_show_sync.g.dart';

/// Max concurrent detail fetches during a sync — the TMDB per-IP guard. A warm
/// library is cache-first (instant); this only paces the cold post-import pass.
const _syncConcurrency = 6;

/// Whether the daily background [TrackedShowSync] is due at launch: never run,
/// or last run a day or more ago. Pure (takes [now]) so the throttle is
/// testable without a boot. `main` stamps the run under [lastLibrarySyncKey].
bool shouldDailySync(DateTime now, DateTime? lastSynced) =>
    lastSynced == null || now.difference(lastSynced) >= const Duration(days: 1);

/// SharedPreferences key holding the last daily-sync time (epoch millis).
const lastLibrarySyncKey = 'last_library_sync';

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
    final sourceId = item.sourceIdFor(backend);
    if (sourceId == null) return null;
    try {
      // `.last`, not `.first`: this is the *refresh* path — its whole job is to
      // pull fresh episode counts / status / next-air. The SWR stream yields the
      // cached value first, then (only if stale) revalidates and yields fresh;
      // `.first` would take the stale cache and cancel before the refetch ever
      // runs, silently writing the same stale values back. `.last` consumes the
      // revalidated value (falling back to cache on a swallowed transient
      // error, and rethrowing on a cold-cache failure — caught below). Contrast
      // bulk_mark, which wants `.first` for latency.
      final d = await repo.showDetails(sourceId).last;
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
