import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/tmdb/tmdb_source.dart';

String _fixture(String name) =>
    File('test/fixtures/metadata/tmdb/$name').readAsStringSync();

/// Routes TMDB endpoints to committed fixtures. An unmatched path returns a
/// 404 with TMDB's error-body shape so the adversarial test can assert on it.
MockClient _fixtureClient({http.Request? Function(http.Request)? spy}) =>
    MockClient((request) async {
      spy?.call(request);
      final path = request.url.path;
      if (path.endsWith('/search/tv')) {
        return http.Response(_fixture('search_tv.json'), 200);
      }
      if (path.endsWith('/search/multi')) {
        return http.Response(_fixture('search_multi.json'), 200);
      }
      if (path.contains('/tv/95396/season/')) {
        return http.Response(_fixture('tv_season1.json'), 200);
      }
      if (path.endsWith('/tv/95396')) {
        return http.Response(_fixture('tv_details.json'), 200);
      }
      if (path.endsWith('/movie/545611')) {
        return http.Response(_fixture('movie_details.json'), 200);
      }
      if (path.contains('/find/')) {
        return http.Response(_fixture('find_imdb.json'), 200);
      }
      return http.Response(
        '{"success":false,"status_code":34,'
        '"status_message":"The resource you requested could not be found."}',
        404,
      );
    });

TmdbSource _source({
  http.Client? client,
  String apiKey = 'test-key',
  String readToken = '',
}) => TmdbSource(
  client: client ?? _fixtureClient(),
  apiKey: apiKey,
  readToken: readToken,
);

