import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';

/// Unit-tests the denormalized progress caption (#17). Built from a real row so
/// the field wiring (which column feeds which part of the string) is exercised,
/// not a hand-rolled stand-in. No metadata fetch anywhere — the whole point is
/// it renders offline.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final now = DateTime(2026);

  Future<LibraryItem> row({
    required MediaType type,
    int watchedCount = 0,
    int? lastSeason,
    int? lastEpisode,
    int? episodeCountTotal,
  }) async {
    final id = await db.libraryDao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: type,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'X',
        trackStatus: TrackStatus.watching,
        addedAt: now,
        updatedAt: now,
        watchedCount: Value(watchedCount),
        lastWatchedSeason: Value(lastSeason),
        lastWatchedEpisode: Value(lastEpisode),
        episodeCountTotal: Value(episodeCountTotal),
      ),
    );
    return (await db.libraryDao.getItem(id))!;
  }

  test(
    'TV in progress → S{season}E{episode} · {remaining} left (acceptance)',
    () async {
      final item = await row(
        type: MediaType.tv,
        watchedCount: 7,
        lastSeason: 2,
        lastEpisode: 4,
        episodeCountTotal: 10,
      );
      expect(libraryProgressLabel(item), 'S2E4 · 3 left');
    },
  );

  test('TV fully watched drops the "left" suffix', () async {
    final item = await row(
      type: MediaType.tv,
      watchedCount: 10,
      lastSeason: 2,
      lastEpisode: 4,
      episodeCountTotal: 10,
    );
    expect(libraryProgressLabel(item), 'S2E4');
  });

  test(
    'TV with a known total but nothing watched shows the episode count',
    () async {
      final item = await row(type: MediaType.tv, episodeCountTotal: 10);
      expect(libraryProgressLabel(item), '10 episodes');
    },
  );

  test('TV with no total and nothing watched → Not started', () async {
    final item = await row(type: MediaType.tv);
    expect(libraryProgressLabel(item), 'Not started');
  });

  test('TV watched but total unknown shows position without a count', () async {
    final item = await row(
      type: MediaType.tv,
      watchedCount: 3,
      lastSeason: 1,
      lastEpisode: 3,
    );
    expect(libraryProgressLabel(item), 'S1E3');
  });

  test('movie reflects watched vs unwatched', () async {
    expect(libraryProgressLabel(await row(type: MediaType.movie)), 'Unwatched');
    expect(
      libraryProgressLabel(await row(type: MediaType.movie, watchedCount: 1)),
      'Watched',
    );
  });
}
