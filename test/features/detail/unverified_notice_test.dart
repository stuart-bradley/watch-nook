import 'dart:async';

import 'package:clock/clock.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/library/unverified_position.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_source.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/detail/presentation/detail_screen.dart';

import '../../support/library_fixtures.dart' as seed;

/// The detail screen is where an Unverified position can finally be resolved:
/// the marker sits above the season list — the evidence the user needs — and
/// the dismiss is the first path this flag has ever had to being cleared by a
/// person.
///
/// Wiring coverage; the rule and every variant's wording live in
/// `unverified_position.dart` and the write is tested at the DAO. What is worth
/// proving here is that the screen picks the variant by the real reason the
/// list is or isn't there, offers the dismiss only beside the list, and that
/// tapping it really performs the write.
///
/// **Proved to fail first**: removing the notice from the build reddens the
/// list-shown and dismiss tests; showing it unconditionally (dropping the
/// `hasUnverifiedPosition` gate) reddens the absence test; making the DAO write
/// a no-op reddens the dismiss test. The variant tests record their own proofs.
///
/// This mounts over a real `AppDatabase` rather than a stub, against
/// ARCHITECTURE.md's widget-test rule. That rule guards one hazard — a live
/// Drift stream never quiescing under fake-async — and the hand-driven
/// controller below removes it. The write under test is the point of the
/// screen, so stubbing the DAO would leave nothing worth asserting.
///
/// The fake source serves details on request. `gate`, when given, holds them
/// back until the test completes it; `offline` fails every fetch, as having no
/// network does.
class _FakeSource implements MetadataSource {
  _FakeSource({this.gate, this.offline = false});

  final Completer<MediaDetails>? gate;
  final bool offline;

