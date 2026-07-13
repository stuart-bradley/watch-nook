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
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/search/presentation/search_screen.dart';

/// #16 acceptance — the search→**detail** flow at the widget layer, via a
/// `ProviderScope` with a fake source + in-memory DB (never the real net/DB).
///
/// Adversarial: a tap must READ (navigate), never WRITE. Both tests assert the
/// DB *after* the tap, because a route assertion alone would happily pass on a
/// screen that navigated AND added.

class _FakeSource implements MetadataSource {
  _FakeSource({required this.results, required this.details});

  final List<MediaSearchResult> results;
  final MediaDetails details;

  @override
  Future<List<MediaSearchResult>> search(
    String query, {
    MediaKind? kind,
  }) async => results;

  @override
  Future<MediaDetails> showDetails(int sourceId) async => details;

  @override
  Future<MediaDetails> movieDetails(int sourceId) async => details;

  @override
  String imageUrl(String path, ImageSize size) => 'https://example.test$path';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  // posterPath is null so no CachedNetworkImage hits the network in tests.
  const results = [
    MediaSearchResult(
      kind: MediaKind.tv,
      title: 'Severance',
      tmdbId: 95396,
      imdbId: 'tt11280740',
      year: 2022,
    ),
  ];
  const details = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama'],
    seasons: [SeasonInfo(seasonNumber: 1, episodeCount: 9)],
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
    runtimeMinutes: 50,
    episodeCountTotal: 9,
  );

  late GoRouter router;

  /// The search screen under a real router, so a tap's *destination* is
  /// observable. `/preview` and `/title/:id` render a stub — this file is about
  /// where the tap goes and what it does (or doesn't) write, not about the
  /// detail screen (see `preview_test.dart` for that).
  Widget harness() {
    router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(
          path: '/search',
          builder: (_, _) => const SearchScreen(),
        ),
        GoRoute(
          path: '/preview',
          builder: (_, _) => const Scaffold(body: Text('preview screen')),
        ),
        GoRoute(
          path: '/title/:id',
          builder: (_, _) => const Scaffold(body: Text('tracked screen')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
        activeMetadataSourceProvider.overrideWithValue(
          _FakeSource(results: results, details: details),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  String location() =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;

  /// Types the query and lets the debounce + search future resolve.
  Future<void> search(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'severance');
    await tester.pump(const Duration(milliseconds: 400)); // fire debounce
    await tester.pumpAndSettle(); // resolve the search future + build the list
  }

  testWidgets('tapping a result opens its detail page and adds nothing', (
    tester,
  ) async {
    // THE regression this flow exists to kill: a tap used to open a status
    // picker and commit the title to the library on the spot, having shown the
    // user nothing but a poster and a year. Asserting the route alone would let
    // an add-on-tap survive — so the empty DB is the load-bearing assertion.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // Empty query → prompt, not a spinner or results.
    expect(find.text('Search for a film or show to track.'), findsOneWidget);
    expect(find.text('Severance'), findsNothing);

    await search(tester);
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('2022 · TV'), findsOneWidget);

    // Nothing tracked, so no badge on the row.
    expect(find.text('Watching'), findsNothing);

    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();

    expect(location(), '/preview');
    expect(find.text('preview screen'), findsOneWidget);
    expect(await db.libraryDao.getAll(), isEmpty);
    // No status sheet: the choice belongs on the detail page, after you've read
    // the thing.
    expect(find.text('Watchlist'), findsNothing);
  });

  testWidgets('a result already in the library is badged with its status', (
    tester,
  ) async {
    // Six films called "Severance" come back from a search; without this you
    // have to open each one to find out which is the one you already track.
    final now = DateTime(2026, 7, 13);
    await db.libraryDao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Severance',
        trackStatus: TrackStatus.onHold,
        addedAt: now,
        updatedAt: now,
        tmdbId: const Value(95396),
      ),
    );

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await search(tester);

    // The badge names the status — the thing you'd have opened the row to see.
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('On hold'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('In your library'), findsOneWidget);
  });

  testWidgets(
    'tapping a result already in the library opens its tracked page',
    (
      tester,
    ) async {
      // Otherwise a title you already track offers you an "Add to library"
      // button. Identity resolves through the same cascade the add-dedupe uses,
      // so a regression there (e.g. matching a tmdbId across mediaTypes) lands
      // here too.
      final now = DateTime(2026, 7, 12);
      final id = await db.libraryDao.insertItem(
        LibraryItemsCompanion.insert(
          mediaType: MediaType.tv,
          recordedSource: MetadataSourceKind.tmdb,
          title: 'Severance',
          trackStatus: TrackStatus.watching,
          addedAt: now,
          updatedAt: now,
          tmdbId: const Value(95396),
        ),
      );

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await search(tester);

      await tester.tap(find.text('Severance'));
      await tester.pumpAndSettle();

      expect(location(), '/title/$id');
      expect(find.text('tracked screen'), findsOneWidget);
      // And it did not quietly add a second copy on the way through.
      expect(await db.libraryDao.getAll(), hasLength(1));
    },
  );
}
