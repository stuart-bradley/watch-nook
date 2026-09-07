import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/switch/backend_switch_service.dart';

part 'backend_switch_providers.g.dart';

/// How many library rows are recorded against a backend that is **not** the
/// active one.
///
/// ADR-2 makes flipping the backend an operator action taken in a hosted config
/// file, so this can become non-zero between one launch and the next with no
/// warning to the user. Those rows still hold the previous backend's ids, which
/// are meaningless to the active catalogue, so nothing may fetch for them until
/// they are relinked.
///
/// A **one-shot** read, not a `.watch()` stream: the count only moves on a
/// relink or an import, so live-ness buys nothing — and a live Drift stream
/// never quiesces under `flutter_test` fake-async, which would hang
/// `pumpAndSettle` in every widget test that mounts Settings (the CLAUDE.md
/// hazard). Auto-disposed, so it is recomputed each time Settings is opened.
@riverpod
Future<int> backendMismatchCount(Ref ref) async {
  final active = metadataSourceKindOf(ref.watch(activeMetadataBackendProvider));
  final rows = await ref.watch(libraryDaoProvider).getAll();
  return rows.where((r) => r.recordedSource != active).length;
}

/// The relink service, pointed at the **active** backend.
///
/// Deliberately has no boot hook. Relinking rewrites ids, `recordedSource` and
/// — where episodes cannot be reconciled by air-date — sets `relinkFailed` on
/// rows carrying the user's watch history. Doing that unattended, in response
/// to a config change the user never saw, is not a decision this app gets to
/// make for them: it is offered in Settings and runs when they ask.
@Riverpod(keepAlive: true)
BackendSwitchService backendSwitchService(Ref ref) => BackendSwitchService(
  db: ref.watch(appDatabaseProvider),
  newSource: ref.watch(metadataProvider),
  newKind: metadataSourceKindOf(ref.watch(activeMetadataBackendProvider)),
);
