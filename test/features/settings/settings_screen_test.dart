import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/export/auto_backup_service.dart';
import 'package:watch_nook/core/import_export/export/export_providers.dart';
import 'package:watch_nook/core/import_export/export/import_export_service.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_provider.dart';
import 'package:watch_nook/features/settings/data/export_share.dart';
import 'package:watch_nook/features/settings/data/shared_preferences_provider.dart';
import 'package:watch_nook/features/settings/data/theme_mode_provider.dart';
import 'package:watch_nook/features/settings/presentation/settings_screen.dart';

/// #35 / US-14 at the widget layer.
///
/// Adversarial framing:
/// - Each export button must call **its own** serializer. The easy bug is two
///   tiles wired to the same `exportJson()`, which a "did anything happen?"
///   assertion would happily pass.
/// - A user who backs out of the share sheet has not hit an error, and must not
///   be shown one. A dismissed sheet is a no-op, full stop.
/// - A serializer that throws must reach a SnackBar, not the red screen.
/// - The attribution footer is a licensing obligation, so it is asserted here
///   as well as on the detail screen — Settings is where a reviewer looks.

/// Records what each tile asked for. `implements` + `noSuchMethod` so the fake
/// never silently grows a real DB dependency.
class _FakeExportService implements ImportExportService {
  int jsonCalls = 0;
  int csvCalls = 0;
  Error? throwOnJson;

  @override
  Future<String> exportJson() async {
    jsonCalls++;
    if (throwOnJson case final error?) throw error;
    return '{"formatVersion":1}';
  }

