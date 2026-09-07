import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/core/widgets/poster_placeholder.dart';
import 'package:watch_nook/core/widgets/remote_image.dart';

/// The offline-first rule used to be restated at five call sites, and the
/// copies had already drifted. Now there is one module, so this is the one
/// place the rule has to hold.
class _SpySource implements MetadataSource {
  final List<(String path, ImageSize size)> asked = [];

  @override
  String imageUrl(String path, ImageSize size) {
    asked.add((path, size));
    return 'https://example.org/$size$path';
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

/// A path this test's active source (TMDB) really did mint.
ArtworkRef _tmdb(String path) => ArtworkRef(MetadataSourceKind.tmdb, path);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late _SpySource source;
  late AppDatabase db;

  setUp(() {
    source = _SpySource();
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The one metadata provider IS the cache now, so it needs a database
          // even where the test only exercises `imageUrl`.
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataSourceProvider.overrideWithValue(source),
          activeMetadataKindProvider.overrideWithValue(
            MetadataSourceKind.tmdb,
          ),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pump();
  }

  testWidgets('a null path renders a placeholder and asks for no URL', (
    tester,
  ) async {
    await pump(tester, const RemoteImage.thumbnail(artwork: null));

    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(
      source.asked,
      isEmpty,
      reason: 'a title with no artwork must never reach the network',
    );
  });

  testWidgets('a null card path still carries its type badge', (tester) async {
    await pump(tester, const RemoteImage.card(artwork: null, tag: 'Film'));

    expect(find.text('Film'), findsOneWidget);
    expect(source.asked, isEmpty);
  });

  testWidgets('a null backdrop path renders 16:9 and asks for no URL', (
    tester,
  ) async {
    await pump(tester, const RemoteImage.backdrop(artwork: null));

    expect(find.byType(AspectRatio), findsOneWidget);
    expect(source.asked, isEmpty);
  });

  testWidgets('each shape asks the active source for its own image size', (
    tester,
  ) async {
    await pump(tester, RemoteImage.thumbnail(artwork: _tmdb('/a.jpg')));
    expect(source.asked.single, ('/a.jpg', ImageSize.small));

    source.asked.clear();
    await pump(
      tester,
      RemoteImage.card(artwork: _tmdb('/b.jpg'), tag: 'TV'),
    );
    expect(source.asked.single, ('/b.jpg', ImageSize.medium));

    source.asked.clear();
    await pump(tester, RemoteImage.backdrop(artwork: _tmdb('/c.jpg')));
    expect(source.asked.single, ('/c.jpg', ImageSize.large));
  });

  testWidgets('a poster from the other backend renders the placeholder', (
    tester,
  ) async {
    // The stranded row. ADR-2 flips the backend remotely, and a relink rewrites
    // ids and `recordedSource` but NOT `posterPath` — and the periodic sync
    // only heals TV rows, so a movie's poster stays stranded indefinitely.
    // Resolved through the active source this path builds a URL that 404s, or
    // loads an unrelated image. Proved to fail first: without the kind check
    // in RemoteImage the source is asked, and it is asked with a path from a
    // catalogue that never minted it.
    await pump(
      tester,
      const RemoteImage.card(
        artwork: ArtworkRef(MetadataSourceKind.tvdb, 'https://tvdb/x.jpg'),
        tag: 'Film',
      ),
    );

    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(
      source.asked,
      isEmpty,
      reason:
          'the active source must never be asked to resolve a path it '
          'did not mint',
    );
  });

  test('the thumbnail box is defined once, at the poster aspect', () {
    expect(RemoteImage.thumbnailWidth, 40);
    expect(
      RemoteImage.thumbnailHeight,
      greaterThan(RemoteImage.thumbnailWidth),
      reason: 'posters are taller than they are wide',
    );
  });
}
