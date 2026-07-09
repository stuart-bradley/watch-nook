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

    final resolutions = <Resolution>[];
    for (final record in result.records) {
      state = ImportRunning(
        ImportPhase.resolving,
        done: resolutions.length,
        total: result.records.length,
      );
      resolutions.add(await resolver.resolve(record));
    }

    final pending = resolutions.whereType<Ambiguous>().toList();
    if (pending.isEmpty) {
      await _apply(resolutions, result.skippedRows);
      return;
    }

    state = ImportConfirming(
      source: source,
      autoResolved: resolutions.where((r) => r is! Ambiguous).toList(),
      pending: pending,
      choices: const {},
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
  }

  MetadataSourceKind get _sourceKind =>
      metadataSourceKindOf(ref.read(activeMetadataBackendProvider));
}
