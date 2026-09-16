// The ids repeat the fixture defaults on purpose: these tests are about WHICH
// id is used for which backend, so spelling it out at the seed site is what
// makes the assertion legible.
// ignore_for_file: avoid_redundant_argument_values
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';
import 'package:watch_nook/features/detail/data/detail_target.dart';

import '../../support/library_fixtures.dart' as seed;

/// "Which title is this, from which backend, and is it already tracked?" used
/// to be answered by a chain of nullable expressions inside a widget's build
/// method, testable only by rendering a screen. These drive the same question
/// directly.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  DetailTarget resolve({
    LibraryItem? item,
    MediaSearchResult? result,
    MetadataSourceKind active = MetadataSourceKind.tmdb,
  }) => detailTargetOf(item: item, result: result, active: active);

  const hit = MediaSearchResult(
    kind: MediaKind.tv,
    title: 'Severance',
    tmdbId: 95396,
  );

  test('a tracked row on the active backend is fetchable', () async {
    final item = await seed.seedShow(db, tmdbId: 95396);

    final target = resolve(item: item);

    expect(target, isA<TrackedTitle>());
    expect(target.fetchRef, const SourceRef(MetadataSourceKind.tmdb, 95396));
    expect(target.mediaType, MediaType.tv);
  });

  test('a row recorded against the other backend is stranded', () async {
    final item = await seed.seedShow(db, tmdbId: 95396);

    final target = resolve(item: item, active: MetadataSourceKind.tvdb);

    expect(
      target,
      isA<StrandedTitle>().having(
        (t) => t.reason,
        'reason',
        Unfetchable.recordedAgainstAnotherBackend,
      ),
    );
    expect(
      target.fetchRef,
      isNull,
      reason:
          'its tmdb id names a different title in the tvdb catalogue, and '
          'that request would succeed',
    );
  });

  test('a row with no id for its own backend is stranded too, but for a '
      'different reason', () async {
    final item = await seed.seedShow(db, tmdbId: null, imdbId: 'tt11280740');

    final target = resolve(item: item);

    expect(
      target,
      isA<StrandedTitle>().having(
        (t) => t.reason,
        'reason',
        Unfetchable.noIdForItsBackend,
      ),
      reason:
          'both cases render identically, but only one of them is repairable '
          'by relinking — the distinction is the point of the reason',
    );
    expect(target.fetchRef, isNull);
  });

  test('the two stranded reasons are not interchangeable', () async {
    final wrongBackend = await seed.seedShow(db, tmdbId: 95396);
    final noId = await seed.seedShow(
      db,
      title: 'Dark',
      tmdbId: null,
      imdbId: 'tt5753856',
    );

    expect(
      (resolve(item: wrongBackend, active: MetadataSourceKind.tvdb)
              as StrandedTitle)
          .reason,
      isNot(equals((resolve(item: noId) as StrandedTitle).reason)),
    );
  });

  test('an untracked hit previews through the active backend', () {
    final target = resolve(result: hit);

    expect(target, isA<PreviewTitle>());
    expect(target.fetchRef, const SourceRef(MetadataSourceKind.tmdb, 95396));
  });

  test('a hit with no id for the active backend previews unfetchably', () {
    final target = resolve(result: hit, active: MetadataSourceKind.tvdb);

    expect(target, isA<PreviewTitle>());
    expect(
      target.fetchRef,
      isNull,
      reason: 'the hit carries no tvdb id, so there is nothing to ask for',
    );
  });

  test('neither a row nor a hit is unknown, with nothing to render', () {
    final target = resolve();

    expect(target, isA<UnknownTitle>());
    expect(target.fetchRef, isNull);
    expect(
      target.mediaType,
      isNull,
      reason:
          'defaulting the media type here would pick a layout for a title '
          'that does not exist',
    );
  });

  test('a tracked row wins over a hit', () async {
    final item = await seed.seedShow(db, tmdbId: 95396);

    expect(resolve(item: item, result: hit), isA<TrackedTitle>());
  });
}
