import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/tvdb/tvdb_source.dart';

String _fixture(String name) =>
    File('test/fixtures/metadata/tvdb/$name').readAsStringSync();

/// Routes a TVDB v4 request path to its committed fixture. Order matters:
/// `/search/remoteid/…` is checked before the bare `/search` endpoint. An
/// unmatched path returns a 404 in TVDB's error-body shape so the adversarial
/// test can assert on it.
http.Response _route(String path) {
  if (path.contains('/search/remoteid/')) {
    return http.Response(_fixture('search_remoteid.json'), 200);
  }
  if (path.endsWith('/search')) {
    return http.Response(_fixture('search_series.json'), 200);
  }
  if (path.endsWith('/series/371980/episodes/default')) {
    return http.Response(_fixture('series_episodes.json'), 200);
  }
  if (path.endsWith('/series/371980/extended')) {
    return http.Response(_fixture('series_extended.json'), 200);
  }
  if (path.endsWith('/movies/168899/extended')) {
    return http.Response(_fixture('movie_extended.json'), 200);
  }
  return http.Response(
    '{"status":"failure","message":"Not Found"}',
    404,
  );
}

/// Happy-path client: `POST /login` mints the mock token, every other request
/// is routed to a fixture. [spy] observes each request (auth headers, paths).
MockClient _okClient({void Function(http.Request)? spy}) =>
    MockClient((request) async {
      spy?.call(request);
      final path = request.url.path;
      if (request.method == 'POST' && path.endsWith('/login')) {
        return http.Response(_fixture('login.json'), 200);
      }
      return _route(path);
    });

TvdbSource _source({http.Client? client, Clock? clock}) => TvdbSource(
  client: client ?? _okClient(),
  apiKey: 'test-key',
  clock: clock ?? const Clock(),
);

