import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/detail/presentation/detail_screen.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';

/// #22 — the cross-screen seam nothing else covers: a **bulk mark on the detail
/// screen** must move the **library grid's progress caption**, which reads only
/// the denormalized columns (AD-4). Two widget tests each pass in isolation
/// while the seam is broken; this one drives the real DAO bulk path against an
/// in-memory DB and then re-mounts the grid on the row it wrote.
///
/// Adversarial framing: the pre-bulk caption ("4 episodes") is asserted first
/// and asserted *gone* after, so a bulk that inserts `WatchEvents` without
/// maintaining `watchedCount`/`lastWatched*` — the exact regression AD-4 exists
/// to prevent — leaves the caption unchanged and fails here.

class _FakeSource implements MetadataSource {
  _FakeSource(this.details, this.episodes);

  final MediaDetails details;
  final List<EpisodeInfo> episodes;

  @override
  Future<MediaDetails> showDetails(int sourceId) async => details;

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int showId, int season) async =>
      episodes.where((e) => e.seasonNumber == season).toList();

  @override
  Attribution attribution() =>
      const Attribution(notice: 'Fake', linkUrl: 'https://example.org/');

  @override
  String imageUrl(String path, ImageSize size) => 'https://example.org/$path';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final now = DateTime(2026, 7, 9);

  const details = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama'],
    seasons: [
      SeasonInfo(seasonNumber: 1, episodeCount: 2),
      SeasonInfo(seasonNumber: 2, episodeCount: 2),
    ],
    tmdbId: 95396,
    episodeCountTotal: 4,
  );
  const episodes = [
    EpisodeInfo(seasonNumber: 1, episodeNumber: 1),
    EpisodeInfo(seasonNumber: 1, episodeNumber: 2),
    EpisodeInfo(seasonNumber: 2, episodeNumber: 1),
    EpisodeInfo(seasonNumber: 2, episodeNumber: 2),
  ];

  /// `episodeCountTotal` is the add-time snapshot (AD-3) the caption divides
  /// against; posterPath stays null so no card image resolves a URL.
  Future<int> insertShow() => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: MediaType.tv,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Severance',
      trackStatus: TrackStatus.watching,
      addedAt: now,
      updatedAt: now,
      tmdbId: const Value(95396),
      episodeCountTotal: const Value(4),
    ),
  );

  /// The grid over a **synchronous snapshot** of the rows as they stand now —
  /// a live Drift `.watch()` never quiesces under fake-async (CLAUDE.md).
  Future<void> pumpGrid(WidgetTester tester) async {
    final rows = await db.libraryDao.getAll();
    await tester.pumpWidget(
      ProviderScope(
        // A distinct key per scope: swapping the grid and detail trees changes
        // the override count, and Riverpod asserts on that when an existing
        // `ProviderScope` element is updated in place.
        key: const ValueKey('grid'),
        overrides: [
          libraryGridProvider.overrideWith((ref, filter) => Stream.value(rows)),
        ],
        child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDetail(WidgetTester tester, int itemId) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final item = (await db.libraryDao.getItem(itemId))!;
    final source = _FakeSource(details, episodes);
    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('detail'),
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataSourceProvider.overrideWithValue(source),
          metadataRepositoryProvider.overrideWithValue(
            CachingMetadataRepository(
              source: source,
              sourceKind: MetadataSourceKind.tmdb,
              dao: db.mediaCacheDao,
            ),
          ),
          libraryItemProvider.overrideWith((ref, id) => Stream.value(item)),
          watchedEpisodesProvider.overrideWith(
            (ref, id) => Stream.value(const <(int, int)>{}),
          ),
        ],
        child: MaterialApp(home: DetailScreen(itemId: itemId)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a bulk season mark moves the grid caption to "S1E2 · 2 left"', (
    tester,
  ) async {
    final id = await insertShow();

    await pumpGrid(tester);
    expect(find.text('4 episodes'), findsOneWidget);

    await pumpDetail(tester, id);
    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark season watched'));
    await tester.pumpAndSettle();

    // Back to the grid, reading the row the bulk write left behind.
    await pumpGrid(tester);
    expect(find.text('S1E2 · 2 left'), findsOneWidget);
    expect(find.text('4 episodes'), findsNothing);
  });
}
