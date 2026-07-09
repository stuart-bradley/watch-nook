import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/import_export/export/auto_backup_service.dart';
import 'package:watch_nook/core/import_export/export/import_export_service.dart';

part 'export_providers.g.dart';

/// The one canonical serializer (AD-1): manual export, auto-backup snapshot and
/// restore all go through this instance.
@Riverpod(keepAlive: true)
ImportExportService importExportService(Ref ref) =>
    ImportExportService(ref.watch(libraryDaoProvider));

/// Async because `getApplicationSupportDirectory()` is a platform channel.
///
/// The backup directory is built from [AutoBackupService.backupDirName], never
/// from a second `'backup'` literal — otherwise the XML allowlist test would
/// catch the *rules* drifting while this provider quietly moved to `backups/`.
@Riverpod(keepAlive: true)
Future<AutoBackupService> autoBackupService(Ref ref) async {
  // Android: `filesDir` — backup domain `file`, empty relative path.
  final support = await getApplicationSupportDirectory();
  return AutoBackupService(
    service: ref.watch(importExportServiceProvider),
    dao: ref.watch(libraryDaoProvider),
    directory: Directory('${support.path}/${AutoBackupService.backupDirName}'),
  );
}
