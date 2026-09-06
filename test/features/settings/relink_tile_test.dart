// The ids below repeat the fixture defaults on purpose: these tests are about
// WHICH id is used for which backend, so spelling it out at the seed site is
// what makes the assertion legible.
// ignore_for_file: avoid_redundant_argument_values
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/switch/backend_switch_providers.dart';
import 'package:watch_nook/core/metadata/switch/backend_switch_service.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';
import 'package:watch_nook/features/settings/presentation/settings_screen.dart';

import '../../support/library_fixtures.dart' as seed;

/// The relink affordance for an ADR-2 backend flip.
///
/// The flip happens in a hosted config file the user never sees, and relinking
/// rewrites ids and `recordedSource` on rows carrying their watch history — so
/// it is offered, never performed unprompted. These pin both halves: the offer
/// appears only when there is something stranded, and nothing relinks on its
/// own.
/// Stands in for the relink itself. The service's own behaviour is
/// `backend_switch_service_test`'s job; what matters here is that the tile
/// invokes it exactly once and renders what it reports — and a spy keeps that
/// assertion off the real database, whose async does not resolve under
/// `flutter_test` fake time inside a widget callback.
class _SpySwitch implements BackendSwitchService {
  _SpySwitch(this.report);

  final BackendSwitchReport report;
  int calls = 0;

  @override
  Future<BackendSwitchReport> switchAll() async {
    calls++;
    return report;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _StubSource implements MetadataSource {
  @override
  Attribution attribution() =>
      const Attribution(notice: 'n', linkUrl: 'https://example.org');
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late AppDatabase db;
  late _SpySwitch relink;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    relink = _SpySwitch(
      const BackendSwitchReport(relinked: 4, flagged: 1, skipped: 2),
    );
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, {required int stranded}) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tvdb),
          activeMetadataSourceProvider.overrideWithValue(_StubSource()),
          backendMismatchCountProvider.overrideWith((ref) async => stranded),
          backendSwitchServiceProvider.overrideWithValue(relink),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no offer when every row is on the active backend', (
    tester,
  ) async {
    await pump(tester, stranded: 0);

    expect(find.text('Relink your library'), findsNothing);
  });

  testWidgets('the offer names how many titles are stranded', (tester) async {
    await pump(tester, stranded: 3);

    expect(find.text('Relink your library'), findsOneWidget);
    expect(
      find.textContaining('3 titles were added using a different'),
      findsOneWidget,
    );
  });

  testWidgets('one stranded title reads as singular', (tester) async {
    await pump(tester, stranded: 1);

    expect(
      find.textContaining('1 title was added using a different'),
      findsOneWidget,
    );
  });

  testWidgets('tapping it relinks and reports', (tester) async {
    await pump(tester, stranded: 2);

    await tester.tap(find.text('Relink your library'));
    await tester.pumpAndSettle();

    expect(relink.calls, 1, reason: 'exactly once per tap');
    expect(
      find.textContaining('Relinked 4.'),
      findsOneWidget,
      reason: 'the report is surfaced, not swallowed',
    );
    expect(
      find.textContaining('1 need a look'),
      findsOneWidget,
      reason: 'flagged rows are named — those are the ones the user must check',
    );
  });

  test('the count is of rows NOT on the active backend', () async {
    await seed.seedShow(db, title: 'Old TMDB row', tmdbId: 95396);
    await seed.seedShow(
      db,
      title: 'Already TVDB',
      source: MetadataSourceKind.tvdb,
      tmdbId: null,
      tvdbId: 371980,
    );

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tvdb),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(backendMismatchCountProvider.future), 1);
  });
}
