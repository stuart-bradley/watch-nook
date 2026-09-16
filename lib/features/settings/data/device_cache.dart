import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/metadata/cache/poster_cache_manager.dart';

part 'device_cache.g.dart';

/// Erases what the app keeps outside its database: Settings → *Delete
/// everything*'s file half.
typedef CacheWiper = Future<void> Function();

/// The real wipe over the platform's cache directory and the poster cache.
/// Overridden in tests: `getTemporaryDirectory` is a platform channel and the
/// poster index is sqflite, neither of which `flutter test` can reach.
@riverpod
CacheWiper cacheWiper(Ref ref) =>
    () async => wipeCaches(
      cacheDir: await getTemporaryDirectory(),
      posters: PosterCacheManager.instance,
    );

/// Empties [posters]' index, then deletes everything inside [cacheDir].
///
/// Android's `cacheDir` is where copies of the user's library pile up, all
/// written by plugins rather than by this app, so none of them is tracked
/// anywhere a narrower delete could find:
/// - `share_plus/`: every export handed to the share sheet (the full JSON and
///   the Letterboxd CSV);
/// - `<uuid>/`: `file_selector`'s copy of each file picked for import;
/// - `watchnook_posters/`: the poster images ([PosterCacheManager]).
///
/// The poster *index* is a sqflite file in app support, outside [cacheDir], so
/// it is emptied through the manager; its rows name every poster the user saw.
///
/// The directory's children go, the directory stays: `drift_flutter` points
/// sqlite's temp directory at it for the lifetime of the open database.
///
/// ponytail: sync deletes. A one-off behind a confirm dialog, and a cache dir
/// is small; move to async if a large poster cache ever janks the dialog.
Future<void> wipeCaches({
  required Directory cacheDir,
  required BaseCacheManager posters,
}) async {
  await posters.emptyCache();
  for (final entity in cacheDir.listSync()) {
    entity.deleteSync(recursive: true);
  }
}
