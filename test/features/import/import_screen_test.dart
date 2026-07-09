import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/import/data/import_providers.dart';
import 'package:watch_nook/features/import/presentation/import_screen.dart';

/// #28 / US-10, US-12 — the import screen, end to end over the **real**
/// pipeline (archive → importer → resolver → applier) with only the platform
/// file picker and the HTTP source faked. Nothing here mocks `ImportService`,
/// so a regression in resolve-or-apply fails this test too.
///
/// Adversarial angles, each a bug someone would otherwise ship:
/// - the applier runs during resolution, so abandoning the confirmation screen
///   has already written rows the user never confirmed;
/// - a skipped title lands anyway (the "skip" only greys out the card);
/// - the confirmed candidate's ids are dropped, so the row imports under the
///   record's bare title and can never be relinked;
/// - an unrecognized file throws out of `main` instead of showing a message.

/// `Dune` comes out of the export with **no year** (neither the column nor the
/// slug carries one), so the resolver's year tie-break abstains, both hits stay
/// confident, and — wanting *exactly one* (AD-3 rung 3) — it hands the film to
/// the confirmation queue. `The Thing` has a single hit and auto-resolves.
class _FakeSource implements MetadataSource {
  @override
  Future<List<MediaSearchResult>> search(
    String query, {
    MediaKind? kind,
  }) async {
    if (query == 'Dune') {
      return const [
        MediaSearchResult(
          kind: MediaKind.movie,
          title: 'Dune',
          tmdbId: 438631,
          year: 2021,
        ),
        MediaSearchResult(
          kind: MediaKind.movie,
          title: 'Dune',
          tmdbId: 841,
          year: 1984,
        ),
      ];
    }
    if (query == 'The Thing') {
      return const [
        MediaSearchResult(
          kind: MediaKind.movie,
          title: 'The Thing',
          tmdbId: 1091,
          year: 1982,
        ),
      ];
    }
    return const [];
  }

  @override
  String imageUrl(String path, ImageSize size) => 'https://example.test$path';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A Letterboxd `watched.csv` — no ids, so both films take the search rung.
const _watchedCsv =
    'Date,Name,Year,Letterboxd URI\n'
    '2024-01-02,Dune,,https://letterboxd.com/film/dune/\n'
    '2024-01-03,The Thing,1982,https://letterboxd.com/film/the-thing/\n';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Widget harness({String csv = _watchedCsv, String name = 'watched.csv'}) =>
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
          activeMetadataSourceProvider.overrideWithValue(_FakeSource()),
          importFilePickerProvider.overrideWithValue(
            () async =>
                (name: name, bytes: Uint8List.fromList(utf8.encode(csv))),
          ),
        ],
        child: const MaterialApp(home: ImportScreen()),
      );

  Future<void> pickFile(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
  }

  testWidgets('an ambiguous title is confirmable, and the confirmed candidate '
      'is what lands in the library', (tester) async {
    await pickFile(tester);

    // One auto-match, one title in the queue with both candidates offered.
    expect(
      find.text(
        '1 title matched automatically. '
        "Pick a match for the rest, or skip the ones you don't want.",
      ),
      findsOneWidget,
    );
    expect(find.text('From your export'), findsOneWidget);
    expect(find.text('2021 · Film'), findsOneWidget);
    expect(find.text('1984 · Film'), findsOneWidget);

    // Nothing is written before the user confirms — the sharpest regression
    // here is an applier that runs at resolve time.
    expect(await db.libraryDao.getAll(), isEmpty);
    expect(find.text('Import 1 title'), findsOneWidget);

    await tester.tap(find.text('2021 · Film'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 2 titles'));
    await tester.pumpAndSettle();

    expect(find.text('Import complete'), findsOneWidget);
    expect(find.text('Titles added: 2'), findsOneWidget);
    expect(find.text('Titles skipped: 0'), findsOneWidget);

    final items = await db.libraryDao.getAll();
    expect(items.map((i) => i.title), containsAll(['Dune', 'The Thing']));

    // The *chosen* candidate's id, not the 1984 one and not null.
    final dune = items.firstWhere((i) => i.title == 'Dune');
    expect(dune.tmdbId, 438631);
    expect(dune.year, 2021);
  });

  testWidgets('a skipped title is left out of the library entirely', (
    tester,
  ) async {
    await pickFile(tester);

    await tester.tap(find.text('Skip this title'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 1 title'));
    await tester.pumpAndSettle();

    expect(find.text('Titles added: 1'), findsOneWidget);
    expect(find.text('Titles skipped: 1'), findsOneWidget);

    final items = await db.libraryDao.getAll();
    expect(items.map((i) => i.title), ['The Thing']);
  });

  testWidgets('an unrecognized file reports a message and writes nothing', (
    tester,
  ) async {
    await tester.pumpWidget(harness(csv: 'a,b\n1,2\n', name: 'notes.csv'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();

    expect(
      find.text('Not a TV Time, Trakt, IMDb or Letterboxd export.'),
      findsOneWidget,
    );
    expect(await db.libraryDao.getAll(), isEmpty);
  });
}
