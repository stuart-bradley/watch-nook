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
import 'package:watch_nook/core/routing/app_router.dart';

/// The `/preview` route itself — mounted from the **real** `appRoutes`.
///
/// Every other test of this flow declares its own `/preview` GoRoute and hands
/// `DetailScreen` the hit directly, so the production builder — and the one
/// line in it that matters — was never executed by anything:
///
///     extra is MediaSearchResult ? extra : null
///
/// That `is` (not `as`) is load-bearing. A bare cast on a missing or foreign
/// `extra` throws a `TypeError` — an `Error`, not an `Exception`, so it is NOT
/// caught by an `on Exception` handler (the Dart gotcha this repo records in
/// CLAUDE.md). `extra` is push-only: it does not survive a deep link or a
/// process restore, so "no extra" is a state a user reaches, not a theory.
///
/// Adversarial: a regression to `state.extra as MediaSearchResult` passes every
/// other test in the suite and crashes here.
class _FakeSource implements MetadataSource {
  _FakeSource(this.details);

  final MediaDetails details;

  @override
  Future<MediaDetails> showDetails(int sourceId) async => details;

  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int show, int season) async =>
      const [];

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
    genres: ['Drama'],
    seasons: [SeasonInfo(seasonNumber: 1, episodeCount: 2)],
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
    overview: 'Mark leads a team of office workers.',
  );

  /// Mounts the REAL router (`appRoutes`) and pushes `/preview` with [extra]
  /// exactly as `SearchScreen` does.
  Future<void> pumpAt(WidgetTester tester, {Object? extra}) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final source = _FakeSource(details);
    final router = GoRouter(
      initialLocation: '/preview',
      routes: appRoutes,
      // The real router also redirects on the onboarding flag; that isn't what
      // is under test here — appRoutes is.
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
          // A live Drift `.watch()` never quiesces under fake-async
          // (CLAUDE.md), so the revision ticker is stubbed.
          libraryRevisionProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    router.go('/preview', extra: extra);
    await tester.pumpAndSettle();
  }

  testWidgets('a hit in `extra` renders the preview', (tester) async {
    await pumpAt(tester, extra: hit);

    expect(tester.takeException(), isNull);
    expect(find.text('Severance'), findsWidgets);
    expect(find.text('Mark leads a team of office workers.'), findsOneWidget);
    expect(find.text('Add to library'), findsOneWidget);
  });

  testWidgets('no `extra` (a restored deep link) degrades to a notice', (
    tester,
  ) async {
    // `extra` doesn't survive a process restore — this is the state a user
    // actually lands in, and it must not throw.
    await pumpAt(tester);

    expect(tester.takeException(), isNull);
    expect(find.text("Couldn't open this title."), findsOneWidget);
    expect(find.text('Add to library'), findsNothing);
  });

  testWidgets('a foreign `extra` degrades too, instead of throwing', (
    tester,
  ) async {
    // The `as`-cast regression: this is where it would throw a TypeError.
    await pumpAt(tester, extra: 'not a search result');

    expect(tester.takeException(), isNull);
    expect(find.text("Couldn't open this title."), findsOneWidget);
  });
}
