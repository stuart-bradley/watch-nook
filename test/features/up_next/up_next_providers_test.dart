import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/up_next/data/up_next_providers.dart';

/// #21 — upcoming/calendar, tracked only. Adversarial throughout: every test is
/// shaped as "what does the regression look like?" — an untracked show leaking
/// in, a dropped show still polled, a *returning* completed show wrongly
/// skipped, a post-switch row fetched with the wrong backend's id, an already
/// aired episode lingering, and the week boundary off by one.
///
/// Rows come from a real in-memory Drift DB, so the column wiring (which id
/// column the active backend reads) is exercised rather than mocked.

/// Returns [episodes] from `upcomingForTracked` and records the ids it was
/// asked for, so a test can prove untracked shows are never even requested.
class _FakeSource implements MetadataSource {
  _FakeSource(this.episodes);

  final List<UpcomingEpisode> episodes;
  List<int>? requestedIds;
  int calls = 0;

  @override
  Future<List<UpcomingEpisode>> upcomingForTracked(
    List<int> showSourceIds,
  ) async {
    calls++;
    requestedIds = showSourceIds;
    return episodes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Every call throws — the offline path.
class _ThrowingSource implements MetadataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('offline: upcoming has no cache-first stream');
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  // A Thursday. The window is [2026-07-09 00:00, 2026-07-16 00:00).
  final now = DateTime(2026, 7, 9, 10, 30);

  Future<LibraryItem> seed({
    required String title,
    MediaType type = MediaType.tv,
    TrackStatus status = TrackStatus.watching,
    MetadataSourceKind recordedSource = MetadataSourceKind.tmdb,
    int? tmdbId,
    int? tvdbId,
    String? showStatus,
  }) async {
    final id = await db.libraryDao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: type,
        recordedSource: recordedSource,
        title: title,
        trackStatus: status,
        addedAt: now,
        updatedAt: now,
        tmdbId: Value(tmdbId),
        tvdbId: Value(tvdbId),
        showStatus: Value(showStatus),
      ),
    );
    return (await db.libraryDao.getItem(id))!;
  }

  UpcomingEpisode airing(
    DateTime airDate, {
    int? tmdbId,
    int? tvdbId,
    int season = 2,
    int episode = 5,
    String? title,
  }) => UpcomingEpisode(
    episode: EpisodeInfo(
      seasonNumber: season,
      episodeNumber: episode,
      title: title,
    ),
    airDate: airDate,
    tmdbId: tmdbId,
    tvdbId: tvdbId,
  );

  group('trackedShowsForUpcoming', () {
    test('keeps watching / watchlist / on-hold shows', () async {
      final items = [
        // `seed` defaults to `watching`.
        await seed(title: 'A', tmdbId: 1),
        await seed(title: 'B', status: TrackStatus.watchlist, tmdbId: 2),
        await seed(title: 'C', status: TrackStatus.onHold, tmdbId: 3),
      ];

      final tracked = trackedShowsForUpcoming(items, MetadataSourceKind.tmdb);

      expect(tracked.map((s) => s.title), ['A', 'B', 'C']);
      expect(tracked.map((s) => s.sourceId), [1, 2, 3]);
    });

    test('drops a dropped show', () async {
      final items = [
        await seed(title: 'Dropped', status: TrackStatus.dropped, tmdbId: 1),
      ];

      expect(trackedShowsForUpcoming(items, MetadataSourceKind.tmdb), isEmpty);
    });

    test('drops a completed show that has ended', () async {
      final items = [
        await seed(
          title: 'Ended',
          status: TrackStatus.completed,
          tmdbId: 1,
          showStatus: 'Ended',
        ),
      ];

      expect(trackedShowsForUpcoming(items, MetadataSourceKind.tmdb), isEmpty);
    });

    test('keeps a completed show that is still returning — the whole point of '
        'the tab is its next season', () async {
      final items = [
        await seed(
          title: 'Returning',
          status: TrackStatus.completed,
          tmdbId: 1,
          showStatus: 'Returning Series',
        ),
      ];

      expect(
        trackedShowsForUpcoming(items, MetadataSourceKind.tmdb).single.title,
        'Returning',
      );
    });

    test('drops movies — upcoming is shows-only in M2', () async {
      final items = [
        await seed(title: 'Dune', type: MediaType.movie, tmdbId: 1),
      ];

      expect(trackedShowsForUpcoming(items, MetadataSourceKind.tmdb), isEmpty);
    });

    test('drops a row recorded against the other backend — its id column holds '
        "the other catalogue's id", () async {
      final items = [
        await seed(
          title: 'Relinked',
          recordedSource: MetadataSourceKind.tvdb,
          tvdbId: 77,
        ),
      ];

      expect(trackedShowsForUpcoming(items, MetadataSourceKind.tmdb), isEmpty);
    });

    test('drops a row with no id for the active backend', () async {
      final items = [await seed(title: 'Manual entry')];

      expect(trackedShowsForUpcoming(items, MetadataSourceKind.tmdb), isEmpty);
    });

    test('reads tvdbId when TVDB is the active backend', () async {
      final items = [
        await seed(
          title: 'Severance',
          recordedSource: MetadataSourceKind.tvdb,
          tvdbId: 371980,
        ),
      ];

      expect(
        trackedShowsForUpcoming(items, MetadataSourceKind.tvdb).single.sourceId,
        371980,
      );
    });
  });

  group('upcomingEntriesThisWeek', () {
    const severance = (sourceId: 95396, itemId: 1, title: 'Severance');
    final byShowId = {severance.sourceId: severance};

    List<UpcomingEntry> entries(
      List<UpcomingEpisode> episodes, {
      MetadataSourceKind backend = MetadataSourceKind.tmdb,
      Map<int, TrackedShow>? shows,
    }) => upcomingEntriesThisWeek(
      episodes,
      shows ?? byShowId,
      backend: backend,
      now: now,
    );

    test("an untracked show's episode never appears, whatever the source "
        'returns', () {
      final result = entries([
        airing(DateTime(2026, 7, 10), tmdbId: 999999),
      ]);

      expect(result, isEmpty);
    });

    test('an episode that already aired is dropped', () {
      final result = entries([
        airing(DateTime(2026, 7, 8), tmdbId: severance.sourceId),
      ]);

      expect(result, isEmpty);
    });

    test('an episode airing earlier today is kept — the window opens at local '
        'midnight, not at `now`', () {
      final result = entries([
        airing(DateTime(2026, 7, 9), tmdbId: severance.sourceId),
      ]);

      expect(result.single.showTitle, 'Severance');
    });

    test('the window is 7 days, end-exclusive: day 6 in, day 7 out', () {
      final within = entries([
        airing(DateTime(2026, 7, 15), tmdbId: severance.sourceId),
      ]);
      final beyond = entries([
        airing(DateTime(2026, 7, 16), tmdbId: severance.sourceId),
      ]);

      expect(within, hasLength(1));
      expect(beyond, isEmpty);
    });

    test('entries come back chronological regardless of source order', () {
      const other = (sourceId: 1399, itemId: 2, title: 'Andor');
      final result = entries(
        [
          airing(DateTime(2026, 7, 14), tmdbId: severance.sourceId),
          airing(DateTime(2026, 7, 10), tmdbId: other.sourceId),
          airing(DateTime(2026, 7, 12), tmdbId: severance.sourceId),
        ],
        shows: {severance.sourceId: severance, other.sourceId: other},
      );

      expect(result.map((e) => e.upcoming.airDate), [
        DateTime(2026, 7, 10),
        DateTime(2026, 7, 12),
        DateTime(2026, 7, 14),
      ]);
    });

    test('joins on tvdbId when TVDB is the active backend — a matching tmdbId '
        'must not be used', () {
      const show = (sourceId: 371980, itemId: 1, title: 'Severance');
      final result = entries(
        [airing(DateTime(2026, 7, 10), tmdbId: 371980)],
        backend: MetadataSourceKind.tvdb,
        shows: {show.sourceId: show},
      );

      expect(result, isEmpty);
    });
  });

  group('groupByAirDay', () {
    test('buckets by local day, chronologically, keyed at midnight', () {
      const show = (sourceId: 1, itemId: 1, title: 'Severance');
      final result = groupByAirDay(
        upcomingEntriesThisWeek(
          [
            airing(DateTime(2026, 7, 10, 21), tmdbId: 1),
            airing(DateTime(2026, 7, 10, 22), tmdbId: 1, episode: 6),
            airing(DateTime(2026, 7, 12, 9), tmdbId: 1, episode: 7),
          ],
          {show.sourceId: show},
          backend: MetadataSourceKind.tmdb,
          now: now,
        ),
      );

      expect(result.keys, [DateTime(2026, 7, 10), DateTime(2026, 7, 12)]);
      expect(result[DateTime(2026, 7, 10)], hasLength(2));
      expect(result[DateTime(2026, 7, 12)], hasLength(1));
    });
  });

  group('episodeLabel', () {
    test('adds the episode title when the backend supplied one', () {
      expect(
        episodeLabel(
          const EpisodeInfo(
            seasonNumber: 2,
            episodeNumber: 5,
            title: 'Cold Harbor',
          ),
        ),
        'S2E5 · Cold Harbor',
      );
    });

    test('falls back to the aired coordinate alone', () {
      expect(
        episodeLabel(const EpisodeInfo(seasonNumber: 2, episodeNumber: 5)),
        'S2E5',
      );
    });
  });

  group('upcomingThisWeekProvider', () {
    ProviderContainer containerWith(MetadataSource source) {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
          activeMetadataSourceProvider.overrideWithValue(source),
        ],
      );
      addTearDown(container.dispose);
      // A bare `container.read(p.future)` opens and immediately closes its
      // subscription, so autoDispose tears the chain down while the Drift
      // stream behind `trackedShowsProvider` is still loading. Hold a listener
      // open for the test's lifetime instead.
      container.listen(upcomingThisWeekProvider, (_, _) {});
      return container;
    }

    test('populates this week from tracked shows only, and never asks the '
        'source about an untracked one (acceptance)', () async {
      final tracked = await seed(title: 'Severance', tmdbId: 95396);
      await seed(title: 'Dropped', status: TrackStatus.dropped, tmdbId: 1399);
      await seed(title: 'Dune', type: MediaType.movie, tmdbId: 438631);

      final source = _FakeSource([
        airing(
          DateTime(2026, 7, 10),
          tmdbId: 95396,
          title: 'Cold Harbor',
        ),
        // The source volunteers an episode for a show we never tracked.
        airing(DateTime(2026, 7, 11), tmdbId: 999999),
      ]);
      final container = containerWith(source);

      final entries = await withClock(
        Clock.fixed(now),
        () => container.read(upcomingThisWeekProvider.future),
      );

      expect(source.requestedIds, [95396]);
      expect(entries, hasLength(1));
      expect(entries.single.showTitle, 'Severance');
      expect(entries.single.itemId, tracked.id);
      expect(
        episodeLabel(entries.single.upcoming.episode),
        'S2E5 · Cold Harbor',
      );
    });

    test('no tracked shows → empty, with no network call at all', () async {
      await seed(title: 'Dropped', status: TrackStatus.dropped, tmdbId: 1399);
      final container = containerWith(_ThrowingSource());

      final entries = await withClock(
        Clock.fixed(now),
        () => container.read(upcomingThisWeekProvider.future),
      );

      expect(entries, isEmpty);
    });

    test('a throwing source surfaces an error state, not a crash', () async {
      await seed(title: 'Severance', tmdbId: 95396);
      final container = containerWith(_ThrowingSource());

      // Matched on the message, not just `throwsStateError`: Riverpod's own
      // "disposed during loading state" failure is *also* a StateError, and
      // would let this test pass without ever reaching the source.
      await expectLater(
        withClock(
          Clock.fixed(now),
          () => container.read(upcomingThisWeekProvider.future),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('offline'),
          ),
        ),
      );
    });
  });
}
