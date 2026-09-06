import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
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

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late _SpySource source;

  setUp(() => source = _SpySource());

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [activeMetadataSourceProvider.overrideWithValue(source)],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pump();
  }

  testWidgets('a null path renders a placeholder and asks for no URL', (
    tester,
  ) async {
    await pump(tester, const RemoteImage.thumbnail(path: null));

    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(
      source.asked,
      isEmpty,
      reason: 'a title with no artwork must never reach the network',
    );
  });

  testWidgets('a null card path still carries its type badge', (tester) async {
    await pump(tester, const RemoteImage.card(path: null, tag: 'Film'));

    expect(find.text('Film'), findsOneWidget);
    expect(source.asked, isEmpty);
  });

  testWidgets('a null backdrop path renders 16:9 and asks for no URL', (
    tester,
  ) async {
    await pump(tester, const RemoteImage.backdrop(path: null));

    expect(find.byType(AspectRatio), findsOneWidget);
    expect(source.asked, isEmpty);
  });

  testWidgets('each shape asks the active source for its own image size', (
    tester,
  ) async {
    await pump(tester, const RemoteImage.thumbnail(path: '/a.jpg'));
    expect(source.asked.single, ('/a.jpg', ImageSize.small));

    source.asked.clear();
    await pump(tester, const RemoteImage.card(path: '/b.jpg', tag: 'TV'));
    expect(source.asked.single, ('/b.jpg', ImageSize.medium));

    source.asked.clear();
    await pump(tester, const RemoteImage.backdrop(path: '/c.jpg'));
    expect(source.asked.single, ('/c.jpg', ImageSize.large));
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
