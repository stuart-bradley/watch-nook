import 'package:flutter/foundation.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

/// One watch event joined to the library item it belongs to — the row shape
/// `LibraryDao.watchAllEvents()` streams, and the only input [statsFrom] takes.
typedef WatchRow = (WatchEvent, LibraryItem);

/// A labelled count in a stats breakdown (one genre, or one decade).
@immutable
class StatBucket {
  /// Creates a [StatBucket].
  const StatBucket(this.label, this.count);

  /// Display label — a genre name, or a decade like `"2010s"`.
  final String label;

  /// How many watch events fell in this bucket.
  final int count;

  @override
  bool operator ==(Object other) =>
      other is StatBucket && other.label == label && other.count == count;

  @override
  int get hashCode => Object.hash(label, count);

  @override
  String toString() => 'StatBucket($label, $count)';
}

/// Everything the stats screen shows, derived from the **user-owned tables
/// alone** (`WatchEvents` + `LibraryItems`).
///
/// The stats-snapshot invariant (CLAUDE.md): runtime is snapshotted onto
/// `WatchEvents` at mark-time and genres/year onto `LibraryItems` at add-time,
/// so a figure here never depends on the disposable metadata cache. Wiping
/// `CachedMedia`/`CachedEpisodes` must leave this object identical — that is
/// #34's acceptance criterion, pinned by `stats_cache_eviction_test.dart`.
@immutable
class StatsSnapshot {
  /// Creates a [StatsSnapshot].
  const StatsSnapshot({
    required this.episodesWatched,
    required this.moviesWatched,
    required this.rewatches,
    required this.timeWatched,
    required this.streakDays,
    required this.byGenre,
    required this.byDecade,
    required this.hasMissingData,
  });

  /// A library with no watch history at all.
  static const empty = StatsSnapshot(
    episodesWatched: 0,
    moviesWatched: 0,
    rewatches: 0,
    timeWatched: Duration.zero,
    streakDays: 0,
    byGenre: [],
    byDecade: [],
    hasMissingData: false,
  );

  /// Non-rewatch watch events on TV items — matches `LibraryItems.watchedCount`
  /// semantics (the idempotent marker), so a double-tap never inflates it.
  final int episodesWatched;

  /// Non-rewatch watch events on movie items.
  final int moviesWatched;

  /// Watch events with `isRewatch = true`, across both media types.
  final int rewatches;

  /// Total time watched, **rewatches included** — you really did watch those
  /// hours, even if they didn't advance your progress.
  final Duration timeWatched;

  /// Consecutive local calendar days, ending today or yesterday, on which at
  /// least one dated watch event landed. See [statsFrom] for the grace rule.
  final int streakDays;

  /// Genre breakdown, most-watched first (ties broken alphabetically).
  final List<StatBucket> byGenre;

  /// Decade breakdown, newest decade first.
  final List<StatBucket> byDecade;

  /// True when at least one watch event contributed no runtime, or its item
  /// carried no genres. Drives the honesty footnote on the stats screen: an
  /// imported history knows *what* you watched but never *how long* it ran
  /// (`merge_applier.dart` — `_episodeMarks`), and so does a title added while
  /// offline. Without the footnote a user reads "0 h" as a bug.
  final bool hasMissingData;

  /// Nothing watched yet. Rewatch-only history is impossible in practice (a
  /// rewatch presupposes a watch), so the two counters are the whole test.
  bool get isEmpty => episodesWatched == 0 && moviesWatched == 0;

  @override
  bool operator ==(Object other) =>
      other is StatsSnapshot &&
      other.episodesWatched == episodesWatched &&
      other.moviesWatched == moviesWatched &&
      other.rewatches == rewatches &&
      other.timeWatched == timeWatched &&
      other.streakDays == streakDays &&
      other.hasMissingData == hasMissingData &&
      _sameBuckets(other.byGenre, byGenre) &&
      _sameBuckets(other.byDecade, byDecade);

  @override
  int get hashCode => Object.hash(
    episodesWatched,
    moviesWatched,
    rewatches,
    timeWatched,
    streakDays,
    hasMissingData,
    Object.hashAll(byGenre),
    Object.hashAll(byDecade),
  );