void main() {
  group('search', () {
    test('normalizes ids, title, year and drops non-title rows', () async {
      final results = await _source().search('severance', kind: MediaKind.tv);

      // The fixture has a series + a person row; the person must be dropped.
      expect(results, hasLength(1));
      final r = results.single;
      expect(r.kind, MediaKind.tv);
      expect(r.tvdbId, 371980); // stringified id coerced to int
      expect(r.imdbId, 'tt11280740'); // from remote_ids
      expect(r.title, 'Severance');
      expect(r.year, 2022);
      expect(r.posterPath, startsWith('https://artworks.thetvdb.com'));
    });

    test('narrows the search type by kind', () async {
      http.Request? seen;
      await _source(
        client: _okClient(spy: (r) => seen = r),
      ).search('x', kind: MediaKind.movie);

      expect(seen!.url.queryParameters['type'], 'movie');
      expect(seen!.url.queryParameters['query'], 'x');
    });
  });

  group('showDetails', () {
    test('joins extended metadata with aired episodes', () async {
      final d = await _source().showDetails(371980);

      expect(d.kind, MediaKind.tv);
      expect(d.imdbId, 'tt11280740'); // from remoteIds
      expect(d.showStatus, 'Continuing');
      expect(d.runtimeMinutes, 50); // averageRuntime
      expect(d.genres, ['Drama', 'Mystery']);
      expect(d.episodeCountTotal, 4);
    });

    test('derives per-season counts from the episode list', () async {
      final d = await _source().showDetails(371980);

      expect(d.seasons.map((s) => s.seasonNumber), [1, 2]);
      expect(d.seasons.map((s) => s.episodeCount), [3, 1]);
    });

    test('resolves nextAired to a real next episode', () async {
      final d = await _source().showDetails(371980);

      expect(d.nextEpisode, isNotNull);
      expect(d.nextEpisode!.seasonNumber, 2);
      expect(d.nextEpisode!.episodeNumber, 1);
      expect(d.nextEpisode!.airDate, DateTime.parse('2027-01-15'));
    });
  });

  group('movieDetails', () {
    test('normalizes runtime, year, imdbId and leaves seasons empty', () async {
      final d = await _source().movieDetails(168899);

      expect(d.kind, MediaKind.movie);
      expect(d.title, 'Everything Everywhere All at Once');
      expect(d.imdbId, 'tt6710474');
      expect(d.runtimeMinutes, 139);
      expect(d.year, 2022);
      expect(d.seasons, isEmpty);
      expect(d.genres, contains('Science Fiction'));
    });
  });

  group('seasonEpisodes', () {
    test('returns one season in contiguous aired order (ADR-4)', () async {
      final eps = await _source().seasonEpisodes(371980, 1);

      expect(eps.map((e) => e.episodeNumber), [1, 2, 3]);
      expect(eps.every((e) => e.seasonNumber == 1), isTrue);
      expect(eps.first.title, 'Good News About Hell');
      expect(eps.first.airDate, DateTime.parse('2022-02-18'));
    });

    test('requests the aired season type, never dvd/absolute', () async {
      final paths = <String>[];
      await _source(
        client: _okClient(spy: (r) => paths.add(r.url.path)),
      ).seasonEpisodes(371980, 1);

      expect(paths, contains(endsWith('/episodes/default')));
      expect(
        paths.every((p) => !p.contains('/dvd') && !p.contains('/absolute')),
        isTrue,
      );
    });
  });

  group('resolveByExternalId', () {
    test('matches an IMDb id to a tv result and stamps ids', () async {
      final r = await _source().resolveByExternalId('tt11280740');

      expect(r, isNotNull);
      expect(r!.kind, MediaKind.tv);
      expect(r.tvdbId, 371980);
      expect(r.imdbId, 'tt11280740');
      expect(r.title, 'Severance');
    });
  });

  group('imageUrl', () {
    test('passes TVDB full URLs through and ignores the size', () {
      final s = _source();
      const url =
          'https://artworks.thetvdb.com/banners/v4/series/1/posters/x.jpg';
      expect(s.imageUrl(url, ImageSize.small), url);
      expect(s.imageUrl(url, ImageSize.original), url);
    });
  });

  group('attribution', () {
    test('carries the mandatory TheTVDB credit and link', () {
      final a = _source().attribution();
      expect(a.notice, contains('TheTVDB'));
      expect(a.linkUrl, contains('thetvdb.com'));
    });
  });

  group('auth', () {
    test('logs in with the api key and sends a Bearer token', () async {
      final requests = <http.Request>[];
      await _source(
        client: _okClient(spy: requests.add),
      ).search('x', kind: MediaKind.tv);

      final login = requests.firstWhere((r) => r.method == 'POST');
      expect(login.body, contains('test-key'));
      final search = requests.firstWhere((r) => r.method == 'GET');
      expect(search.headers['Authorization'], 'Bearer tvdb.mock.token.v4');
    });

    test('reuses the cached token across calls (one login)', () async {
      var logins = 0;
      final client = MockClient((req) async {
        if (req.method == 'POST' && req.url.path.endsWith('/login')) {
          logins++;
          return http.Response(_fixture('login.json'), 200);
        }
        return _route(req.url.path);
      });
      final source = _source(client: client);

      await source.movieDetails(168899);
      await source.movieDetails(168899);

      expect(logins, 1);
    });
  });

  group('token refresh (adversarial)', () {
    // Models a token that goes stale between calls: the server issues a token,
    // rejects it once with a 401, and the source must re-login and retry.
    MockClient staleTokenClient({
      required Set<int> rejectAtLogins,
      required void Function() onLogin,
    }) {
      var logins = 0;
      final rejected = <String>{};
      return MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'POST' && path.endsWith('/login')) {
          logins++;
          onLogin();
          final token = 'token-$logins';
          if (rejectAtLogins.contains(logins)) rejected.add(token);
          return http.Response(
            '{"status":"success","data":{"token":"$token"}}',
            200,
          );
        }
        final token = req.headers['Authorization']?.replaceFirst('Bearer ', '');
        if (token != null && rejected.remove(token)) {
          return http.Response('{"status":"failure","message":"expired"}', 401);
        }
        return _route(path);
      });
    }

    test('a 401 triggers exactly one re-login and retries', () async {
      var logins = 0;
      final client = staleTokenClient(
        rejectAtLogins: {1}, // the first-issued token is stale
        onLogin: () => logins++,
      );
      final d = await _source(client: client).showDetails(371980);

      expect(d.title, 'Severance');
      expect(logins, 2); // initial login + one refresh after the 401
    });

    test('a persistent 401 surfaces as MetadataException(401)', () async {
      final client = staleTokenClient(
        rejectAtLogins: {1, 2, 3}, // every token is rejected
        onLogin: () {},
      );
      await expectLater(
        _source(client: client).showDetails(371980),
        throwsA(
          isA<MetadataException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
    });
  });

  group('token TTL (Clock)', () {
    test('re-logins proactively once the token ages past its TTL', () async {
      var logins = 0;
      var now = DateTime.utc(2026);
      final client = MockClient((req) async {
        if (req.method == 'POST' && req.url.path.endsWith('/login')) {
          logins++;
          return http.Response(_fixture('login.json'), 200);
        }
        return _route(req.url.path);
      });
      final source = _source(client: client, clock: Clock(() => now));

      await source.movieDetails(168899); // login #1
      await source.movieDetails(168899); // token fresh — no new login
      expect(logins, 1);

      now = now.add(const Duration(days: 25)); // past the 24-day TTL
      await source.movieDetails(168899); // proactive re-login
      expect(logins, 2);
    });
  });

  group('errors (adversarial)', () {
    test('an unknown id surfaces MetadataException with the status', () async {
      // The source must surface a non-2xx (not swallow it) so the SWR wrapper
      // (#13) can fall back to cache.
      await expectLater(
        _source().movieDetails(999),
        throwsA(
          isA<MetadataException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });
}
