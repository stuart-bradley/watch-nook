import 'dart:io';

import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/import_export/export/import_export_service.dart';

/// Android Auto Backup's on-device half: keep a JSON snapshot of the user
/// tables where the manifest allowlist can see it, and put it back on a fresh
/// install.
///
/// INVARIANT (AD-7, enforced by `test/android/backup_rules_test.dart`):
/// [backupDirName] is one fact written in three files — here, in
/// `res/xml/backup_rules.xml` and in `res/xml/data_extraction_rules.xml`. The
/// allowlist names `path="backup"`, and `getApplicationSupportDirectory()` is
/// Android's `filesDir` (backup domain `file`, empty relative path), so the
/// snapshot **must** live one level down. Disagree and the app silently backs
/// up nothing, forever.
class AutoBackupService {
  /// Creates a service writing into [directory] (injected, so tests use a temp
  /// dir rather than `path_provider`).
  AutoBackupService({
    required this.service,
    required this.dao,
    required this.directory,
  });

  /// The single canonical serializer (AD-1) — export and backup are one format.
  final ImportExportService service;

  /// User-owned tables. The empty-library probe for [restoreIfEmpty].
  final LibraryDao dao;

  /// Where [file] lives. Must be `<filesDir>/[backupDirName]` in production.
  final Directory directory;

  /// MUST equal the `path` attribute of the `include` in **both**
  /// `res/xml/backup_rules.xml` and `res/xml/data_extraction_rules.xml`.
  static const backupDirName = 'backup';

  static const _fileName = 'watchnook_backup.json';

  /// The published snapshot. Never half-written (see [snapshot]).
  File get file => File('${directory.path}/$_fileName');

  File get _temp => File('${file.path}.tmp');

  Future<void>? _inFlight;

  /// Serialize → temp file → rename. Same-directory rename is atomic on POSIX,
  /// so [file] is either the previous backup or the new one, never a prefix of
  /// either.
  ///
  /// Single-flight (leading edge): `onPause` is fire-and-forget, so a fast
  /// pause→resume→pause would otherwise put two writers on the same temp name
  /// and let the second's rename publish the first's half-written bytes. The
  /// second caller joins the first flight; its newer DB state lands on the next
  /// `onPause` (Android throttles off-device backup anyway, so the file
  /// re-converges).
  Future<void> snapshot() =>
      _inFlight ??= _snapshot().whenComplete(() => _inFlight = null);

  Future<void> _snapshot() async {
    // Serialize BEFORE touching disk: a throw here leaves the previous backup
    // intact and does not even create a temp sibling.
    final json = await service.exportJson();
    await directory.create(recursive: true);
    await _temp.writeAsString(json, flush: true);
    await _temp.rename(file.path);
  }

  /// Deletes the on-device snapshot (and any in-flight temp). Part of the GDPR
  /// delete-all: the manifest allowlist backs up exactly this file, so removing
  /// it is what stops wiped data being re-restored on the next launch or
  /// re-uploaded by Android Auto Backup.
  Future<void> deleteBackup() async {
    if (file.existsSync()) await file.delete();
    if (_temp.existsSync()) await _temp.delete();
  }

  /// Fresh-install restore. Returns true when it actually put items back.
  ///
  /// Keyed on an **empty library**, not on a "first run" pref — prefs are
  /// excluded from the backup allowlist, so they cannot be trusted here. A
  /// non-empty library is never touched (restore replaces; that would be a
  /// wipe).
  ///
  /// Propagates [FormatException] on a corrupt file. The boot path in `main()`
  /// swallows it (`on Object`) so a bad backup can never loop the boot.
  Future<bool> restoreIfEmpty() async {
    if (await dao.hasAnyItems()) return false;
    // Sync: one stat, and `avoid_slow_async_io` bans the async form.
    if (!file.existsSync()) return false;
    final summary = await service.restore(await file.readAsString());
    // A rejected file (wrong `version`) restores zero items — that is not a
    // restore, and must not suppress onboarding for an empty library.
    return summary.itemsRestored > 0;
  }
}
