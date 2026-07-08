import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/main.dart';

void main() {
  testWidgets('boots to a blank Watchnook home', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: WatchnookApp()));

    // Home renders with its app-bar title.
    expect(find.widgetWithText(AppBar, 'Watchnook'), findsOneWidget);

    // Adversarial: debug banner off, and no home/router conflict (a
    // MaterialApp with both `home:` and `routerConfig:` throws at build). #4
    // flips this to a router config — guard against leaving both wired at once.
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.debugShowCheckedModeBanner, isFalse);
    expect(app.home, isNotNull);
    expect(app.routerConfig, isNull);
  });
}