  @override
  Future<MediaDetails> showDetails(SourceRef ref) async {
    if (offline) throw Exception('offline');
    return gate?.future ?? _details;
  }

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(SourceRef show, int season) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _details = MediaDetails(
  kind: MediaKind.tv,
  title: 'Severance',
  genres: ['Drama'],
  seasons: [SeasonInfo(seasonNumber: 1, episodeCount: 2)],
  tmdbId: 95396,
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final fixed = Clock.fixed(DateTime(2026, 7, 9));

  /// Mounts the detail screen over the real DB, feeding the row through a
  /// controller rather than `watchItem`: a live Drift stream never quiesces
  /// under fake-async and would hang `pumpAndSettle` (the CLAUDE.md hazard).
  /// Re-emitting by hand after the write is exactly what the real stream does.
  ///
  /// [settle] false stops after one frame, for a screen still loading details:
  /// its progress bar animates forever, so `pumpAndSettle` would never return.
  Future<StreamController<LibraryItem?>> pump(
    WidgetTester tester,
    LibraryItem row, {
    _FakeSource? source,
    bool settle = true,
  }) async {
    final rows = StreamController<LibraryItem?>.broadcast();
    addTearDown(rows.close);
    final fake = source ?? _FakeSource();

    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
          activeMetadataSourceProvider.overrideWithValue(fake),
          metadataProvider.overrideWithValue(
            CachingMetadataSource(
              source: fake,
              sourceKind: MetadataSourceKind.tmdb,
              dao: db.mediaCacheDao,
              clock: fixed,
            ),
          ),
          libraryItemProvider.overrideWith((ref, id) => rows.stream),
          // Same reason as the row above: the season tiles watch this, and a
          // live Drift stream leaves a pending timer at teardown.
          watchedEpisodesProvider.overrideWith(
            (ref, id) => Stream.value(const <(int, int)>{}),
          ),
        ],
        child: MaterialApp(home: DetailScreen(itemId: row.id)),
      ),
    );
    // One pump to let the provider subscribe. A broadcast controller drops
    // anything added before that, which leaves the screen on its spinner —
    // and a spinner animates forever, so pumpAndSettle would never return.
    await tester.pump();
    rows.add(row);
    settle ? await tester.pumpAndSettle() : await tester.pump();
    return rows;
  }

  Future<LibraryItem> seedRow({required bool unverified}) => seed.seedShow(
    db,
    imdbId: 'tt11280740',
    relinkFailed: unverified,
    watched: const [(1, 1)],
  );

  /// Unverified **and** Stranded — recorded against the backend that is no
  /// longer active. Not an exotic combination: "could not relink at all" leaves
  /// the row on the old backend, so this is one of the two documented ways a
  /// row becomes Unverified in the first place (CONTEXT.md).
  Future<LibraryItem> seedStrandedRow() => seed.seedShow(
    db,
    source: MetadataSourceKind.tvdb,
    tmdbId: null,
    tvdbId: 371980,
    imdbId: 'tt11280740',
    relinkFailed: true,
    watched: const [(1, 1)],
  );

  /// Unverified **and** Unlinked: on the active backend, but with no id for it.
  /// Rare, but reachable: a title-matched import has no imdbId, so a relink
  /// after a backend flip flags it in place, and a flip back leaves it on the
  /// active backend with nothing to fetch by.
  Future<LibraryItem> seedUnlinkedRow() => seed.seedShow(
    db,
    tmdbId: null,
    relinkFailed: true,
    watched: const [(1, 1)],
  );

  final anyNotice = find.textContaining(unverifiedPositionNoticeOpening);
  final dismiss = find.text(unverifiedPositionDismissLabel);

  testWidgets('with the episode list on screen: check the seasons below, and '
      'the dismiss', (tester) async {
    await pump(tester, await seedRow(unverified: true));

    expect(find.text(unverifiedPositionNoticeListShown), findsOneWidget);
    expect(dismiss, findsOneWidget);

    // Above the seasons list, because the list is the evidence the user needs
    // in order to answer it. Anywhere else and they are told to go and check
    // something without being shown it.
    expect(
      tester.getTopLeft(find.text(unverifiedPositionNoticeListShown)).dy,
      lessThan(tester.getTopLeft(find.text('Seasons')).dy),
    );
  });

  testWidgets('a healthy title shows no notice and no dismiss', (tester) async {
    await pump(tester, await seedRow(unverified: false));

    expect(anyNotice, findsNothing);
    expect(dismiss, findsNothing);
  });

  // A Stranded row fetches nothing, so its list can never appear until a
  // relink. The first round of this feature pointed it at "the seasons below"
  // with nothing below, and offered a dismiss nothing on screen could justify.
  testWidgets('Stranded: the relink variant, and no dismiss', (tester) async {
    await pump(tester, await seedStrandedRow());

    expect(find.text(unverifiedPositionNoticeStranded), findsOneWidget);
    expect(
      dismiss,
      findsNothing,
      reason: 'nothing on screen could justify answering it',
    );
    expect(
      find.text('Seasons'),
      findsNothing,
      reason: 'sanity: this row really has no list — the premise of the test',
    );
  });

  // THE regression guard for the relink loop. A fetchable row is on the active
  // backend already, so a relink skips it. Told to relink, the user does, comes
  // back, and is told to relink again, under "You're offline". This is common,
  // not exotic: straight after a switch the new backend's cache is empty for
  // every show. The Stranded test above cannot catch it: it seeds a Stranded
  // row, which is the one case where the relink advice is right.
  //
  // Proved to fail first: choosing the variant from "list present" alone
  // (`listRef != null ? ListShown : Stranded`, the previous behaviour) shows
  // the relink copy here and reddens it.
  testWidgets('fetchable but offline: the not-loaded variant, no dismiss, and '
      'no mention of Settings', (tester) async {
    await pump(
      tester,
      await seedRow(unverified: true),
      source: _FakeSource(offline: true),
    );

    expect(
      find.text("Couldn't load details. You're offline."),
      findsOneWidget,
      reason: 'sanity: the list is missing because the fetch failed',
    );
    expect(find.text(unverifiedPositionNoticeNotLoaded), findsOneWidget);
    expect(dismiss, findsNothing);
    expect(
      find.textContaining('Settings'),
      findsNothing,
      reason: 'a relink skips this row, so Settings cannot help',
    );
  });

  // An Unlinked row has no reference either, but it is NOT Stranded: it is
  // already on the active backend, so a relink skips it and Settings does not
  // even offer one. Keyed on "no reference" alone, it was sent to a Settings
  // relink that is not there (D1 of the deviation audit).
  //
  // Proved to fail first: run against the previous variant choice, keyed on
  // `fetchRef == null` alone, which showed the Stranded copy here and reddened
  // the Settings assertion.
  testWidgets('Unlinked: its own variant, never sent to Settings, no dismiss', (
    tester,
  ) async {
    await pump(tester, await seedUnlinkedRow());

    expect(
      anyNotice,
      findsOneWidget,
      reason: 'sanity: the row is Unverified with a position',
    );
    expect(find.text(unverifiedPositionNoticeUnlinked), findsOneWidget);
    expect(
      find.textContaining('Settings'),
      findsNothing,
      reason: 'a relink skips this row, and Settings offers none',
    );
    expect(dismiss, findsNothing);
    expect(
      find.text('Seasons'),
      findsNothing,
      reason: 'sanity: no reference, so no list — the premise of the test',
    );
  });

  // Nothing special should be needed for this beyond the screen rebuilding;
  // pinned so that stays true.
  //
  // Proved to fail first: choosing the variant from the fetch reference alone
  // (`fetchRef == null ? Stranded : NotLoaded`, so a fetchable row never
  // reaches ListShown) reddens the second half; the "list present" alone
  // mutation above reddens the first.
  testWidgets('a fetchable title whose details arrive moves to "check the '
      'seasons below" and gains its dismiss', (tester) async {
    final gate = Completer<MediaDetails>();
    await pump(
      tester,
      await seedRow(unverified: true),
      source: _FakeSource(gate: gate),
      settle: false,
    );

    expect(find.text(unverifiedPositionNoticeNotLoaded), findsOneWidget);
    expect(dismiss, findsNothing);

    gate.complete(_details);
    await tester.pumpAndSettle();

    expect(find.text(unverifiedPositionNoticeListShown), findsOneWidget);
    expect(dismiss, findsOneWidget);
    expect(find.text(unverifiedPositionNoticeNotLoaded), findsNothing);
  });

  testWidgets('dismissing clears the flag and the screen updates', (
    tester,
  ) async {
    final row = await seedRow(unverified: true);
    final rows = await pump(tester, row);

    await tester.tap(dismiss);
    await tester.pumpAndSettle();

    final after = (await db.libraryDao.getItem(row.id))!;
    expect(after.relinkFailed, isFalse, reason: 'the tap performed the write');

    // What the real Drift stream does on that write.
    rows.add(after);
    await tester.pumpAndSettle();

    expect(
      anyNotice,
      findsNothing,
      reason: 'a dismissed title is indistinguishable from a healthy one',
    );
  });
}