void main() {
  group('attribution (TMDB compliance — #53)', () {
    test('notice is the EXACT TMDB-required wording (no paraphrase)', () {
      // TMDB API terms mandate this string verbatim; a paraphrase is a
      // compliance violation. This is the regression guard for #53.
      expect(
        _source().attribution().notice,
        'This product uses TMDB and the TMDB APIs but is not endorsed, '
        'certified, or otherwise approved by TMDB.',
      );
    });

    test('bundles the TMDB logo asset (the terms require the logo too)', () {
      expect(
        _source().attribution().logoAsset,
        'assets/branding/tmdb_logo.png',
      );
    });
  });

  group('search', () {
    test('narrowed to tv normalizes ids, title, and year', () async {
      final results = await _source().search('severance', kind: MediaKind.tv);

      expect(results, hasLength(1));
      final r = results.single;
      expect(r.kind, MediaKind.tv);
      expect(r.tmdbId, 95396);
      expect(r.title, 'Severance');
      expect(r.year, 2022);
      expect(r.posterPath, isNotNull);
    });

    test('multi filters out person rows and keeps movie + tv', () async {
      final results = await _source().search('severance');

      // The fixture has tv + movie + person; person must be dropped.
      expect(results.map((r) => r.kind), [MediaKind.tv, MediaKind.movie]);
      expect(results[0].title, 'Severance');
      expect(results[1].tmdbId, 9741);
      expect(results[1].year, 2006);
    });
  });

  group('showDetails', () {
    test('inlines external_ids, next episode, seasons, and genres', () async {
      final d = await _source().showDetails(95396);

      expect(d.kind, MediaKind.tv);
      expect(d.imdbId, 'tt11280740');
      expect(d.showStatus, 'Returning Series');
      expect(d.episodeCountTotal, 19);
      expect(d.runtimeMinutes, 50);
      expect(d.genres, ['Drama', 'Mystery']);
      expect(d.seasons, hasLength(3));
      expect(d.nextEpisode, isNotNull);
      expect(d.nextEpisode!.airDate, DateTime.parse('2027-01-15'));
    });
  });

  group('movieDetails', () {
    test(
      'normalizes runtime, year, imdbId, and leaves seasons empty',
      () async {
        final d = await _source().movieDetails(545611);

        expect(d.kind, MediaKind.movie);
        expect(d.title, 'Everything Everywhere All at Once');
        expect(d.imdbId, 'tt6710474');
        expect(d.runtimeMinutes, 139);
        expect(d.year, 2022);
        expect(d.seasons, isEmpty);
        expect(d.genres, contains('Science Fiction'));
      },
    );
  });

  group('seasonEpisodes', () {
    test('returns episodes in contiguous aired order (ADR-4)', () async {
      final eps = await _source().seasonEpisodes(95396, 1);

      expect(eps.map((e) => e.episodeNumber), [1, 2, 3]);
      expect(eps.every((e) => e.seasonNumber == 1), isTrue);
      expect(eps.first.title, 'Good News About Hell');
      expect(eps.first.airDate, DateTime.parse('2022-02-18'));
    });
  });

  group('resolveByExternalId', () {
    test('matches an IMDb id to a tv result and stamps the imdbId', () async {
      final r = await _source().resolveByExternalId('tt11280740');

      expect(r, isNotNull);
      expect(r!.kind, MediaKind.tv);
      expect(r.tmdbId, 95396);
      expect(r.imdbId, 'tt11280740');
    });
  });

  group('upcomingForTracked', () {
    test("emits each show's next dated episode", () async {
      final upcoming = await _source().upcomingForTracked([95396]);

      expect(upcoming, hasLength(1));
      expect(upcoming.single.tmdbId, 95396);
      expect(upcoming.single.imdbId, 'tt11280740');
      expect(upcoming.single.airDate, DateTime.parse('2027-01-15'));
      expect(upcoming.single.episode.episodeNumber, 1);
    });
  });

  group('imageUrl', () {
    test('maps size buckets onto the TMDB image host', () {
      final s = _source();
      expect(
        s.imageUrl('/p.jpg', ImageSize.small),
        'https://image.tmdb.org/t/p/w185/p.jpg',
      );
      expect(
        s.imageUrl('/p.jpg', ImageSize.medium),
        'https://image.tmdb.org/t/p/w342/p.jpg',
      );
      expect(
        s.imageUrl('/p.jpg', ImageSize.large),
        'https://image.tmdb.org/t/p/w500/p.jpg',
      );
      expect(
        s.imageUrl('/p.jpg', ImageSize.original),
        'https://image.tmdb.org/t/p/original/p.jpg',
      );
    });
  });

  group('attribution', () {
    test('carries the mandatory TMDB notice and link', () {
      final a = _source().attribution();
      expect(a.notice, contains('TMDB'));
      expect(a.notice, contains('not endorsed'));
      expect(a.linkUrl, contains('themoviedb.org'));
    });
  });

  group('auth', () {
    test('v3 sends the api_key query param, no Authorization header', () async {
      http.Request? seen;
      final client = _fixtureClient(spy: (r) => seen = r);
      await _source(
        client: client,
        apiKey: 'v3-key',
      ).search('x', kind: MediaKind.tv);

      expect(seen!.url.queryParameters['api_key'], 'v3-key');
      expect(seen!.headers.containsKey('Authorization'), isFalse);
    });

    test('a v4 read token switches to Bearer auth, no api_key param', () async {
      http.Request? seen;
      final client = _fixtureClient(spy: (r) => seen = r);
      await _source(
        client: client,
        apiKey: '',
        readToken: 'v4-token',
      ).search('x', kind: MediaKind.tv);

      expect(seen!.headers['Authorization'], 'Bearer v4-token');
      expect(seen!.url.queryParameters.containsKey('api_key'), isFalse);
    });
  });

  group('errors (adversarial)', () {
    test(
      'a non-2xx response throws MetadataException with the status',
      () async {
        // Unknown id → the handler's 404 branch. The source must surface it
        // (not swallow) so the SWR wrapper (#13) can fall back to cache.
        expect(
          () => _source().movieDetails(999),
          throwsA(
            isA<MetadataException>().having(
              (e) => e.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
      },
    );
  });
}
