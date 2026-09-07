import 'package:drift/drift.dart' show Value;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_source.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';

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
  repo: ref.watch(metadataProvider),
  backend: metadataSourceKindOf(ref.watch(activeMetadataBackendProvider)),
);

/// Refreshes the per-show metadata an import can't fetch — `episodeCountTotal`,
/// `showStatus`, poster, per-episode `runtimeMinutes` and `genresCsv` — onto
/// the tracked `LibraryItems` rows, so the grid's progress labels ("3 left"),
/// the derived **Up to date** category, and the Stats hours/genre breakdowns
/// are accurate. Cache-first per show (a warm library is cheap), bounded, and
/// per-show fault-tolerant (an offline / 404 show is skipped, not fatal). All
/// writes land in one transaction, so the grid and Up Next recompute once.
class TrackedShowSync {
  TrackedShowSync({
    required this.dao,
    required this.repo,
    required this.backend,
  });

  final LibraryDao dao;
  final CachingMetadataSource repo;
  final MetadataSourceKind backend;

  Future<void> refresh() async {
    final items = await dao.getAll();
    final shows = [
      for (final item in items)
        if (item.mediaType == MediaType.tv &&
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
    // The one pairing check: a row recorded against the other backend (or with
    // no id for its own) has no reference, and so nothing this sync can fetch.
    final show = item.refFor(backend);
    if (show == null) return null;
    try {
      // Named, not `.last`: this is the *refresh* path, so it must be told when
      // a refresh did not happen rather than handed back the stale values it
      // already has. A failure lands in the catch below and skips the patch.
      final d = await repo.revalidatedShowDetails(show);
      return (
        item.id,
        LibraryItemsCompanion(
          episodeCountTotal: Value(d.episodeCountTotal),
          showStatus: Value(d.showStatus),
          // Per-episode runtime + genres: the stats-snapshot enrichment an
          // export can't carry. Import stays honest; the refresh backfills both
          // so imported history contributes estimated hours (via the item
          // runtime fallback) and a genre breakdown, clearing the "missing
          // data" footnote. Absent, not null, on a partial detail.
          runtimeMinutes: d.runtimeMinutes != null
              ? Value(d.runtimeMinutes)
              : const Value.absent(),
          genresCsv: d.genres.isNotEmpty
              ? Value(d.genres.join(','))
              : const Value.absent(),
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
