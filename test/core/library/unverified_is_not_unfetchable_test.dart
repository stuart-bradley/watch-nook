import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/features/detail/data/detail_target.dart';

import '../../support/library_fixtures.dart' as seed;

/// **The two axes are independent** (CONTEXT.md). Unverified is a doubt about
/// what a stored coordinate *means*; it says nothing about whether the row's
/// ids are usable.
///
/// The tempting mistake is to read the flag as "something is wrong with this
/// title" and start withholding things: suppress the poster, refuse the fetch,
/// route it down the Stranded branch. Every one of those punishes the user for
/// a doubt about episode numbering by taking away a screen that was working,
/// and none of them makes the position any more certain.
///
/// A row that is Unverified *and* Stranded is a real combination and must
/// still be labelled Stranded for the reason it actually is one.
///
/// **Proved to fail first.** This guards behaviour that is correct today, so
/// the only way to know it bites is to break it: making `detailTargetOf` treat
/// `relinkFailed` as unfetchable reddens both tests. Without that check it
/// would be exactly the decoration this spec set out to stop shipping.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  const active = MetadataSourceKind.tmdb;

  test('an Unverified row on the active backend is still fetchable', () async {
    final item = await seed.seedShow(
      db,
      posterPath: '/poster.jpg',
      relinkFailed: true,
      watched: const [(1, 1)],
    );

    expect(
      detailTargetOf(item: item, result: null, active: active),
      isA<TrackedTitle>(),
      reason: 'the flag doubts the coordinate, not the id',
    );
    expect(item.refFor(active)?.id, item.tmdbId);
    expect(
      item.posterRef?.path,
      '/poster.jpg',
      reason: 'artwork is axis 1, and this row is on the active backend',
    );
  });

  test('Unverified and Stranded is Stranded for the Stranded reason', () async {
    final item = await seed.seedShow(
      db,
      source: MetadataSourceKind.tvdb,
      tmdbId: null,
      tvdbId: 371980,
      relinkFailed: true,
      watched: const [(1, 1)],
    );

    final target = detailTargetOf(item: item, result: null, active: active);
    expect(target, isA<StrandedTitle>());
    expect(
      (target as StrandedTitle).reason,
      Unfetchable.recordedAgainstAnotherBackend,
      reason: 'the reason is the backend it is on, never the Unverified flag',
    );
  });
}