  static bool _sameBuckets(List<StatBucket> a, List<StatBucket> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// How far back the streak walk will go before giving up. A year of unbroken
/// daily watching is already implausible; the cap stops a corrupt future date
/// from spinning the loop.
const _maxStreakLookback = 366;

/// Folds every `(event, item)` row into a [StatsSnapshot]. Pure: no DB, no
/// widgets, no `DateTime.now()` — [now] is injected (`clock.now()` in the
/// provider) so the streak is testable against a pinned today.
///
/// Counting rules — this is the test contract:
/// - **Counts** use non-rewatch rows; **hours** include rewatches.
/// - Runtime per event coalesces `event.runtimeMinutes ?? item.runtimeMinutes`,
///   then contributes zero. The item fallback exists for the *mixed* case — a
///   title added via search (so the item carries a runtime) whose episodes were
///   later marked by an import (so the event does not). It is not a fix for a
///   pure import, where both are null; that shows up as
///   [StatsSnapshot.hasMissingData].
/// - Both breakdowns are **episode-weighted**: a 62-episode drama adds 62 to
///   each of its genres and 62 to its decade. They answer *"where did my hours
///   go?"*, matching the headline cards above them — not *"what's in my
///   library?"*. Rewatches count here too, for the same reason they count
///   toward hours.
/// - A null `genresCsv` or null `year` is **omitted**, never bucketed as
///   "Unknown" — an absent fact is not a category.
/// - **Streak**: consecutive local calendar days walking back from [now]'s day.
///   If today has no event but yesterday does, the streak stands (you haven't
///   watched *yet* today). Undated events (`watchedAt == null`, i.e. imported)
///   never contribute; future-dated ones can't, since the walk only goes back.
///   Days are bucketed on the **local** `(y, m, d)` after `toLocal()`, and the
///   walk steps by calendar arithmetic rather than `Duration` — both so a DST
///   boundary can't drop or double a day.
StatsSnapshot statsFrom(Iterable<WatchRow> rows, DateTime now) {
  var episodesWatched = 0;
  var moviesWatched = 0;
  var rewatches = 0;
  var minutes = 0;
  var hasMissingData = false;
  final genres = <String, int>{};
  final decades = <int, int>{};
  final watchedDays = <DateTime>{};

  for (final (event, item) in rows) {
    if (event.isRewatch) {
      rewatches++;
    } else if (item.mediaType == MediaType.movie) {
      moviesWatched++;
    } else {
      episodesWatched++;
    }

    final runtime = event.runtimeMinutes ?? item.runtimeMinutes;
    if (runtime == null) {
      hasMissingData = true;
    } else {
      minutes += runtime;
    }

    final csv = item.genresCsv;
    if (csv == null || csv.trim().isEmpty) {
      hasMissingData = true;
    } else {
      for (final raw in csv.split(',')) {
        final genre = raw.trim();
        if (genre.isEmpty) continue;
        genres.update(genre, (n) => n + 1, ifAbsent: () => 1);
      }
    }

    if (item.year case final year?) {
      decades.update(year - year % 10, (n) => n + 1, ifAbsent: () => 1);
    }

    if (event.watchedAt case final at?) {
      watchedDays.add(_localDay(at));
    }
  }

  final byGenre = genres.entries.map((e) => StatBucket(e.key, e.value)).toList()
    ..sort(_byCountThenLabel);
  final byDecade =
      decades.entries.map((e) => StatBucket('${e.key}s', e.value)).toList()
        ..sort((a, b) => b.label.compareTo(a.label));

  return StatsSnapshot(
    episodesWatched: episodesWatched,
    moviesWatched: moviesWatched,
    rewatches: rewatches,
    timeWatched: Duration(minutes: minutes),
    streakDays: _streakDays(watchedDays, now),
    byGenre: byGenre,
    byDecade: byDecade,
    hasMissingData: hasMissingData,
  );
}

int _byCountThenLabel(StatBucket a, StatBucket b) {
  final byCount = b.count.compareTo(a.count);
  return byCount != 0 ? byCount : a.label.compareTo(b.label);
}

/// Midnight of [at]'s **local** calendar day. A `watchedAt` stored as UTC
/// 23:00Z belongs to whatever local day the user was living in.
DateTime _localDay(DateTime at) {
  final local = at.toLocal();
  return DateTime(local.year, local.month, local.day);
}

int _streakDays(Set<DateTime> watchedDays, DateTime now) {
  final today = _localDay(now);
  // Grace: a streak survives a today on which you haven't watched *yet*.
  var cursor = watchedDays.contains(today)
      ? today
      : DateTime(today.year, today.month, today.day - 1);

  var streak = 0;
  while (streak < _maxStreakLookback && watchedDays.contains(cursor)) {
    streak++;
    // Calendar arithmetic, not `subtract(Duration(days: 1))` — a DST shift
    // makes a "day" 23 or 25 hours long and would skip or repeat a date.
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }
  return streak;
}
