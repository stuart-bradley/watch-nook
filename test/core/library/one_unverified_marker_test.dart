import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lint-as-test, in the style of `test/core/metadata/one_metadata_provider_test.dart`.
///
/// Three surfaces render an Unverified position and all three must take the
/// wording from `unverified_position.dart`. The failure this guards against is
/// not a crash — it is the grid saying one thing and Up Next another about the
/// same title, which reads as two different problems. Retyping the word at a
/// surface is exactly how that starts.
void main() {
  const owner = 'lib/core/library/unverified_position.dart';
  // The marker EXACTLY as it renders, parentheses included — not the bare word.
  // 'unconfirmed' also appears in the detail notices' prose, so scanning
  // for that would make the positive control below pass even with the marker
  // constant deleted: a guard that cannot fail.
  const marker = '(unconfirmed)';

  test('the marker wording is written in exactly one lib/ file', () {
    final offenders =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.endsWith('.g.dart'))
            .where((f) => f.path != owner)
            .where((f) => f.readAsStringSync().contains(marker))
            .map((f) => f.path)
            .toList()
          ..sort();

    expect(
      offenders,
      isEmpty,
      reason:
          'call markUnverifiedPosition instead — the wording belongs to '
          '$owner, and a second copy is free to drift',
    );
  });

  test(
    'the owner really does contain the wording — a rename must not neuter this',
    () {
      // Without this, renaming the marker turns the scan above into a test that
      // passes forever while checking nothing. A lint-as-test needs a positive
      // control more than most tests do: its failure mode is silence.
      expect(File(owner).readAsStringSync(), contains(marker));
    },
  );
}
