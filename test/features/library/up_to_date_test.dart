import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/features/library/presentation/library_screen.dart';

/// #12 — the derived **Up to date** category. Shōgun (all aired S1 watched, a
/// returning show awaiting S2) must read as up-to-date, not completed/dropped —
/// but a show with episodes left, or one that has ended, must not.

LibraryItem _item({
  TrackStatus status = TrackStatus.watching,
  String? showStatus,
  int watched = 10,
  int? total = 10,
  MediaType type = MediaType.tv,
}) => LibraryItem(
  id: 1,
  mediaType: type,
  recordedSource: MetadataSourceKind.tmdb,
  title: 'Shōgun',
  trackStatus: status,
  showStatus: showStatus,
  episodeCountTotal: total,
  watchedCount: watched,
  addedAt: DateTime(2026),
  updatedAt: DateTime(2026),
  relinkFailed: false,
);

void main() {
  group('isUpToDate', () {
    test('all aired watched + still returning → up to date', () {
      expect(isUpToDate(_item(showStatus: 'Returning Series')), isTrue);
    });

    test('episodes still to watch → not up to date', () {
      expect(
        isUpToDate(_item(watched: 5, showStatus: 'Returning Series')),
        isFalse,
      );
    });

    test('an ended show is completed, never up to date', () {
      expect(isUpToDate(_item(showStatus: 'Ended')), isFalse);
    });

    test('unknown episode count (not yet synced) → not up to date', () {
      expect(isUpToDate(_item(total: null)), isFalse);
    });

    test('refines completed too (a returning show archived early)', () {
      expect(
        isUpToDate(
          _item(status: TrackStatus.completed, showStatus: 'Returning Series'),
        ),
        isTrue,
      );
    });

    test('does not apply to dropped shows', () {
      expect(
        isUpToDate(
          _item(status: TrackStatus.dropped, showStatus: 'Returning Series'),
        ),
        isFalse,
      );
    });

    test('movies are never up to date', () {
      expect(isUpToDate(_item(type: MediaType.movie)), isFalse);
    });
  });
}
