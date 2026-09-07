import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lint-as-test, in the style of `test/design_tokens_test.dart`.
///
/// `metadataProvider` and `activeMetadataSourceProvider` satisfy the same
/// interface, and picking the wrong one costs nothing at compile time — it
/// just opts that call site out of the cache, and with it the offline
/// guarantee (ADR-7, US-13): a screen fed from the raw source blanks when the
/// network does, and a whole-show bulk mark aborts instead of using what it
/// already had.
///
/// Nothing but the wrapper itself may read the raw source. Tests still
/// override it — that is what it stays public for.
///
/// A text match, not a compiler guarantee: it cannot see an alias or an
/// instance passed by hand. It does catch the way this actually goes wrong,
/// which is someone reaching for the obvious-looking provider.
void main() {
  test('nothing in lib/ reads the raw source except its own wrapper', () {
    const owner = 'lib/core/metadata/metadata_providers.dart';

    final offenders =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.endsWith('.g.dart'))
            .where((f) => f.path != owner)
            // A read, not a mention: the doc comments in `core/config` name
            // it while explaining what it is, which is not a bypass.
            .where(
              (f) => RegExp(
                r'ref\.(watch|read)\(\s*activeMetadataSourceProvider',
              ).hasMatch(f.readAsStringSync()),
            )
            .map((f) => f.path)
            .toList()
          ..sort();

    expect(
      offenders,
      isEmpty,
      reason:
          'read metadataProvider instead — it is the same interface with the '
          'cache, and the cache is the offline guarantee',
    );
  });
}
