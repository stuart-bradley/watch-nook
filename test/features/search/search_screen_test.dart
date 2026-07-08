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
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/search/presentation/search_screen.dart';

/// #16 acceptance — the search→add flow at the widget layer, via a
/// `ProviderScope` with a fake source + in-memory DB (never the real net/DB).
/// Adversarial: prove a search query renders results and that picking a status
/// actually writes the row (the "added item appears in the library" contract),
/// not just shows a confirmation.

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

  Widget harness() => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
      activeMetadataSourceProvider.overrideWithValue(
        _FakeSource(results: results, details: details),
      ),
    ],
    child: const MaterialApp(home: SearchScreen()),
  );

  testWidgets('search renders results, then picking a status adds the title '
      'to the library', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // Empty query → prompt, not a spinner or results.
    expect(find.text('Search for a film or show to track.'), findsOneWidget);
    expect(find.text('Severance'), findsNothing);

    await tester.enterText(find.byType(TextField), 'severance');
    await tester.pump(const Duration(milliseconds: 400)); // fire debounce
    await tester.pumpAndSettle(); // resolve the search future + build the list

    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('2022 · TV'), findsOneWidget);

    // Tap the result → status picker.
    await tester.tap(find.text('Severance'));
    await tester.pumpAndSettle();
    expect(find.text('Watching'), findsOneWidget);
    expect(find.text('Watchlist'), findsOneWidget);

    await tester.tap(find.text('Watching'));
    await tester.pumpAndSettle();

    // Acceptance: the item is really in the library with the chosen status and
    // the AD-3 snapshot — not just a UI confirmation.
    final items = await db.libraryDao.getAll();
    expect(items, hasLength(1));
    expect(items.single.title, 'Severance');
    expect(items.single.trackStatus, TrackStatus.watching);
    expect(items.single.genresCsv, 'Drama');
    expect(items.single.runtimeMinutes, 50);

    expect(find.byType(SnackBar), findsOneWidget);
  });
}
