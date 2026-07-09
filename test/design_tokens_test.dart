import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// T11 — lint-as-test. `Color.withOpacity()` is deprecated (Flutter >= 3.27)
/// and lossy; the design system uses `.withValues(alpha:)`. Cheap to run, and
/// it stays true.
void main() {
  test('lib/ contains no deprecated withOpacity() calls', () {
    final offenders =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => f.readAsStringSync().contains('withOpacity('))
            .map((f) => f.path)
            .toList()
          ..sort();

    expect(
      offenders,
      isEmpty,
      reason:
          'use .withValues(alpha:) instead of the deprecated '
          '.withOpacity()',
    );
  });
}
