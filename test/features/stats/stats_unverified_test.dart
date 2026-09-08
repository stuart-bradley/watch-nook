import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';

import '../../support/library_fixtures.dart' as seed;

/// **Unverified is a caveat about a position, never about history** (CONTEXT.md
/// axis 2). The backend switch does not touch `WatchEvents`, and each event's
/// runtime was snapshotted at mark-time, so an Unverified title's contribution
/// to the totals is exactly as accurate as a healthy one's.
///
/// This is the guard against someone later deciding a title the app "cannot
/// vouch for" should be excluded from the numbers — which would take history
/// away from the user on the strength of a flag that explicitly promises not
/// to. It runs through the real stats read (`watchAllEvents` + [statsFrom]), so
/// an exclusion added in either the query or the fold trips it.
void main() {
  late AppDatabase db;
  final now = DateTime(2026, 7, 9, 12);

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<StatsSnapshot> snapshot() async =>
      statsFrom(await db.libraryDao.watchAllEvents().first, now);

  test('an Unverified title contributes as a healthy one does', () async {
    // Two shows identical in every stats-relevant field. The only difference is
    // the flag, so any divergence in the snapshot is caused by the flag alone.
    Future<void> add({
      required String title,
      required int tmdbId,
      required bool unverified,
    }) => seed.seedShow(
      db,
      title: title,
      tmdbId: tmdbId,
      year: 2022,
      genresCsv: 'Drama',
      runtimeMinutes: 45,
      relinkFailed: unverified,
      now: now,
      watched: const [(1, 1), (1, 2)],
    );

    await add(title: 'Healthy Show', tmdbId: 1, unverified: false);
    final healthy = await snapshot();

    await add(title: 'Unverified Show', tmdbId: 2, unverified: true);
    final both = await snapshot();

    expect(
      healthy.episodesWatched,
      2,
      reason: 'sanity: the healthy show landed two episodes',
    );
    expect(
      both.episodesWatched,
      healthy.episodesWatched * 2,
      reason: 'the episodes were watched; the flag doubts the position only',
    );
    expect(both.timeWatched, healthy.timeWatched * 2);
    // The buckets count watch events, so two shows of two episodes each is 4.
    expect(
      both.byGenre,
      const [StatBucket('Drama', 4)],
      reason: 'an Unverified title is still a Drama the user watched',
    );
    expect(both.byDecade, const [StatBucket('2020s', 4)]);
  });
}
