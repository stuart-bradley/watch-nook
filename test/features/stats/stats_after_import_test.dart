import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_dao.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/merge_applier.dart';
import 'package:watch_nook/core/import_export/import/resolver.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';

/// #34 — a **characterization** test for the import seam, not an aspiration.
///
/// `MergeApplier._episodeMarks` says it outright: *"an export knows what you
/// watched, never how long it ran. Imported history therefore contributes to
/// watch counts but not to watch time — the stats invariant forbids
/// back-filling it from the disposable cache."* And the `Resolver` yields a
/// `MediaSearchResult`, which carries neither runtime nor genres, so there is
/// nothing to snapshot onto the item either.
///
/// So a library populated **only by import** legitimately shows: real counts, a
/// decade breakdown wherever the export gave a year, **zero hours**, and **no
/// genres** — plus `hasMissingData`, which is the whole reason the stats screen
/// carries a footnote instead of letting the user read "0 h" as a bug.
///
/// This test pins all five facts in one place. It is *meant* to go red the day
/// the enrichment follow-up lands (resolve `MediaDetails` at import time),
/// forcing whoever does it to update the contract here rather than discover the
/// seam through a support ticket.
///
/// Records are hand-built with an explicit `year` rather than driven off the
/// TV Time fixture: `tv_time_importer.dart` derives a year only from a
/// `"(YYYY)"` title suffix, so a re-trim of that fixture could quietly make the
/// decade assertion vacuous.
void main() {
  late AppDatabase db;
  late LibraryDao dao;
  late MergeApplier applier;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = LibraryDao(db);
    applier = MergeApplier(dao: dao, sourceKind: MetadataSourceKind.tmdb);
  });
  tearDown(() => db.close());

  final now = DateTime(2026, 7, 9, 12);

  test(
    'an imported library has counts and decades, but no hours or genres',
    () async {
      await applier.apply(const [
        Auto(
          ImportRecord(
            mediaType: MediaType.tv,
            title: 'Mr. Robot',
            year: 2015,
            tmdbId: 62560,
            watches: [
              ImportWatch(season: 1, episode: 1),
              ImportWatch(season: 1, episode: 2),
            ],
          ),
        ),
        Auto(
          ImportRecord(
            mediaType: MediaType.movie,
            title: 'Whiplash',
            year: 2014,
            tmdbId: 244786,
            watches: [ImportWatch()],
          ),
        ),
      ]);

      final stats = statsFrom(await dao.watchAllEvents().first, now);

      // Counts are complete — the export knew exactly what you watched.
      expect(stats.episodesWatched, 2);
      expect(stats.moviesWatched, 1);
      expect(stats.isEmpty, isFalse);

      // Decades survive, because the export carried a year.
      expect(stats.byDecade, const [StatBucket('2010s', 3)]);

      // Hours and genres do not, and never should be back-filled from cache.
      expect(stats.timeWatched, Duration.zero);
      expect(stats.byGenre, isEmpty);

      // ...so the screen tells the user, rather than showing a bare "0 h".
      expect(stats.hasMissingData, isTrue);
    },
  );
}
