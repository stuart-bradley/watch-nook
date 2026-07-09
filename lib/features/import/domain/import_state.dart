import 'package:flutter/foundation.dart';
import 'package:watch_nook/core/import_export/import/importers.dart';
import 'package:watch_nook/core/import_export/import/merge_applier.dart';
import 'package:watch_nook/core/import_export/import/resolver.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// Where a running import has got to. Reading is instant; resolving is the slow
/// leg (one lookup per unidentified title), so only it carries a total.
enum ImportPhase {
  /// Unzipping and parsing the file.
  reading('Reading your export'),

  /// Matching titles against the metadata backend.
  resolving('Matching titles'),

  /// Writing rows into the library.
  applying('Adding to your library');

  const ImportPhase(this.label);

  /// Progress-screen caption.
  final String label;
}

/// The import flow, as a state machine. One of these at a time; the screen is a
/// `switch` over them.
@immutable
sealed class ImportState {
  const ImportState();
}

/// Nothing picked yet.
class ImportIdle extends ImportState {
  /// Creates an [ImportIdle].
  const ImportIdle();
}

/// Working. [total] is 0 while the phase has nothing to count.
class ImportRunning extends ImportState {
  /// Creates an [ImportRunning].
  const ImportRunning(this.phase, {this.done = 0, this.total = 0});

  /// Which leg of the pipeline is executing.
  final ImportPhase phase;

  /// Records finished in this phase.
  final int done;

  /// Records this phase has to get through, or 0 when it isn't countable.
  final int total;
}

/// The resolver could not confidently match some titles (AD-3 rung 3). Nothing
/// has been written yet — the applier only runs once the user has decided, so
/// abandoning the screen here leaves the library untouched.
@immutable
class ImportConfirming extends ImportState {
  /// Creates an [ImportConfirming].
  const ImportConfirming({
    required this.source,
    required this.autoResolved,
    required this.pending,
    required this.choices,
    required this.parseSkipped,
  });

  /// Which export this came from, for the header.
  final ImportSourceKind source;

  /// Everything the resolver settled on its own; applied verbatim.
  final List<Resolution> autoResolved;

  /// The titles awaiting a decision, in display order.
  final List<Ambiguous> pending;

  /// `pending` index → the candidate chosen for it. A key mapped to null is an
  /// explicit **skip**; a missing key is simply undecided. Both leave the title
  /// out of the import — the distinction only drives the UI's selected state.
  final Map<int, MediaSearchResult?> choices;

  /// Rows the importer had to drop while parsing (AD-7), carried through to the
  /// summary so a malformed export is visible rather than silently lossy.
  final int parseSkipped;

  /// Copy with [choices] replaced.
  ImportConfirming withChoices(Map<int, MediaSearchResult?> next) =>
      ImportConfirming(
        source: source,
        autoResolved: autoResolved,
        pending: pending,
        choices: next,
        parseSkipped: parseSkipped,
      );
}

/// The import landed.
class ImportDone extends ImportState {
  /// Creates an [ImportDone].
  const ImportDone(this.summary, {this.parseSkipped = 0});

  /// What the applier wrote.
  final ImportSummary summary;

  /// Rows dropped during parsing, on top of [ImportSummary.skippedRows].
  final int parseSkipped;

  /// Every row this import could not use, from either stage.
  int get rowsSkipped => parseSkipped + summary.skippedRows;
}

/// The file could not be read at all. Nothing was written.
class ImportFailed extends ImportState {
  /// Creates an [ImportFailed].
  const ImportFailed(this.message);

  /// What to show the user.
  final String message;
}
