import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';

/// #34 / US-12 — the pure fold. No DB, no widget tree: [statsFrom] is
/// arithmetic over rows, and every counting rule in its dartdoc is a test here.
///
/// Adversarial framing — the bugs these are written against:
/// - a rewatch inflates `episodesWatched` (it must only add hours);
/// - hours *exclude* rewatches (you watched them, they count);
/// - a null runtime on both event and item throws instead of contributing 0;
/// - the item-runtime fallback is forgotten, so a search-added title whose
///   episodes were bulk-marked by an import silently loses its hours;
/// - `"Drama,Sci-Fi"` becomes one genre named `"Drama,Sci-Fi"`;
/// - `1999` buckets as `"1990s"` but `2000` also lands in `"1990s"` (off-by-one
///   on the modulo);
/// - a null genre/year is bucketed as `"Unknown"` rather than omitted.
void main() {
  final addedAt = DateTime(2026);

  var nextItemId = 0;
  var nextEventId = 0;

  LibraryItem item({
    MediaType mediaType = MediaType.tv,
    int? year,
    String? genresCsv,
    int? runtimeMinutes,
  }) => LibraryItem(
    id: ++nextItemId,
    mediaType: mediaType,
    recordedSource: MetadataSourceKind.tmdb,
    title: 'Title $nextItemId',
    year: year,
    genresCsv: genresCsv,
    runtimeMinutes: runtimeMinutes,
    trackStatus: TrackStatus.watching,
    watchedCount: 0,
    addedAt: addedAt,
    updatedAt: addedAt,
    relinkFailed: false,
  );

  WatchEvent event({
    int libraryItemId = 1,
    bool isRewatch = false,
    int? runtimeMinutes,
    DateTime? watchedAt,
  }) => WatchEvent(
    id: ++nextEventId,
    libraryItemId: libraryItemId,
    isRewatch: isRewatch,
    runtimeMinutes: runtimeMinutes,
    watchedAt: watchedAt,
  );

  final now = DateTime(2026, 7, 9, 12);

  group('counts', () {
    test('split episodes, movies and rewatches by kind, not by row', () {
      final show = item();
      final film = item(mediaType: MediaType.movie);

      final stats = statsFrom([
        (event(), show),
        (event(), show),
        (event(isRewatch: true), show),
        (event(), film),
        (event(isRewatch: true), film),
      ], now);

      expect(stats.episodesWatched, 2);
      expect(stats.moviesWatched, 1);
      // Both rewatches, whichever media type they belong to.
      expect(stats.rewatches, 2);
      expect(stats.isEmpty, isFalse);
    });

    test('no watch events at all is empty', () {
      final stats = statsFrom(const [], now);
      expect(stats, StatsSnapshot.empty);
      expect(stats.isEmpty, isTrue);
    });
  });

  group('hours', () {
    test('sum the event runtimes, rewatches included', () {
      final show = item();
      final stats = statsFrom([
        (event(runtimeMinutes: 40), show),
        (event(runtimeMinutes: 40), show),
        (event(isRewatch: true, runtimeMinutes: 40), show),
      ], now);

      // 120 minutes: the rewatch's 40 counts — you really did watch them.
      expect(stats.timeWatched, const Duration(minutes: 120));
      expect(stats.episodesWatched, 2);
    });

    test("fall back to the item's runtime when the event carries none", () {
      // The mixed case: added via search (item has a runtime), episodes later
      // marked by an import (the event does not).
      final show = item(runtimeMinutes: 25, genresCsv: 'Comedy');
      final stats = statsFrom([(event(), show)], now);

      expect(stats.timeWatched, const Duration(minutes: 25));
      // Nothing is actually missing — the fallback resolved it.
      expect(stats.hasMissingData, isFalse);
    });

    test('the event runtime wins over the item runtime', () {
      final show = item(runtimeMinutes: 25, genresCsv: 'Comedy');
      final stats = statsFrom([(event(runtimeMinutes: 60), show)], now);
      expect(stats.timeWatched, const Duration(minutes: 60));
    });

    test('both runtimes null contributes zero and does not throw', () {
      final show = item(genresCsv: 'Drama');
      final stats = statsFrom([
        (event(), show),
        (event(runtimeMinutes: 30), show),
      ], now);

      expect(stats.timeWatched, const Duration(minutes: 30));
      expect(stats.episodesWatched, 2);
      // ...and it says so, rather than presenting 30 minutes as the whole
      // truth.
      expect(stats.hasMissingData, isTrue);
    });
  });

  group('hasMissingData', () {
    test('a missing genre alone raises it', () {
      final show = item(runtimeMinutes: 40);
      expect(statsFrom([(event(), show)], now).hasMissingData, isTrue);
    });

    test('an empty genre string is missing, not a genre named ""', () {
      final show = item(runtimeMinutes: 40, genresCsv: '   ');
      final stats = statsFrom([(event(), show)], now);
      expect(stats.hasMissingData, isTrue);
      expect(stats.byGenre, isEmpty);
    });

    test('a fully-snapshotted library raises nothing', () {
      final show = item(runtimeMinutes: 40, genresCsv: 'Drama', year: 2015);
      expect(statsFrom([(event(), show)], now).hasMissingData, isFalse);
    });
  });

  group('byGenre', () {
    test('splits a CSV and counts each genre once per watch event', () {
      final drama = item(genresCsv: 'Drama, Sci-Fi', runtimeMinutes: 40);
      final comedy = item(genresCsv: 'Comedy', runtimeMinutes: 20);

      final stats = statsFrom([
        (event(), drama),
        (event(), drama),
        (event(), comedy),
      ], now);

      // Episode-weighted: two episodes of a 2-genre show add 2 to each.
      expect(stats.byGenre, const [
        StatBucket('Drama', 2),
        StatBucket('Sci-Fi', 2),
        StatBucket('Comedy', 1),
      ]);
    });

    test('rewatches count toward genres, matching the hours they add', () {
      final show = item(genresCsv: 'Drama', runtimeMinutes: 40);
      final stats = statsFrom([
        (event(), show),
        (event(isRewatch: true), show),
      ], now);
      expect(stats.byGenre, const [StatBucket('Drama', 2)]);
    });

    test('a null genre is omitted, never bucketed as Unknown', () {
      final stats = statsFrom([(event(), item())], now);
      expect(stats.byGenre, isEmpty);
    });

    test('ties break alphabetically so the order is deterministic', () {
      final show = item(genresCsv: 'Western,Action', runtimeMinutes: 40);
      final stats = statsFrom([(event(), show)], now);
      expect(stats.byGenre, const [
        StatBucket('Action', 1),
        StatBucket('Western', 1),
      ]);
    });
  });

  group('byDecade', () {
    test('buckets on the item year, newest decade first', () {
      LibraryItem from(int year) =>
          item(year: year, genresCsv: 'Drama', runtimeMinutes: 40);
      final nineties = from(1999);
      final noughties = from(2000);
      final tens = from(2015);

      final stats = statsFrom([
        (event(), nineties),
        (event(), noughties),
        (event(), noughties),
        (event(), tens),
      ], now);

      // 1999 → 1990s and 2000 → 2000s: the modulo boundary, not an off-by-one.
      expect(stats.byDecade, const [
        StatBucket('2010s', 1),
        StatBucket('2000s', 2),
        StatBucket('1990s', 1),
      ]);
    });

    test('a null year is omitted, never bucketed as Unknown', () {
      final stats = statsFrom([(event(), item(genresCsv: 'Drama'))], now);
      expect(stats.byDecade, isEmpty);
    });
  });
}
