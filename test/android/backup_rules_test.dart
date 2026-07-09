import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/import_export/export/auto_backup_service.dart';

/// AD-7: the manifest allowlist is the only thing between the disposable cache
/// (+ the metadata API key in `shared_prefs/`) and Google's servers. Both rule
/// files fail **open** — a file that mentions neither `database` nor
/// `sharedpref` is exactly the leaking one — so every assertion here is
/// positive: what the rules contain, not what they omit.
///
/// Deliberately no XML parser. `package:xml` is only transitive through
/// `archive`, which may drop it in any release (`depend_on_referenced_packages`
/// exists for this); the files are six lines each.
void main() {
  String read(String name) =>
      // Comments are stripped first: prose about `device-transfer` must not be
      // able to satisfy an assertion about the element.
      File(
        'android/app/src/main/res/xml/$name.xml',
      ).readAsStringSync().replaceAll(RegExp('<!--.*?-->', dotAll: true), '');

  /// Every `(domain, path)` pair of every `include` in [xml].
  List<(String?, String?)> includes(String xml) => [
    for (final m in RegExp(r'<include\b([^>]*?)/?>').allMatches(xml))
      (_attr(m.group(1)!, 'domain'), _attr(m.group(1)!, 'path')),
  ];

  /// The body of `<[tag]> … </[tag]>`, or null if the section is absent.
  String? section(String xml, String tag) =>
      RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(xml)?.group(1);

  final legacy = read('backup_rules');
  final modern = read('data_extraction_rules');

  test('backup_rules.xml allowlists exactly the backup dir', () {
    expect(legacy, contains('<full-backup-content>'));
    expect(includes(legacy), [('file', 'backup')]);
    expect(RegExp('<exclude').allMatches(legacy), isEmpty);
  });

  test('data_extraction_rules.xml carries BOTH backup-mode sections', () {
    expect(modern, contains('<data-extraction-rules>'));

    // A missing section is a FULLY ENABLED section: ship only `cloud-backup`
    // and a device-to-device transfer copies `shared_prefs/` (the API key).
    for (final tag in ['cloud-backup', 'device-transfer']) {
      final body = section(modern, tag);
      expect(body, isNotNull, reason: '$tag missing ⇒ that mode backs up all');
      expect(includes(body!), [('file', 'backup')]);
    }
  });

  test('data_extraction_rules.xml has no root-level include/exclude', () {
    // Invalid at the root in this schema ⇒ the whole file is ignored ⇒ Android
    // silently falls back to backing up databases/ and shared_prefs/.
    final root = modern
        .replaceAll(
          RegExp('<cloud-backup>.*?</cloud-backup>', dotAll: true),
          '',
        )
        .replaceAll(
          RegExp('<device-transfer>.*?</device-transfer>', dotAll: true),
          '',
        );
    expect(includes(root), isEmpty);
    expect(RegExp('<exclude').allMatches(root), isEmpty);
  });

  test('across both files, the allowed set is exactly {(file, backup)}', () {
    // Driven by the invariant, not by string absence: a `domain="database"`
    // include, a third backup-mode section, or a dropped `device-transfer` each
    // fails a different one of these tests.
    expect(
      {...includes(legacy), ...includes(modern)},
      {('file', AutoBackupService.backupDirName)},
    );
  });

  test('the manifest wires both rule files and keeps allowBackup on', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync().replaceAll(RegExp('<!--.*?-->', dotAll: true), '');

    expect(manifest, contains('android:allowBackup="true"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });
}

String? _attr(String attributes, String name) =>
    RegExp('$name="([^"]*)"').firstMatch(attributes)?.group(1);
