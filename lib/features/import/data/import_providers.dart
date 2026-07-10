import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_archive.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/importers.dart';
import 'package:watch_nook/core/import_export/import/merge_applier.dart';
import 'package:watch_nook/core/import_export/import/resolver.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/import/domain/import_state.dart';
import 'package:watch_nook/features/library/data/tracked_show_sync.dart';

part 'import_providers.g.dart';

/// A picked file: what the user chose, already in memory. Android's SAF hands
/// back a content URI, not a path, so bytes are the only portable currency.
typedef PickedFile = ({String name, Uint8List bytes});

/// Opens the system file picker. Null when the user backed out.
typedef ImportFilePicker = Future<PickedFile?> Function();

/// The real Android SAF picker. Overridden in tests and by the E2E harness —
/// the platform channel is the one thing `flutter test` cannot drive, so it is
/// the *only* thing behind this seam. Everything below it is the real pipeline.
///
/// No type filter: SAF's MIME filtering hides `.csv` files behind some file
/// managers (they report `application/octet-stream`), and a user who cannot see
/// their own export blames the app, not Android.
@riverpod
ImportFilePicker importFilePicker(Ref ref) => () async {
  final file = await openFile();
  if (file == null) return null;
  return (name: file.name, bytes: await file.readAsBytes());
};

/// Drives the import flow: pick → parse → resolve → (confirm) → apply.
///
/// Nothing is written until [applyConfirmed] (or, when no title was ambiguous,
/// the tail of [importBytes]). Abandoning the confirmation screen therefore
/// leaves the library exactly as it was.
@riverpod
class ImportController extends _$ImportController {
  @override
  ImportState build() => const ImportIdle();

  /// Asks for a file, then imports it. A cancelled picker is a no-op.
  Future<void> pickAndImport() async {
    final picked = await ref.read(importFilePickerProvider)();
    if (picked == null) return;
    await importBytes(picked.name, picked.bytes);
  }

  /// Imports already-read [bytes]. Stops at [ImportConfirming] if the resolver
  /// left anything for a human.
  Future<void> importBytes(String filename, Uint8List bytes) async {
    state = const ImportRunning(ImportPhase.reading);

    // A corrupt zip throws from the decoder, and a wrong-typed field deeper in
    // an importer raises `TypeError` — an `Error`, which `on Exception` would
    // miss (CLAUDE.md). Catching `Object` is what keeps a bad file a message
    // rather than a crash.
    final (ImportSourceKind, ParseResult)? parsed;
    try {
      parsed = parseArchive(ImportArchive.fromBytes(filename, bytes));
    } on Object {
      state = const ImportFailed("That file couldn't be read.");
      return;
    }
    if (parsed == null) {
      state = const ImportFailed(
        'Not a TV Time, Trakt, IMDb or Letterboxd export.',
      );
      return;
    }

    final (source, result) = parsed;
    if (result.records.isEmpty) {
      state = ImportFailed('That ${source.label} export has nothing in it.');
      return;
    }

    final resolver = Resolver(
      source: ref.read(activeMetadataSourceProvider),
      sourceKind: _sourceKind,
    );

    state = ImportRunning(
      ImportPhase.resolving,
      total: result.records.length,
    );
    final resolutions = await _resolveAll(
      result.records,
      resolver,
      onProgress: (done) => state = ImportRunning(
        ImportPhase.resolving,
        done: done,
        total: result.records.length,
      ),
    );

    final pending = resolutions.whereType<Ambiguous>().toList();
    if (pending.isEmpty) {
      await _apply(resolutions, result.skippedRows);
      return;
    }

    state = ImportConfirming(
      source: source,
      autoResolved: resolutions.where((r) => r is! Ambiguous).toList(),
      pending: pending,
      // Pre-select each title's top candidate. TMDB returns them in relevance
      // order and the first is almost always right (regional versions aside),
      // so "accept all" is one tap; wrong ones are re-picked or skipped. Titles
      // with no candidate stay undecided (a skip).
      choices: {
        for (final (i, a) in pending.indexed)
          if (a.candidates.isNotEmpty) i: a.candidates.first,
      },
      parseSkipped: result.skippedRows,
    );
  }

  /// Records the user's decision for `pending[index]`: a candidate, or null to
  /// skip the title. Re-tapping the same choice clears it.
  void choose(int index, MediaSearchResult? candidate) {
    final current = state;
    if (current is! ImportConfirming) return;
    final choices = Map<int, MediaSearchResult?>.from(current.choices);
    if (choices.containsKey(index) && choices[index] == candidate) {
      choices.remove(index);
    } else {
      choices[index] = candidate;
    }
    state = current.withChoices(choices);
  }

  /// Applies the auto-resolved titles plus every confirmed choice. Undecided
  /// and skipped titles stay [Ambiguous], so the applier counts them and writes
  /// nothing for them.
  Future<void> applyConfirmed() async {
    final current = state;
    if (current is! ImportConfirming) return;
    await _apply([
      ...current.autoResolved,
      for (final (i, ambiguous) in current.pending.indexed)
        switch (current.choices[i]) {
          final MediaSearchResult c => Auto(ambiguous.record, c),
          null => ambiguous,
        },
    ], current.parseSkipped);
  }

  /// Back to the start, ready for another file.
  void reset() => state = const ImportIdle();

  Future<void> _apply(List<Resolution> resolutions, int parseSkipped) async {
    state = const ImportRunning(ImportPhase.applying);
    final applier = MergeApplier(
      dao: ref.read(libraryDaoProvider),
      sourceKind: _sourceKind,
    );
    state = ImportDone(
      await applier.apply(resolutions),
      parseSkipped: parseSkipped,
    );
    // Fetch the per-show metadata an import can't (episode counts, show
    // status), so the grid's progress labels and the derived Up-to-date
    // category are right. Fire-and-forget — the summary is already shown.
    unawaited(ref.read(trackedShowSyncProvider).refresh());
  }

  MetadataSourceKind get _sourceKind =>
      metadataSourceKindOf(ref.read(activeMetadataBackendProvider));
}

/// Max metadata lookups in flight during import. Bounding concurrency is the
/// rate-limit guard: TMDB throttles per IP, so firing a 300-title import all at
/// once would 429. Six in flight is fast without tripping the limit; the
/// resolver already degrades a stray 429 to [Unresolved] (the record still
/// applies), so no explicit backoff is needed.
const _resolveConcurrency = 6;

/// Resolves [records] with up to [_resolveConcurrency] lookups running at once,
/// preserving input order. [onProgress] reports the running completed count.
///
/// The index grab (`next++`) and the length check run synchronously between
/// awaits, so the workers never race for the same record on Dart's single
/// event loop.
Future<List<Resolution>> _resolveAll(
  List<ImportRecord> records,
  Resolver resolver, {
  required void Function(int done) onProgress,
}) async {
  final results = List<Resolution?>.filled(records.length, null);
  var next = 0;
  var done = 0;

  Future<void> worker() async {
    while (next < records.length) {
      final i = next++;
      results[i] = await resolver.resolve(records[i]);
      onProgress(++done);
    }
  }

  await Future.wait([
    for (var w = 0; w < _resolveConcurrency && w < records.length; w++)
      worker(),
  ]);
  return results.cast<Resolution>();
}
