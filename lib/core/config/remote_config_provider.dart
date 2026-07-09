import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_service.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';

part 'remote_config_provider.g.dart';

/// The singleton [RemoteConfigService]. `keepAlive` — it owns the config cache
/// for the whole app lifetime.
@Riverpod(keepAlive: true)
RemoteConfigService remoteConfigService(Ref ref) =>
    RemoteConfigService(prefs: ref.watch(sharedPreferencesProvider));

/// The active metadata backend (enum) from the synchronous config. M1 adds a
/// separate `activeMetadataSourceProvider` (a `MetadataSource` instance) that
/// consumes this — additive, no retype of this provider.
@Riverpod(keepAlive: true)
MetadataBackend activeMetadataBackend(Ref ref) =>
    ref.watch(remoteConfigServiceProvider).current().backend;
