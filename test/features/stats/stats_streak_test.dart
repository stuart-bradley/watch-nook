import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';

/// #34 / US-12 — the streak walk, table-tested against a pinned `now`.
///
/// **Timezone hardening.** Pinning `now` is not enough on its own: a fixture
/// built as `now.subtract(Duration(days: n))` lands on a different *local* day
/// depending on the CI box's UTC offset and on whether a DST boundary fell in
/// between. Every fixture here is an explicit **local midday**, so no date is
/// within 12 hours of a day boundary in any zone, and the walk steps by
/// calendar arithmetic rather than `Duration`.
///
/// Adversarial framing — the bugs:
/// - the streak breaks the moment you haven't watched *yet today* (no grace);
/// - two events on one day count as a 2-day streak;
/// - an undated (imported) event silently extends it;
/// - a future-dated event extends it;
/// - a rewatch doesn't count (it is a watch, on a date — it counts);
/// - a `watchedAt` stored in UTC buckets by its UTC day, so a 23:00Z event
///   lands on the wrong side of midnight for a user west of Greenwich;
/// - a corrupt 400-day chain spins the loop forever.
void main() {
  /// Local midday on the given calendar day — never near a day boundary.
  DateTime midday(int year, int month, int day) =>
      DateTime(year, month, day, 12);

  final now = midday(2026, 7, 9);

  final show = LibraryItem(
    id: 1,
    mediaType: MediaType.tv,
    recordedSource: MetadataSourceKind.tmdb,
    title: 'Severance',
    genresCsv: 'Drama',
    runtimeMinutes: 45,
    trackStatus: TrackStatus.watching,
    watchedCount: 0,
    addedAt: DateTime(2026),
    updatedAt: DateTime(2026),
    relinkFailed: false,
  );

  var nextEventId = 0;
  WatchEvent watched(DateTime? at, {bool isRewatch = false}) => WatchEvent(
    id: ++nextEventId,
    libraryItemId: 1,
    isRewatch: isRewatch,
    runtimeMinutes: 45,
    watchedAt: at,
  );

  int streakOf(Iterable<DateTime?> days) =>
      statsFrom([for (final d in days) (watched(d), show)], now).streakDays;

  test('no events is no streak', () {
    expect(statsFrom(const [], now).streakDays, 0);
  });

  test('watched today only is a 1-day streak', () {
    expect(streakOf([midday(2026, 7, 9)]), 1);
  });

  test('today and yesterday is a 2-day streak', () {
    expect(streakOf([midday(2026, 7, 9), midday(2026, 7, 8)]), 2);
  });

  test('yesterday but not yet today still counts — the grace rule', () {
    // You haven't watched *yet* today; the streak is not dead until you skip a
    // whole day. Without the grace, every user's streak reads 0 each morning.
    expect(streakOf([midday(2026, 7, 8), midday(2026, 7, 7)]), 2);
  });

  test('a one-day gap breaks the streak at the gap', () {
    expect(
      streakOf([
        midday(2026, 7, 9), // today
        midday(2026, 7, 8), // yesterday
        // 7 July missing — the walk stops here.
        midday(2026, 7, 6),
        midday(2026, 7, 5),
      ]),
      2,
    );
  });

  test('two days ago with nothing since is no streak at all', () {
    expect(streakOf([midday(2026, 7, 7)]), 0);
  });

  test('two events on the same day count once', () {
    expect(streakOf([midday(2026, 7, 9), midday(2026, 7, 9)]), 1);
  });

  test('a rewatch extends the streak — it is a watch, on a date', () {
    final stats = statsFrom([
      (watched(midday(2026, 7, 9), isRewatch: true), show),
      (watched(midday(2026, 7, 8)), show),
    ], now);
    expect(stats.streakDays, 2);
  });

  test('an undated (imported) event never contributes', () {
    expect(streakOf([midday(2026, 7, 9), null, midday(2026, 7, 7)]), 1);
  });

  test('a future-dated event does not extend the streak', () {
    expect(streakOf([midday(2026, 7, 20), midday(2026, 7, 9)]), 1);
  });

  test('a future-dated event alone is no streak', () {
    expect(streakOf([midday(2026, 7, 20)]), 0);
  });

  test('a watchedAt stored in UTC buckets by its LOCAL day', () {
    // 23:00 *local* on 8 July, expressed as an instant. Bucketing on the UTC
    // calendar day would put this on the 8th or the 9th depending on the box's
    // offset; bucketing on the local day always says "the 8th".
    final lateOn8th = midday(2026, 7, 8).add(const Duration(hours: 11));
    expect(lateOn8th.day, 8, reason: 'fixture sanity: 23:00 local on the 8th');

    expect(streakOf([midday(2026, 7, 9), lateOn8th.toUtc()]), 2);
  });

  test('an unbroken 400-day chain caps the walk at 366', () {
    final days = [for (var i = 0; i < 400; i++) midday(2026, 7, 9 - i)];
    expect(streakOf(days), 366);
  });
}
