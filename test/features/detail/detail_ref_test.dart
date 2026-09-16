// The ids below repeat the fixture defaults on purpose: these tests are about
// WHICH id is used for which backend, so spelling it out at the seed site is
// what makes the assertion legible.
// ignore_for_file: avoid_redundant_argument_values
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
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/core/widgets/remote_image.dart';
import 'package:watch_nook/features/detail/data/detail_providers.dart';
import 'package:watch_nook/features/detail/presentation/detail_screen.dart';

import '../../support/library_fixtures.dart' as seed;

/// Counts calls rather than throwing on them.
///
/// A throwing double looks adversarial but is not: the detail screen consumes
/// metadata through an `AsyncValue`, which captures the error and still renders
/// the stored row, so the test passes whether or not the fetch was attempted.
/// Asking "how many times were you called" is the assertion that actually bites
/// — verified by removing the guard and watching this go red.
class _SpySource implements MetadataSource {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw UnimplementedError();
  }
}

/// ADR-2 makes flipping the metadata backend an operator action: edit the
/// hosted config, and the next launch resolves a different source. The rows in
/// the library are still stamped with the backend they were recorded against,
/// and their ids are namespaced per backend (ADR-4).
///
/// So the detail screen must never hand a row's id to whichever source happens
/// to be active now. That request succeeds — it just describes a completely
/// different title, which is then cached as this one. Wrong data, no exception,
/// nothing to notice.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a row on the active backend yields that backend id', () async {
    final item = await seed.seedShow(db, tmdbId: 95396);

    expect(item.refFor(MetadataSourceKind.tmdb)?.id, 95396);
  });

  test('a row recorded against the inactive backend yields nothing', () async {
    final item = await seed.seedShow(db, tmdbId: 95396);

    expect(
      item.refFor(MetadataSourceKind.tvdb)?.id,
      isNull,
      reason:
          'null is the established "cannot fetch metadata for this row" '
          'signal, and the detail screen already renders from the stored '
          'columns when it sees one',
    );
  });

  test('the id is never borrowed from the other backend column', () async {
    final item = await seed.seedShow(
      db,
      source: MetadataSourceKind.tvdb,
      tmdbId: null,
      tvdbId: 371980,
    );

    expect(item.refFor(MetadataSourceKind.tvdb)?.id, 371980);
    expect(item.refFor(MetadataSourceKind.tmdb)?.id, isNull);
  });

  test('a row with no id for its own backend still yields nothing', () async {
    final item = await seed.seedShow(db, tmdbId: null, imdbId: 'tt11280740');

    expect(item.refFor(MetadataSourceKind.tmdb)?.id, isNull);
  });

  testWidgets('the screen renders the stored row and fetches nothing', (
    tester,
  ) async {
    // Recorded against TMDB; TVDB is now active, as an ADR-2 config flip would
    // leave it until the user relinks.
    final item = await seed.seedShow(
      db,
      title: 'Severance',
      tmdbId: 95396,
      episodeCountTotal: 9,
      watched: const [(1, 1), (1, 2)],
    );

    final source = _SpySource();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tvdb),
          activeMetadataSourceProvider.overrideWithValue(source),
          // Synchronous snapshots: a live Drift `.watch()` never quiesces under
          // fake-async, so pumpAndSettle would hang (CLAUDE.md).
          libraryItemProvider.overrideWith((ref, i) => Stream.value(item)),
          watchedEpisodesProvider.overrideWith(
            (ref, i) => Stream.value(const {(1, 1), (1, 2)}),
          ),
        ],
        child: MaterialApp(home: DetailScreen(itemId: item.id)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      source.calls,
      0,
      reason:
          'the row is recorded against TMDB and TVDB is active, so there '
          'is no id it is safe to fetch with',
    );
    expect(
      find.text('Severance'),
      findsWidgets,
      reason: 'the stored row still renders — degrading, not blanking',
    );
    // Stored *progress* has no surface on this screen — the per-episode
    // toggles need the fetched season listing, and the grid caption is where
    // the denormalized columns are rendered (covered by the library tests).
    // What must hold here is that nothing blanks and nothing is fetched.
    expect(
      find.byType(RemoteImage),
      findsWidgets,
      reason:
          'artwork still renders — through the module, which shows its '
          'placeholder rather than resolving a URL against the wrong backend',
    );
  });
}
