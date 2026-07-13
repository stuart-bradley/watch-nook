import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/detail/data/add_to_library.dart';

/// #16 AD-3 snapshot-at-add. Adversarial: prove the snapshot actually lands on
/// the row (not left to the disposable cache), that an offline add still
/// persists the title, and that re-adding never duplicates history — the #16
/// acceptance contract. Real in-memory Drift DB (not a mock) so the DAO's
/// dedupe query rides along.

/// A `MetadataSource` stand-in: returns [details] from the detail calls (or
/// throws to simulate offline). Counts detail calls so a test can prove the
/// fetch happens exactly once. Unused members throw via [noSuchMethod].
class _FakeSource implements MetadataSource {
  _FakeSource({
    this.details,
    this.offline = false,
    this.kind = MetadataSourceKind.tmdb,
  });

  final MediaDetails? details;
  final bool offline;

  /// Which catalogue this stands in for — the cache is namespaced per backend,
  /// so the repo wrapping it must agree with the add's `sourceKind`.
  final MetadataSourceKind kind;

  int detailCalls = 0;

  @override
  Future<MediaDetails> showDetails(int sourceId) async => _detail();

  @override
  Future<MediaDetails> movieDetails(int sourceId) async => _detail();

  MediaDetails _detail() {
    detailCalls++;
    if (offline) throw Exception('offline');
    return details!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// The add goes through the SWR cache (not the bare source) so it warms the
  /// cache Up Next reads — see `up_next_after_add_test.dart`.
  CachingMetadataRepository repoOver(_FakeSource source) =>
      CachingMetadataRepository(
        source: source,
        sourceKind: source.kind,
        dao: db.mediaCacheDao,
      );

  const severance = MediaSearchResult(
    kind: MediaKind.tv,
    title: 'Severance',
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
    posterPath: '/poster.jpg',
  );

  const severanceDetails = MediaDetails(
    kind: MediaKind.tv,
    title: 'Severance',
    genres: ['Drama', 'Sci-Fi & Fantasy'],
    seasons: [SeasonInfo(seasonNumber: 1, episodeCount: 9)],
    tmdbId: 95396,
    imdbId: 'tt11280740',
    year: 2022,
    runtimeMinutes: 50,
    showStatus: 'Returning Series',
    episodeCountTotal: 9,
  );

  test('adds with the chosen status and snapshots the offline-stats fields '
      'onto the row', () async {
    final source = _FakeSource(details: severanceDetails);

    final (:item, created: _) = await addToLibrary(
      repo: repoOver(source),
      sourceKind: MetadataSourceKind.tmdb,
      dao: db.libraryDao,
      result: severance,
      status: TrackStatus.watching,
    );

    expect(source.detailCalls, 1, reason: 'details fetched exactly once');
    expect(item.trackStatus, TrackStatus.watching);
    // The snapshot lands on the user row, not the disposable cache.
    expect(item.genresCsv, 'Drama,Sci-Fi & Fantasy');
    expect(item.runtimeMinutes, 50);
    expect(item.episodeCountTotal, 9);
    expect(item.showStatus, 'Returning Series');
    // Required-non-null relink columns are set from the active backend.
    expect(item.recordedSource, MetadataSourceKind.tmdb);
    expect(item.tmdbId, 95396);
    expect(item.imdbId, 'tt11280740');
    expect(item.mediaType, MediaType.tv);

    final all = await db.libraryDao.getAll();
    expect(all, hasLength(1), reason: 'the added item appears in the library');
  });

  test('offline at add-time still persists the title from the search hit, '
      'stats fields left null to backfill later', () async {
    final source = _FakeSource(details: severanceDetails, offline: true);

    final (:item, created: _) = await addToLibrary(
      repo: repoOver(source),
      sourceKind: MetadataSourceKind.tmdb,
      dao: db.libraryDao,
      result: severance,
      status: TrackStatus.watchlist,
    );

    expect(source.detailCalls, 1, reason: 'fetch was attempted');
    expect(item.title, 'Severance');
    expect(item.trackStatus, TrackStatus.watchlist);
    // Search-hit fields survive; details-only fields are null (backfill later).
    expect(item.tmdbId, 95396);
    expect(item.year, 2022);
    expect(item.genresCsv, isNull);
    expect(item.runtimeMinutes, isNull);
    expect(item.recordedSource, MetadataSourceKind.tmdb);
  });

  test(
    're-adding the same title does not duplicate (dedupe by identity)',
    () async {
      final source = _FakeSource(details: severanceDetails);

      final (item: first, created: firstCreated) = await addToLibrary(
        repo: repoOver(source),
        sourceKind: MetadataSourceKind.tmdb,
        dao: db.libraryDao,
        result: severance,
        status: TrackStatus.watching,
      );
      final (item: second, created: secondCreated) = await addToLibrary(
        repo: repoOver(source),
        sourceKind: MetadataSourceKind.tmdb,
        dao: db.libraryDao,
        result: severance,
        status: TrackStatus.completed,
      );

      final all = await db.libraryDao.getAll();
      expect(all, hasLength(1), reason: 're-add returns the existing row');
      expect(second.id, first.id);
      // Dedupe returns the pre-existing row untouched — it does not
      // overwrite the first status with the second.
      expect(second.trackStatus, TrackStatus.watching);

      // ...and it SAYS so. The second call applied nothing, so a caller that
      // reports "Added X to Completed" off the back of it is lying about the
      // user's own data — `created` is the only way to tell the two apart.
      expect(firstCreated, isTrue);
      expect(secondCreated, isFalse);
    },
  );

  test('a TVDB-active add stores the tvdb id, not tmdb', () async {
    const tvdbHit = MediaSearchResult(
      kind: MediaKind.movie,
      title: 'Dune',
      tvdbId: 111,
      year: 2021,
    );
    final source = _FakeSource(
      kind: MetadataSourceKind.tvdb,
      details: const MediaDetails(
        kind: MediaKind.movie,
        title: 'Dune',
        genres: ['Sci-Fi'],
        seasons: [],
        tvdbId: 111,
        runtimeMinutes: 155,
      ),
    );

    final (:item, created: _) = await addToLibrary(
      repo: repoOver(source),
      sourceKind: MetadataSourceKind.tvdb,
      dao: db.libraryDao,
      result: tvdbHit,
      status: TrackStatus.completed,
    );

    expect(item.recordedSource, MetadataSourceKind.tvdb);
    expect(item.tvdbId, 111);
    expect(item.tmdbId, isNull);
    expect(item.mediaType, MediaType.movie);
    expect(item.runtimeMinutes, 155);
  });
}
