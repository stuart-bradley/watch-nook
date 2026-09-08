import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/library/unverified_position.dart';

import '../../support/library_fixtures.dart' as seed;

/// The marker rule, driven over real rows (the prior art: the progress-label
/// and reference-mapping tests). No widgets — the rule is the thing under test;
/// the three surfaces only wire it up.
///
/// Adversarial framing — what a wrong rule looks like:
/// - the marker attaches to the *title* rather than the position, so an
///   Unverified movie or a never-started show is flagged for a coordinate that
///   does not exist and cannot be checked;
/// - the flag is read as "something is broken with this title", so it starts
///   gating fetches and the user loses artwork over an episode-numbering doubt;
/// - the wording is retyped at a surface and quietly drifts.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('hasUnverifiedPosition', () {
    test('an Unverified show with a position carries the marker', () async {
      final item = await seed.seedShow(
        db,
        relinkFailed: true,
        watched: const [(1, 1), (1, 2)],
      );
      expect(hasUnverifiedPosition(item), isTrue);
    });

    test('a healthy show with the same position does not', () async {
      final item = await seed.seedShow(db, watched: const [(1, 1), (1, 2)]);
      expect(hasUnverifiedPosition(item), isFalse);
    });

    test('an Unverified show with nothing watched does not', () async {
      // There is no coordinate on screen, so there is nothing to doubt and
      // nothing the user could go and check.
      final item = await seed.seedShow(db, relinkFailed: true);
      expect(hasUnverifiedPosition(item), isFalse);
    });

    test('an Unverified movie does not — it has no coordinate', () async {
      final item = await seed.seedMovie(db, relinkFailed: true, watched: true);
      expect(hasUnverifiedPosition(item), isFalse);
    });
  });

  group('markUnverifiedPosition', () {
    test('appends the marker, leaving the position itself intact', () {
      final marked = markUnverifiedPosition('S2E4', unverified: true);
      expect(marked, startsWith('S2E4'));
      expect(
        marked,
        isNot('S2E4'),
        reason: 'an unverified position must be visibly qualified',
      );
    });

    test('a verified position is returned untouched', () {
      expect(markUnverifiedPosition('S2E4', unverified: false), 'S2E4');
    });

    test('the marker is words, not a bare glyph', () {
      // A screen reader has to be able to say it, and a lone symbol in a grid
      // caption reads as decoration.
      final marker = markUnverifiedPosition(
        '',
        unverified: true,
      ).trim().replaceAll(RegExp('[^A-Za-z]'), '');
      expect(marker.length, greaterThan(3));
    });
  });
}
