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
/// Wiring coverage; the rule lives in `unverified_position.dart` and the write
/// is tested at the DAO. What is worth proving here is that tapping the action
/// really performs that write, and that a row without the flag shows nothing.
class _FakeSource implements MetadataSource {
  const _FakeSource();

  static const _details = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama'],
    seasons: [SeasonInfo(seasonNumber: 1, episodeCount: 2)],
    tmdbId: 95396,
  );

  @override
  Future<MediaDetails> showDetails(SourceRef ref) async => _details;

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(SourceRef show, int season) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

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
  Future<StreamController<LibraryItem?>> pump(
    WidgetTester tester,
    LibraryItem row,
  ) async {
    final rows = StreamController<LibraryItem?>.broadcast();
    addTearDown(rows.close);

    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
          activeMetadataSourceProvider.overrideWithValue(const _FakeSource()),
          metadataProvider.overrideWithValue(
            CachingMetadataSource(
              source: const _FakeSource(),
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
    await tester.pumpAndSettle();
    return rows;
  }

  Future<LibraryItem> seedRow({required bool unverified}) => seed.seedShow(
    db,
    imdbId: 'tt11280740',
    relinkFailed: unverified,
    watched: const [(1, 1)],
  );

  testWidgets('an Unverified title shows the marker and its dismiss', (
    tester,
  ) async {
    await pump(tester, await seedRow(unverified: true));

    expect(find.text(unverifiedPositionNotice), findsOneWidget);
    expect(find.text(unverifiedPositionDismissLabel), findsOneWidget);

    // Above the seasons list, because the list is the evidence the user needs
    // in order to answer it. Anywhere else and they are told to go and check
    // something without being shown it.
    expect(
      tester.getTopLeft(find.text(unverifiedPositionNotice)).dy,
      lessThan(tester.getTopLeft(find.text('Seasons')).dy),
    );
  });

  testWidgets('a healthy title shows neither', (tester) async {
    await pump(tester, await seedRow(unverified: false));

    expect(find.text(unverifiedPositionNotice), findsNothing);
    expect(find.text(unverifiedPositionDismissLabel), findsNothing);
  });

  testWidgets('dismissing clears the flag and the screen updates', (
    tester,
  ) async {
    final row = await seedRow(unverified: true);
    final rows = await pump(tester, row);

    await tester.tap(find.text(unverifiedPositionDismissLabel));
    await tester.pumpAndSettle();

    final after = (await db.libraryDao.getItem(row.id))!;
    expect(after.relinkFailed, isFalse, reason: 'the tap performed the write');

    // What the real Drift stream does on that write.
    rows.add(after);
    await tester.pumpAndSettle();

    expect(
      find.text(unverifiedPositionNotice),
      findsNothing,
      reason: 'a dismissed title is indistinguishable from a healthy one',
    );
  });
}
