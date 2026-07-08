import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Poster/backdrop image cache (ADR-7). Artwork is near-immutable, so we raise
/// both the TTL and the object cap far above `flutter_cache_manager`'s defaults
/// (30 days / 200 objects) — a library of a few hundred titles should keep all
/// its posters resident so the grid renders fully offline.
///
/// Wire into `CachedNetworkImage(cacheManager: PosterCacheManager.instance)`
/// wherever posters/backdrops render (the detail screen + grid land in M2).
class PosterCacheManager extends CacheManager {
  PosterCacheManager._()
    : super(
        Config(
          cacheKey,
          stalePeriod: imageStalePeriod,
          maxNrOfCacheObjects: maxObjects,
        ),
      );

  /// Namespaces this cache's box (distinct from any default manager).
  static const cacheKey = 'watchnook_posters';

  /// 60-day TTL — images rarely change (ADR-7); a stale poster is harmless.
  static const imageStalePeriod = Duration(days: 60);

  /// Cap well above the 200 default so a full library's artwork stays cached.
  static const maxObjects = 1000;

  /// The shared singleton — one manager per cache box.
  static final PosterCacheManager instance = PosterCacheManager._();
}
