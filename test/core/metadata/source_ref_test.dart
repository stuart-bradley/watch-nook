// The ids repeat the fixture defaults on purpose: these tests are about WHICH
// backend a reference names, so spelling it out at the seed site is what makes
// the assertion legible.
// ignore_for_file: avoid_redundant_argument_values
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';

import '../../support/library_fixtures.dart' as seed;

/// The row → reference mapping.
///
/// `remote_image_test` hand-constructs an [ArtworkRef] and so proves only the
/// widget's rule; it would stay green with this mapping completely wrong. This
/// is the half that says which backend a stored row's artwork actually claims
/// — and it is the half a relink can break, because a relink rewrites the very
/// field the mapping reads.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('SourceRef off a row', () {
    test("names the row's own backend, not the one asked about", () async {
      final item = await seed.seedShow(db, tmdbId: 95396);

      expect(
        item.refFor(MetadataSourceKind.tmdb),
        const SourceRef(MetadataSourceKind.tmdb, 95396),
      );
      expect(item.refFor(MetadataSourceKind.tvdb), isNull);
    });

    test("never borrows the other backend's id column", () async {
      final item = await seed.seedShow(
        db,
        source: MetadataSourceKind.tvdb,
        tmdbId: null,
        tvdbId: 371980,
      );

      expect(
        item.refFor(MetadataSourceKind.tvdb),
        const SourceRef(MetadataSourceKind.tvdb, 371980),
      );
    });
  });

  group('ArtworkRef off a row', () {
    test(
      'tags the poster with the backend the row is recorded against',
      () async {
        final item = await seed.seedShow(db, posterPath: '/severance.jpg');

        expect(
          item.posterRef,
          const ArtworkRef(MetadataSourceKind.tmdb, '/severance.jpg'),
        );
      },
    );

    test('a row with no artwork has no reference', () async {
      final item = await seed.seedShow(db, posterPath: null);

      expect(item.posterRef, isNull);
    });

    test('a tvdb row claims tvdb, whatever is active', () async {
      final item = await seed.seedShow(
        db,
        source: MetadataSourceKind.tvdb,
        tmdbId: null,
        tvdbId: 371980,
        posterPath: 'https://artworks.thetvdb.com/x.jpg',
      );

      expect(item.posterRef?.kind, MetadataSourceKind.tvdb);
    });

    test(
      'the reference follows recordedSource, so a poster left behind by a '
      'relink would claim a backend that never minted it',
      () async {
        // This is the trap, pinned. `posterRef` reads `recordedSource` — the
        // field a relink OVERWRITES — while `posterPath` is only meaningful to
        // the backend that produced it. A relink that rewrote one and kept the
        // other would hand `RemoteImage` a reference that passes its mismatch
        // check and resolves through the wrong catalogue. The relink therefore
        // has to drop the path; see `BackendSwitchService`. Anything that
        // rewrites `recordedSource` in future must do the same.
        final stale = await seed.seedRawItem(
          db,
          LibraryItemsCompanion.insert(
            mediaType: MediaType.movie,
            // Relinked to tmdb...
            recordedSource: MetadataSourceKind.tmdb,
            title: 'Relinked',
            trackStatus: TrackStatus.completed,
            addedAt: seed.fixtureNow,
            updatedAt: seed.fixtureNow,
            // ...but still carrying TheTVDB's absolute URL.
            posterPath: const Value('https://artworks.thetvdb.com/old.jpg'),
          ),
        );
        final row = (await db.libraryDao.getItem(stale))!;

        expect(
          row.posterRef?.kind,
          MetadataSourceKind.tmdb,
          reason:
              'the reference cannot tell — which is exactly why the path must '
              'not outlive the recordedSource it was minted under',
        );
      },
    );
  });

  group('SourceRef off a search hit', () {
    const hit = MediaSearchResult(
      kind: MediaKind.tv,
      title: 'Severance',
      tmdbId: 95396,
    );

    test("takes the active backend's id column", () {
      expect(
        hit.refFor(MetadataSourceKind.tmdb),
        const SourceRef(MetadataSourceKind.tmdb, 95396),
      );
      expect(hit.refFor(MetadataSourceKind.tvdb), isNull);
    });
  });

  group('idFor', () {
    test('hands over its id to its own backend', () {
      expect(
        const SourceRef(MetadataSourceKind.tmdb, 95396).idFor(
          MetadataSourceKind.tmdb,
        ),
        95396,
      );
    });

    test('refuses the other backend rather than answering it', () {
      expect(
        () => const SourceRef(
          MetadataSourceKind.tvdb,
          95396,
        ).idFor(MetadataSourceKind.tmdb),
        throwsArgumentError,
      );
    });
  });
}
