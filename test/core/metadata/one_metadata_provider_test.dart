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
  const pattern = r'ref\.(watch|read)\(\s*activeMetadataSourceProvider';

  test('nothing in lib/ reads the raw source except its own wrapper', () {
    const owner = 'lib/core/metadata/metadata_providers.dart';

    /// The relink is the one thing that must NOT read through the cache: it
    /// decides whether a row's watch history survives, and a warm cache entry
    /// would let that check pass without ever reaching the new backend. The
    /// reasoning is at the provider; this list is the enforcement.
    const exempt = {'lib/core/metadata/switch/backend_switch_providers.dart'};

    final offenders =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.endsWith('.g.dart'))
            .where((f) => f.path != owner)
            .where((f) => !exempt.contains(f.path))
            // A read, not a mention: the doc comments in `core/config` name
            // it while explaining what it is, which is not a bypass.
            .where(
              (f) => RegExp(pattern).hasMatch(f.readAsStringSync()),
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

  test('the scan can actually match — a rename must not neuter it', () {
    // Without this, renaming the provider (or aliasing the import) turns the
    // test above into one that passes forever while checking nothing. A
    // lint-as-test needs a positive control more than most tests do, because
    // its failure mode is silence.
    expect(
      RegExp(pattern).hasMatch('ref.watch(activeMetadataSourceProvider)'),
      isTrue,
    );
    expect(
      RegExp(pattern).hasMatch('ref.read( activeMetadataSourceProvider )'),
      isTrue,
    );
    expect(
      RegExp(pattern).hasMatch('/// mentions activeMetadataSourceProvider'),
      isFalse,
      reason: 'prose that names it is not a bypass',
    );
  });
}
