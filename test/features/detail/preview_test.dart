import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/library_identity.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/detail/presentation/detail_screen.dart';

/// US-1/US-2 — the detail screen in **preview** mode: an untracked search hit,
/// reachable before it is in the library.
///
/// Adversarial framing:
/// - Every write control must be **absent**, not merely disabled. There is no
///   `LibraryItems` row to write against yet, so a leaked status dropdown,
///   bulk button or episode toggle would fire against a null item id. The test
///   asserts their absence by name, including *inside an expanded season* —
///   the place a nullable id is easiest to forget to thread.
/// - Adding is asserted against the **DB**, not the SnackBar: the row must
///   carry the chosen status and the AD-3 snapshot (`genresCsv`,
///   `runtimeMinutes`, `episodeCountTotal`), which is what makes stats work
///   offline. A confirmation toast proves nothing.
/// - Previewing a title that is *already* tracked must not duplicate it — the
///   `addOrGetItem` dedupe is reachable from a new caller now.

class _FakeSource implements MetadataSource {
  _FakeSource({required this.details, this.episodes = const []});

  final MediaDetails details;
  final List<EpisodeInfo> episodes;

  @override
  Future<MediaDetails> showDetails(int sourceId) async => details;

  @override
  Future<MediaDetails> movieDetails(int sourceId) async => details;

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int showId, int season) async =>
      episodes.where((e) => e.seasonNumber == season).toList();

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

  // posterPath/backdropPath stay null so no CachedNetworkImage hits the net.
  const hit = MediaSearchResult(
    kind: MediaKind.tv,
    title: 'Severance',
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
  );
  const details = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama', 'Mystery'],
    seasons: [
      SeasonInfo(seasonNumber: 1, episodeCount: 2),
      SeasonInfo(seasonNumber: 2, episodeCount: 1),
    ],
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
    overview: 'Mark leads a team of office workers.',
    showStatus: 'Returning Series',
    runtimeMinutes: 50,
    episodeCountTotal: 3,
  );
  const episodes = [
    EpisodeInfo(seasonNumber: 1, episodeNumber: 1, title: 'Good News'),
    EpisodeInfo(seasonNumber: 1, episodeNumber: 2, title: 'Half Loop'),
    EpisodeInfo(seasonNumber: 2, episodeNumber: 1, title: 'Hello, Ms Cobel'),
  ];

  late GoRouter router;

  /// Mounts the preview under a real router (the Add button replaces this route
  /// with the tracked one, so there has to be somewhere to land). `/title/:id`
  /// renders a stub — this file is about the preview, not the tracked screen.
  Future<void> pumpPreview(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final source = _FakeSource(details: details, episodes: episodes);
    router = GoRouter(
      initialLocation: '/preview',
      routes: [
        GoRoute(
          path: '/preview',
          builder: (_, _) => const DetailScreen(result: hit),
        ),
        GoRoute(
          path: '/title/:id',
          builder: (_, _) => const Scaffold(body: Text('tracked screen')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
          activeMetadataSourceProvider.overrideWithValue(source),
          metadataRepositoryProvider.overrideWithValue(
            CachingMetadataRepository(
              source: source,
              sourceKind: MetadataSourceKind.tmdb,
              dao: db.mediaCacheDao,
            ),
          ),
          // Real rows off the real DB, but as one-shot streams: a live Drift
          // `.watch()` never quiesces under fake-async and hangs
          // `pumpAndSettle` (CLAUDE.md). Only reached once the screen resolves
          // into tracked mode; an untracked preview never watches them.
          libraryRevisionProvider.overrideWith((ref) => Stream.value(0)),
          libraryItemProvider.overrideWith(
            (ref, id) => Stream.fromFuture(db.libraryDao.getItem(id)),
          ),
          watchedEpisodesProvider.overrideWith(
            (ref, id) => Stream.value(const <(int, int)>{}),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  String location() =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;

  /// What the status dropdown is showing (its internal controller), when the
  /// screen has resolved into tracked mode.
  String? statusLabel(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byType(DropdownMenu<TrackStatus>),
          matching: find.byType(TextField),
        ),
      )
      .controller
      ?.text;

  testWidgets('an untracked title shows its details and offers only Add', (
    tester,
  ) async {
    await pumpPreview(tester);

    // The details you came here to read.
    expect(find.text('Severance'), findsWidgets);
    expect(find.text('2022 · TV · Returning Series'), findsOneWidget);
    expect(find.text('Mark leads a team of office workers.'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('2 episodes'), findsOneWidget);

    // One action, and nothing that would write to a row that doesn't exist.
    expect(find.text('Add to library'), findsOneWidget);
    expect(find.byType(DropdownMenu<TrackStatus>), findsNothing);
    expect(find.text('Rate'), findsNothing);
    expect(find.text('Mark show watched'), findsNothing);
    expect(find.byTooltip('Mark season watched'), findsNothing);
    expect(find.byTooltip('Mark watched'), findsNothing);
  });

  testWidgets('an expanded season lists episodes with no watch controls', (
    tester,
  ) async {
    // The nullable item id is threaded deepest here — an episode row is the
    // easiest place to leave a toggle wired to a null id.
    await pumpPreview(tester);

    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();

    expect(find.text('Good News'), findsOneWidget);
    expect(find.text('Half Loop'), findsOneWidget);
    expect(find.byTooltip('Mark watched'), findsNothing);
    expect(find.byTooltip('Mark unwatched'), findsNothing);
  });

  testWidgets('Add to library picks a status, writes the row, lands on it', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.text('Add to library'));
    await tester.pumpAndSettle();

    // The shared status sheet.
    expect(find.text('Watchlist'), findsOneWidget);
    await tester.tap(find.text('Watching'));
    await tester.pumpAndSettle();

    // The AD-3 snapshot landed on the row — not just a confirmation toast.
    final items = await db.libraryDao.getAll();
    expect(items, hasLength(1));
    expect(items.single.title, 'Severance');
    expect(items.single.trackStatus, TrackStatus.watching);
    expect(items.single.genresCsv, 'Drama,Mystery');
    expect(items.single.runtimeMinutes, 50);
    expect(items.single.episodeCountTotal, 3);

    // The preview is spent: it's replaced by the tracked route, so Back returns
    // to search rather than to an Add page for a title that's now tracked.
    expect(location(), '/title/${items.single.id}');
    expect(find.text('tracked screen'), findsOneWidget);
    expect(find.text('Add to library'), findsNothing);
  });

  testWidgets('a title tracked only by imdbId never offers to add it', (
    tester,
  ) async {
    // The US-3 hole. Search resolves tracked-ness at tap time from the raw hit,
    // and TMDB's `search` carries NO imdbId — so a row imported from Trakg/TV
    // Time (imdb-keyed, no tmdbId, and a title that doesn't match character for
    // character) slips through and lands here. The details DO carry the imdbId,
    // so the screen re-resolves identity once they land.
    //
    // Without that second look you get an "Add to library" button for a show
    // you already track — and pressing it silently keeps the old status while
    // reporting the new one.
    final now = DateTime(2026, 7, 12);
    final existing = await db.libraryDao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Severance (2022)', // ≠ the hit's title, so no title+year match
        trackStatus: TrackStatus.completed,
        addedAt: now,
        updatedAt: now,
        imdbId: const Value('tt11280740'), // the ONLY thing that can match
      ),
    );

    await pumpPreview(tester);

    // It's that row's detail page, not an add page.
    expect(find.text('Add to library'), findsNothing);
    expect(find.byType(DropdownMenu<TrackStatus>), findsOneWidget);
    expect(find.text('Mark show watched'), findsOneWidget);

    // ...showing the status it actually has, and still exactly one row.
    expect(statusLabel(tester), 'Completed');
    final items = await db.libraryDao.getAll();
    expect(items, hasLength(1));
    expect(items.single.id, existing);
  });
}