  @override
  Future<String> exportLetterboxdCsv() async {
    csvCalls++;
    return 'Title,Year\nDune,2021\n';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeBackupService implements AutoBackupService {
  int snapshots = 0;
  int deletes = 0;
  Error? throwOnSnapshot;

  @override
  Future<void> snapshot() async {
    snapshots++;
    if (throwOnSnapshot case final error?) throw error;
  }

  // Faked (no real File I/O) so the widget test's pumpAndSettle doesn't hang;
  // the real delete is exercised in auto_backup_service_test.
  @override
  Future<void> deleteBackup() async => deletes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Only `attribution()` is reachable from Settings — nothing here fetches.
class _StubSource implements MetadataSource {
  @override
  Attribution attribution() => const Attribution(
    notice: 'This product uses the TMDB API but is not endorsed by TMDB.',
    linkUrl: 'https://www.themoviedb.org/',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// One share request, as the screen handed it over.
typedef _Shared = ({String fileName, String contents, String mimeType});

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late _FakeExportService service;
  late _FakeBackupService backup;
  late List<_Shared> shared;
  late bool shareSucceeds;

  setUp(() {
    service = _FakeExportService();
    backup = _FakeBackupService();
    shared = [];
    shareSucceeds = true;
  });

  Future<SharedPreferences> prefsWith(Map<String, Object> stored) {
    SharedPreferences.setMockInitialValues(stored);
    return SharedPreferences.getInstance();
  }

  Future<void> pump(
    WidgetTester tester, {
    Map<String, Object> stored = const {},
  }) async {
    final prefs = await prefsWith(stored);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          importExportServiceProvider.overrideWithValue(service),
          autoBackupServiceProvider.overrideWith((ref) async => backup),
          activeMetadataSourceProvider.overrideWithValue(_StubSource()),
          exportSharerProvider.overrideWithValue(
            ({
              required fileName,
              required contents,
              required mimeType,
            }) async {
              shared.add((
                fileName: fileName,
                contents: contents,
                mimeType: mimeType,
              ));
              return shareSucceeds;
            },
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The settings list is taller than the test viewport and `ListView` builds
  /// lazily, so a widget below the fold is not merely invisible — it is absent
  /// from the tree, and `ensureVisible` would throw "No element".
  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapTile(WidgetTester tester, String label) async {
    await reveal(tester, find.text(label));
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('Export JSON serializes once and shares a .json file', (
    tester,
  ) async {
    await pump(tester);
    await tapTile(tester, 'Export JSON');

    expect(service.jsonCalls, 1);
    expect(service.csvCalls, 0);
    expect(shared, hasLength(1));
    expect(shared.single.fileName, endsWith('.json'));
    expect(shared.single.mimeType, 'application/json');
    expect(shared.single.contents, '{"formatVersion":1}');
  });

  // Adversarial: the CSV tile must not be wired to exportJson().
  testWidgets('Export Letterboxd CSV uses the CSV serializer, not the JSON '
      'one', (tester) async {
    await pump(tester);
    await tapTile(tester, 'Export Letterboxd CSV');

    expect(service.csvCalls, 1);
    expect(service.jsonCalls, 0);
    expect(shared.single.fileName, endsWith('.csv'));
    expect(shared.single.mimeType, 'text/csv');
  });

  testWidgets('a dismissed share sheet is a silent no-op, not an error', (
    tester,
  ) async {
    shareSucceeds = false;
    await pump(tester);
    await tapTile(tester, 'Export JSON');

    expect(shared, hasLength(1));
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed export surfaces a SnackBar rather than throwing', (
    tester,
  ) async {
    service.throwOnJson = StateError('disk full');
    await pump(tester);
    await tapTile(tester, 'Export JSON');

    expect(shared, isEmpty);
    expect(find.text("Couldn't export your data."), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back up now refreshes the snapshot and confirms', (
    tester,
  ) async {
    await pump(tester);
    await tapTile(tester, 'Back up now');

    expect(backup.snapshots, 1);
    expect(find.text('Backup updated.'), findsOneWidget);
  });

  testWidgets('a failed backup surfaces a SnackBar rather than throwing', (
    tester,
  ) async {
    backup.throwOnSnapshot = StateError('no space');
    await pump(tester);
    await tapTile(tester, 'Back up now');

    expect(find.text("Couldn't back up your data."), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the theme picker reflects the stored mode and persists a '
      'change', (tester) async {
    await pump(tester, stored: {themeModeKey: 'system'});

    final picker = tester.widget<SegmentedButton<AppAppearance>>(
      find.byType(SegmentedButton<AppAppearance>),
    );
    expect(picker.selected, {AppAppearance.system});

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(themeModeKey), 'light');
    expect(
      tester
          .widget<SegmentedButton<AppAppearance>>(
            find.byType(SegmentedButton<AppAppearance>),
          )
          .selected,
      {AppAppearance.light},
    );
  });

  // The TMDB/TheTVDB credit is a licensing obligation (CLAUDE.md), and it
  // follows the active source rather than being hardcoded.
  testWidgets('the mandatory attribution renders the active source credit', (
    tester,
  ) async {
    await pump(tester);
    final notice = find.text(
      'This product uses the TMDB API but is not endorsed by TMDB.',
    );
    await reveal(tester, notice);

    expect(notice, findsOneWidget);
    expect(find.text('https://www.themoviedb.org/'), findsOneWidget);
  });

  // US-D1: one action erases everything, across all four surfaces a user's data
  // can hide in, and returns the app to first-run. The load-bearing step is
  // deleting the backup file — leave it and the wiped data re-restores.
  testWidgets('Delete all data wipes every surface and resets first-run', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = db.libraryDao;

    // Seed every surface: a tracked item, a watch event, and cached metadata.
    final at = DateTime(2026);
    final id = await dao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Severance',
        trackStatus: TrackStatus.watching,
        addedAt: at,
        updatedAt: at,
        tmdbId: const Value(95396),
      ),
    );
    await dao.markWatched(id, season: 1, episode: 1, watchedAt: at);
    await db.mediaCacheDao.upsertMedia(
      CachedMediaCompanion.insert(
        source: MetadataSourceKind.tmdb,
        mediaType: MediaType.tv,
        sourceId: 95396,
        payload: '{}',
        fetchedAt: at,
        title: 'Severance',
      ),
    );

    final prefs = await prefsWith({onboardingSeenKey: true});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          autoBackupServiceProvider.overrideWith((ref) async => backup),
          activeMetadataSourceProvider.overrideWithValue(_StubSource()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tapTile(tester, 'Delete all data');
    await tester.tap(find.text('Delete everything'));
    await tester.pumpAndSettle();

    expect(await dao.getAll(), isEmpty, reason: 'library wiped');
    expect(await db.select(db.watchEvents).get(), isEmpty, reason: 'history');
    expect(await db.select(db.cachedMedia).get(), isEmpty, reason: 'cache');
    expect(backup.deletes, 1, reason: 'the backup file is deleted too');
    expect(
      prefs.getBool(onboardingSeenKey),
      isFalse,
      reason: 'first-run reset',
    );
  });

  testWidgets('Delete all data can be cancelled without wiping anything', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = db.libraryDao;
    await dao.insertItem(
      LibraryItemsCompanion.insert(
        mediaType: MediaType.tv,
        recordedSource: MetadataSourceKind.tmdb,
        title: 'Kept',
        trackStatus: TrackStatus.watching,
        addedAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tmdbId: const Value(1),
      ),
    );
    final prefs = await prefsWith({onboardingSeenKey: true});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          activeMetadataSourceProvider.overrideWithValue(_StubSource()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tapTile(tester, 'Delete all data');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await dao.getAll(), hasLength(1), reason: 'nothing wiped on cancel');
  });

  testWidgets('Dynamic (Material You) is offered and persists (#51)', (
    tester,
  ) async {
    await pump(tester, stored: {themeModeKey: 'dark'});
    expect(find.text('Dynamic'), findsOneWidget);

    await tester.tap(find.text('Dynamic'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(themeModeKey), 'dynamicColor');
    expect(
      tester
          .widget<SegmentedButton<AppAppearance>>(
            find.byType(SegmentedButton<AppAppearance>),
          )
          .selected,
      {AppAppearance.dynamicColor},
    );
  });
}
