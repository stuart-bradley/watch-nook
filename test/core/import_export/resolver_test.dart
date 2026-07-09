import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/import_export/import/resolver.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// #23 AD-3 — the rung cascade. Adversarial throughout: the failure that
/// matters is not "a title didn't resolve", it is **a title resolved to the
/// wrong show** and quietly inherited someone's watch history. So every test
/// that could tempt a loose match asserts [Ambiguous], and the rung-2 tests
/// assert *zero* network calls (a resolver that searches when it already holds
/// a usable id turns a 300-title import into 300 HTTP round-trips).

class _FakeSource implements MetadataSource {
  _FakeSource({this.byImdb, this.hits = const [], this.failWith});

  final MediaSearchResult? byImdb;
  final List<MediaSearchResult> hits;
  final MetadataException? failWith;

  int resolveCalls = 0;
  int searchCalls = 0;

  @override
  Future<MediaSearchResult?> resolveByExternalId(String imdbId) async {
    resolveCalls++;
    if (failWith case final e?) throw e;
    return byImdb;
  }

  @override
  Future<List<MediaSearchResult>> search(
    String query, {
    MediaKind? kind,
  }) async {
    searchCalls++;
    if (failWith case final e?) throw e;
    return hits;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

ImportRecord _record({
  String title = 'Severance',
  int? year = 2022,
  String? imdbId,
  int? tmdbId,
  int? tvdbId,
  MediaType mediaType = MediaType.tv,
}) => ImportRecord(
  mediaType: mediaType,
  title: title,
  year: year,
  imdbId: imdbId,
  tmdbId: tmdbId,
  tvdbId: tvdbId,
);

MediaSearchResult _hit({
  String title = 'Severance',
  int? year = 2022,
  int? tmdbId = 95396,
}) => MediaSearchResult(
  kind: MediaKind.tv,
  title: title,
  year: year,
  tmdbId: tmdbId,
);

void main() {
  Resolver resolverOn(
    _FakeSource source, {
    MetadataSourceKind kind = MetadataSourceKind.tmdb,
  }) => Resolver(source: source, sourceKind: kind);

  group('rung 1 — imdb id', () {
    test('resolves through the universal join key without searching', () async {
      final source = _FakeSource(byImdb: _hit());

      final result = await resolverOn(
        source,
      ).resolve(_record(imdbId: 'tt11280740'));

      expect(result, isA<Auto>());
      expect((result as Auto).match?.tmdbId, 95396);
      expect(source.searchCalls, 0);
    });

    test('an imdb id the backend cannot match falls through', () async {
      // Not a failure — TVDB simply may not carry the title. Falling through is
      // what stops a movie-only imdb id from being dropped entirely.
      final source = _FakeSource(hits: [_hit()]);

      final result = await resolverOn(source).resolve(_record(imdbId: 'tt999'));

      expect(result, isA<Auto>());
      expect(source.resolveCalls, 1);
      expect(source.searchCalls, 1);
    });
  });

  group('rung 2 — an id already in the active backend namespace', () {
    test('a tmdb id on the tmdb backend costs no network call', () async {
      final source = _FakeSource();

      final result = await resolverOn(source).resolve(_record(tmdbId: 95396));

      expect(result, isA<Auto>());
      expect((result as Auto).match, isNull, reason: 'record fields carry');
      expect(source.searchCalls, 0);
      expect(source.resolveCalls, 0);
    });

    test(
      'a tvdb id on the tmdb backend is useless and falls to search',
      () async {
        final source = _FakeSource(hits: [_hit()]);

        final result = await resolverOn(source).resolve(_record(tvdbId: 73244));

        expect(result, isA<Auto>());
        expect(source.searchCalls, 1);
      },
    );

    test('a tvdb id on the tvdb backend costs no network call', () async {
      final source = _FakeSource();

      final result = await resolverOn(
        source,
        kind: MetadataSourceKind.tvdb,
      ).resolve(_record(tvdbId: 73244));

      expect(result, isA<Auto>());
      expect(source.searchCalls, 0);
    });
  });

  group('rung 3 — title search', () {
    test('exactly one title+year match auto-resolves', () async {
      final source = _FakeSource(
        hits: [
          _hit(),
          _hit(title: 'Severance: The Lexington Letter'),
        ],
      );

      final result = await resolverOn(source).resolve(_record());

      expect(result, isA<Auto>());
      expect((result as Auto).match?.title, 'Severance');
    });

    test('punctuation and case do not block a match', () async {
      final source = _FakeSource(hits: [_hit(title: 'the office  us')]);

      final result = await resolverOn(
        source,
      ).resolve(_record(title: 'The Office (US)'));

      expect(result, isA<Auto>());
    });

    test(
      'a year within one year still matches (release vs air skew)',
      () async {
        final source = _FakeSource(hits: [_hit(year: 2021)]);

        expect(
          await resolverOn(source).resolve(_record()),
          isA<Auto>(),
        );
      },
    );

    test(
      'two identically-titled candidates go to the queue, never auto',
      () async {
        // The regression: picking `hits.first` here files a remake's watch
        // history under the original.
        final source = _FakeSource(
          hits: [_hit(tmdbId: 1), _hit(tmdbId: 2)],
        );

        final result = await resolverOn(source).resolve(_record());

        expect(result, isA<Ambiguous>());
        expect((result as Ambiguous).candidates, hasLength(2));
      },
    );

    test('a title match with a wrong year goes to the queue', () async {
      final source = _FakeSource(hits: [_hit(year: 2005)]);

      expect(
        await resolverOn(source).resolve(_record()),
        isA<Ambiguous>(),
      );
    });

    test(
      'a record with no year abstains on year rather than failing',
      () async {
        final source = _FakeSource(hits: [_hit(year: 1978)]);

        expect(
          await resolverOn(source).resolve(_record(year: null)),
          isA<Auto>(),
        );
      },
    );

    test(
      'no candidates at all is still an ambiguous, with nothing to pick',
      () async {
        final result = await resolverOn(_FakeSource()).resolve(_record());

        expect(result, isA<Ambiguous>());
        expect((result as Ambiguous).candidates, isEmpty);
      },
    );

    test('the confirmation queue is capped at five candidates', () async {
      final source = _FakeSource(
        hits: [for (var i = 0; i < 9; i++) _hit(title: 'Other $i')],
      );

      final result = await resolverOn(source).resolve(_record());

      expect((result as Ambiguous).candidates, hasLength(5));
    });
  });

  group('rung 4 — the backend is down', () {
    test('a search failure yields Unresolved, not a thrown import', () async {
      final source = _FakeSource(
        failWith: const MetadataException(503, 'down'),
      );

      final result = await resolverOn(source).resolve(_record());

      expect(result, isA<Unresolved>());
      expect((result as Unresolved).reason, contains('503'));
    });

    test('an imdb lookup failure yields Unresolved', () async {
      final source = _FakeSource(
        failWith: const MetadataException(429, 'slow'),
      );

      final result = await resolverOn(source).resolve(_record(imdbId: 'tt1'));

      expect(result, isA<Unresolved>());
      expect(source.searchCalls, 0, reason: 'no point retrying a down backend');
    });
  });

  group('normalizeTitle', () {
    test('folds case and punctuation to a single space', () {
      expect(normalizeTitle('Love, Death & Robots'), 'love death robots');
      expect(normalizeTitle('  The Office (U.S.)  '), 'the office u s');
    });

    test('keeps non-Latin scripts instead of erasing them', () {
      // An ASCII-only fold would collapse both of these to '' — and then two
      // unrelated shows would compare *equal* and auto-match each other.
      expect(normalizeTitle('鬼滅の刃'), isNot(isEmpty));
      expect(normalizeTitle('鬼滅の刃'), isNot(normalizeTitle('進撃の巨人')));
    });

    test('does not fold diacritics — the pair goes to a human', () {
      expect(normalizeTitle('Shōgun'), isNot(normalizeTitle('Shogun')));
    });
  });
}
