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

/// The detail screen on a **real phone**, at 360dp wide.
///
/// Every other detail test pumps a 1000dp-wide surface (so the `ListView`
/// builds everything at once), which is wider than any phone — and therefore
/// blind to anything that only breaks when horizontal space is scarce. It hid a
/// live one: the seasons header was a `Row` of an `Expanded` label and a button
/// wide enough to eat the row, so "Seasons" was squeezed to ~20dp and wrapped
/// **one letter per line** — 168dp of unreadable text that looked, on device,
/// like a mysterious blank gap.
///
/// So: assert the header lays out as a header. Single-line label, no overflow.
class _FakeSource implements MetadataSource {
  _FakeSource(this.details);
  final MediaDetails details;
  @override
  Future<MediaDetails> showDetails(int sourceId) async => details;
  @override
  Future<List<EpisodeInfo>> seasonEpisodes(int s, int n) async => const [];
  @override
  String imageUrl(String path, ImageSize size) => 'https://e.org/$path';
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  testWidgets('the seasons header lays out on a 360dp phone', (tester) async {
    // Exactly the emulator: 1080x2400 @ dpr 3 => 360x800 logical.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    const details = MediaDetails(
      kind: MediaKind.tv,
      title: 'Severance',
      genres: ['Drama'],
      seasons: [
        SeasonInfo(seasonNumber: 0, episodeCount: 1, name: 'Specials'),
        SeasonInfo(seasonNumber: 1, episodeCount: 9),
        SeasonInfo(seasonNumber: 2, episodeCount: 10),
      ],
      tmdbId: 95396,
      overview:
          'Mark leads a team of office workers whose memories have been '
          'surgically divided between their work and personal lives.',
      showStatus: 'Returning Series',
      episodeCountTotal: 19,
    );

    final now = DateTime(2026, 7, 12);
    final id = await db.libraryDao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Severance',
        trackStatus: TrackStatus.dropped,
        addedAt: now,
        updatedAt: now,
        tmdbId: const Value(95396),
      ),
    );
    final item = (await db.libraryDao.getItem(id))!;
    final source = _FakeSource(details);

    await tester.pumpWidget(
      ProviderScope(
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
          libraryItemProvider.overrideWith((ref, i) => Stream.value(item)),
          watchedEpisodesProvider.overrideWith(
            (ref, i) => Stream.value(const {(1, 1), (1, 2)}),
          ),
        ],
        child: MaterialApp(home: DetailScreen(itemId: id)),
      ),
    );
    await tester.pumpAndSettle();

    // No RenderFlex overflow, no squeezed-to-nothing children.
    expect(tester.takeException(), isNull);

    final label = tester.getRect(find.text('Seasons'));
    // One line of titleMedium is ~24dp. The bug rendered it 168dp tall (one
    // letter per line) — anything over a line and a half means it's wrapping in
    // a column that's too narrow for it.
    expect(label.height, lessThan(40));
    expect(label.width, greaterThan(60)); // the whole word, not "S…"

    // Still a section header for the seasons below it, whichever line it's on.
    final button = tester.getRect(find.text('Mark show watched'));
    expect(button.top, greaterThan(label.top));
    expect(
      button.bottom,
      lessThan(tester.getRect(find.text('Specials')).top),
    );
  });
}
