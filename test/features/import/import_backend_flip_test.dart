import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_provider.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/features/import/data/import_providers.dart';
import 'package:watch_nook/features/import/domain/import_state.dart';

/// ADR-2 makes flipping the metadata backend an operator action taken in a
/// hosted config file — it can land at any moment, including while the user is
/// sitting on the import confirmation screen deciding between two candidates.
///
/// The candidates on that screen were resolved against the backend that was
/// active when the file was read, and their ids are meaningless to any other
/// catalogue. Everything downstream of the resolve must therefore use the
/// backend it *resolved against*, not the one that happens to be active when
/// the user finally taps Apply.
///
/// Getting this wrong writes real watch history into the library stamped with
/// a `recordedSource` that never minted its ids — the wrong-title bug, baked
/// into the user's precious data rather than into a render.
class _FakeSource implements MetadataSource {
  @override
  Future<List<MediaSearchResult>> search(
    String query, {
    MediaKind? kind,
  }) async {
    if (query != 'Dune') return const [];
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

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A Letterboxd export. Dune carries **no year**, so the resolver's tie-break
/// abstains, both hits stay confident, and it reaches the confirmation queue —
/// which is the only state that outlives a flip.
const _csv =
    'Date,Name,Year,Letterboxd URI\n'
    '2024-01-02,Dune,,https://letterboxd.com/film/dune/\n';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a backend flip mid-confirmation does not restamp the import', () async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tmdb),
        activeMetadataSourceProvider.overrideWithValue(_FakeSource()),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(importControllerProvider.notifier)
        .importBytes('watched.csv', Uint8List.fromList(utf8.encode(_csv)));

    final confirming = container.read(importControllerProvider);
    expect(confirming, isA<ImportConfirming>());
    expect(
      (confirming as ImportConfirming).resolvedAgainst,
      MetadataSourceKind.tmdb,
      reason: 'the state carries the backend it resolved against',
    );

    // The operator flips the backend while the screen is open.
    container.updateOverrides([
      appDatabaseProvider.overrideWithValue(db),
      activeMetadataBackendProvider.overrideWithValue(MetadataBackend.tvdb),
      activeMetadataSourceProvider.overrideWithValue(_FakeSource()),
    ]);

    await container.read(importControllerProvider.notifier).applyConfirmed();

    final dune = (await db.libraryDao.getAll()).single;
    expect(dune.tmdbId, 438631, reason: 'a TMDB id, because TMDB resolved it');
    expect(
      dune.recordedSource,
      MetadataSourceKind.tmdb,
      reason:
          'stamping tvdb here would claim TheTVDB minted 438631 — it did not, '
          'and every later fetch for this row would return a different film',
    );
  });
}
