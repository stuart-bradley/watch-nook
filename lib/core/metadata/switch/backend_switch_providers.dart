import 'package:riverpod_annotation/riverpod_annotation.dart';
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
  final active = ref.watch(activeMetadataKindProvider);
  final rows = await ref.watch(libraryDaoProvider).getAll();
  return rows.where((r) => r.recordedSource != active).length;
}

/// The relink service, pointed at the **active** backend.
///
/// **The one deliberate reader of the raw, uncached source** — the exemption
/// named in `test/core/metadata/one_metadata_provider_test.dart`.
///
/// Relinking decides whether a row's watch history survives, by checking every
/// watched coordinate against the new backend's air-dates. Answering that from
/// cache is worse than not answering it: a warm entry means the check silently
/// passes without ever reaching the new backend, and `relinkFailed` is written
/// `false` for a row nothing verified — invariant 3's "never silently scramble
/// watched flags". A failure here must stay a failure, so the reconcile can
/// flag the row instead of trusting it.
///
/// Deliberately has no boot hook. Relinking rewrites ids, `recordedSource` and
/// — where episodes cannot be reconciled by air-date — sets `relinkFailed` on
/// rows carrying the user's watch history. Doing that unattended, in response
/// to a config change the user never saw, is not a decision this app gets to
/// make for them: it is offered in Settings and runs when they ask.
@Riverpod(keepAlive: true)
BackendSwitchService backendSwitchService(Ref ref) => BackendSwitchService(
  db: ref.watch(appDatabaseProvider),
  newSource: ref.watch(activeMetadataSourceProvider),
  newKind: ref.watch(activeMetadataKindProvider),
);
