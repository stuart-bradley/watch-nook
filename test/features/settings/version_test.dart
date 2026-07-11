import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/features/settings/presentation/settings_screen.dart';

/// The About screen renders a hardcoded [appVersion] rather than depending on
/// `package_info_plus` (ponytail: one string beats a platform channel). This
/// guard keeps that string in lockstep with `pubspec.yaml`'s `version:` so the
/// two can't silently drift — the exact bug that shipped 0.1.0 in About while
/// pubspec had moved on.
void main() {
  test('appVersion matches pubspec.yaml version (no drift)', () {
    // Flutter tests run from the package root, so the path is stable.
    final line = File(
      'pubspec.yaml',
    ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    // "version: 0.1.1+2" -> "0.1.1" (strip the +build).
    final pubspecVersion = line.split(':')[1].trim().split('+').first;

    expect(appVersion, pubspecVersion);
  });
}
