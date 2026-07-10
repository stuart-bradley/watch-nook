import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/cache/caching_metadata_repository.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/library/data/tracked_show_sync.dart';

/// The tracked-show sync backfills the per-show metadata an import can't fetch
/// (episode count, show status, poster) onto the library rows — the data the
/// derived "Up to date" category and the progress labels depend on. It must be
/// fault-tolerant: one offline show can't sink the whole pass.
class _FakeRepo implements CachingMetadataRepository {
  _FakeRepo(this.byId);

  final Map<int, MediaDetails> byId;
  int calls = 0;

  @override
  Stream<MediaDetails> showDetails(int sourceId) {
    calls++;
    final d = byId[sourceId];
    return d == null ? Stream.error(StateError('offline')) : Stream.value(d);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  MediaDetails details({int? total, String? status}) => MediaDetails(
    kind: MediaKind.tv,
    title: 'Show',
    genres: const [],
    seasons: const [],
    episodeCountTotal: total,
    showStatus: status,
    posterPath: '/p.jpg',
  );

  Future<int> seedShow({
    int tmdbId = 100,
    MediaType type = MediaType.tv,
    TrackStatus status = TrackStatus.watching,
  }) => db.libraryDao.insertItem(
    LibraryItemsCompanion.insert(
      mediaType: type,
      recordedSource: MetadataSourceKind.tmdb,
      title: 'Show $tmdbId',
      trackStatus: status,
      addedAt: DateTime(2026),
      updatedAt: DateTime(2026),
      tmdbId: Value(tmdbId),
    ),
  );

  TrackedShowSync syncWith(_FakeRepo repo) => TrackedShowSync(
    dao: db.libraryDao,
    repo: repo,
    backend: MetadataSourceKind.tmdb,
  );

  test('writes episode count, status and poster onto tracked shows', () async {
    await seedShow();
    await syncWith(
      _FakeRepo({100: details(total: 19, status: 'Returning Series')}),
    ).refresh();

    final item = (await db.libraryDao.getAll()).single;
    expect(item.episodeCountTotal, 19);
    expect(item.showStatus, 'Returning Series');
    expect(item.posterPath, '/p.jpg');
  });

  test('an offline/unknown show is skipped, not fatal to the pass', () async {
    await seedShow(); // tmdbId 100, resolvable
    await seedShow(tmdbId: 999); // errors

    await syncWith(_FakeRepo({100: details(total: 10)})).refresh();

    final items = await db.libraryDao.getAll();
    expect(items.firstWhere((i) => i.tmdbId == 100).episodeCountTotal, 10);
    expect(items.firstWhere((i) => i.tmdbId == 999).episodeCountTotal, isNull);
  });

  test('never touches movies or dropped shows', () async {
    await seedShow(tmdbId: 5, type: MediaType.movie);
    await seedShow(tmdbId: 6, status: TrackStatus.dropped);
    final repo = _FakeRepo({5: details(total: 1), 6: details(total: 1)});

    await syncWith(repo).refresh();

    expect(repo.calls, 0);
  });

  group('shouldDailySync (launch throttle)', () {
    final now = DateTime(2026, 7, 10, 12);

    test('due when never synced', () {
      expect(shouldDailySync(now, null), isTrue);
    });

    test('due exactly a day later (the boundary runs)', () {
      expect(
        shouldDailySync(now, now.subtract(const Duration(days: 1))),
        isTrue,
      );
    });

    test('not due within the day', () {
      expect(
        shouldDailySync(now, now.subtract(const Duration(hours: 23))),
        isFalse,
      );
    });
  });
}
