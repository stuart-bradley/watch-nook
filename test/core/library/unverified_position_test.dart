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

  // The detail notice has three variants, one per reason the episode list is
  // or isn't on screen. What a wrong set looks like: two variants collapse into
  // one (the relink loop: a not-loaded row told to relink), a variant drops the
  // shared opening and loses "your history is intact", or copy that works on
  // screen reads as noise aloud.
  //
  // Proved to fail first: making the not-loaded variant the Stranded one (the
  // previous single "no list" notice) reddens "distinct" and "only Stranded
  // mentions Settings"; restoring the old em-dash copy reddens "plain words".
  group('the detail notice variants', () {
    const variants = {
      'list shown': unverifiedPositionNoticeListShown,
      'Stranded': unverifiedPositionNoticeStranded,
      'Unlinked': unverifiedPositionNoticeUnlinked,
      'not loaded': unverifiedPositionNoticeNotLoaded,
    };

    test('are distinct', () {
      expect(variants.values.toSet(), hasLength(variants.length));
    });

    test('share the opening, then close with one sentence of their own', () {
      for (final MapEntry(:key, :value) in variants.entries) {
        expect(value, startsWith(unverifiedPositionNoticeOpening), reason: key);
        final closing = value.substring(unverifiedPositionNoticeOpening.length);
        expect(
          RegExp(r'^ [A-Z][^.]*\.$').hasMatch(closing),
          isTrue,
          reason: '$key closes with exactly one sentence, got "$closing"',
        );
      }
    });

    test('only the Stranded variant sends the user to Settings', () {
      // A relink skips a row already on the active backend, so a not-loaded
      // row sent to Settings comes straight back to the same advice.
      expect(unverifiedPositionNoticeStranded, contains('Settings'));
      expect(unverifiedPositionNoticeNotLoaded, isNot(contains('Settings')));
      // Nor does it help an Unlinked row, and Settings offers it no relink.
      expect(unverifiedPositionNoticeUnlinked, isNot(contains('Settings')));
      expect(unverifiedPositionNoticeListShown, isNot(contains('Settings')));
    });

    test("are plain words, in the app's own vocabulary", () {
      for (final MapEntry(:key, :value) in variants.entries) {
        // Letters and ordinary punctuation only, so a screen reader says it
        // as written: no dashes, glyphs or symbols to be read out or skipped.
        expect(
          RegExp(r"^[A-Za-z ,.']+$").hasMatch(value),
          isTrue,
          reason: '$key: "$value"',
        );
        // Settings calls this event "a different metadata provider". A second
        // name for it makes a user think a second thing happened.
        expect(value.toLowerCase(), isNot(contains('catalogue')), reason: key);
        expect(value, contains('metadata provider'), reason: key);
      }
    });
  });
}
