import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/theme/watchnook_theme.dart';
import 'package:watch_nook/core/widgets/poster_placeholder.dart';

/// T10 — the shared placeholder replaced three divergent private copies
/// (library grid, search row, import row). These pin the contract each call
/// site depends on.
void main() {
  Widget host(Widget child) => MaterialApp(
    theme: WatchnookTheme.dark,
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('renders at the requested size', (tester) async {
    await tester.pumpWidget(
      host(const PosterPlaceholder(width: 40, height: 60)),
    );

    expect(
      tester.getSize(find.byType(PosterPlaceholder)),
      const Size(40, 60),
    );
  });

  testWidgets('unsized placeholder fills its parent', (tester) async {
    // The library grid hands it a cell and expects it to fill it — a hard-coded
    // width/height default would letterbox every card.
    await tester.pumpWidget(
      host(const SizedBox(width: 120, height: 200, child: PosterPlaceholder())),
    );

    expect(
      tester.getSize(find.byType(PosterPlaceholder)),
      const Size(120, 200),
    );
  });

  testWidgets('a tag renders a TypeBadge with that label', (tester) async {
    await tester.pumpWidget(host(const PosterPlaceholder(tag: 'TV')));

    expect(find.byType(TypeBadge), findsOneWidget);
    expect(find.text('TV'), findsOneWidget);
  });

  testWidgets('a null tag renders no TypeBadge', (tester) async {
    await tester.pumpWidget(host(const PosterPlaceholder()));

    expect(find.byType(TypeBadge), findsNothing);
  });
}
