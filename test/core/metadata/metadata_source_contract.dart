import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/tmdb/tmdb_source.dart';
import 'package:watch_nook/core/metadata/tvdb/tvdb_source.dart';

/// The provider-agnostic contract (#12, ADR-1). **One** suite, run against
/// **both** impls: every assertion is on the normalized `MetadataSource`
/// output (the interface type, never the concrete class), so a green run proves
/// TMDB and TVDB emit the *same shape* for the same title — nothing downstream
/// can tell which backend is active. Backend-specific mechanics (auth, TVDB
/// token refresh, TMDB v3/v4, season-type) live in the per-source tests; this
/// file asserts only the shared contract.
///
/// The two fixture sets are deliberately parallel — both resolve the show
/// "Severance" (imdb `tt11280740`) and the movie "Everything Everywhere All at
/// Once" (`tt6710474`) — so the expected values below are identical for both
/// cases. That identity *is* the contract.

String _tmdb(String name) =>
    File('test/fixtures/metadata/tmdb/$name').readAsStringSync();
String _tvdb(String name) =>
    File('test/fixtures/metadata/tvdb/$name').readAsStringSync();

/// Routes TMDB endpoints to committed fixtures; an unmatched path 404s so the
/// contract never accidentally passes on a stubbed-everything client.
MockClient _tmdbClient() => MockClient((request) async {
  final path = request.url.path;
  if (path.endsWith('/search/tv')) {
    return http.Response(_tmdb('search_tv.json'), 200);
  }
  if (path.contains('/tv/95396/season/')) {
    return http.Response(_tmdb('tv_season1.json'), 200);
  }
  if (path.endsWith('/tv/95396')) {
    return http.Response(_tmdb('tv_details.json'), 200);
  }
  if (path.endsWith('/movie/545611')) {
    return http.Response(_tmdb('movie_details.json'), 200);
  }
  if (path.contains('/find/')) {
    return http.Response(_tmdb('find_imdb.json'), 200);
  }
  return http.Response('{"success":false}', 404);
});

/// Routes TVDB v4 endpoints to committed fixtures; `POST /login` mints the mock
/// token. `/search/remoteid/` is matched before the bare `/search`.
MockClient _tvdbClient() => MockClient((request) async {
  final path = request.url.path;
  if (request.method == 'POST' && path.endsWith('/login')) {
    return http.Response(_tvdb('login.json'), 200);
  }
  if (path.contains('/search/remoteid/')) {
    return http.Response(_tvdb('search_remoteid.json'), 200);
  }
  if (path.endsWith('/search')) {
    return http.Response(_tvdb('search_series.json'), 200);
  }
  if (path.endsWith('/series/371980/episodes/default')) {
    return http.Response(_tvdb('series_episodes.json'), 200);
  }
  if (path.endsWith('/series/371980/extended')) {
    return http.Response(_tvdb('series_extended.json'), 200);
  }
  if (path.endsWith('/movies/168899/extended')) {
    return http.Response(_tvdb('movie_extended.json'), 200);
  }
  return http.Response('{"status":"failure"}', 404);
});

/// One backend under test. [build] takes the injected [Clock] (TVDB uses it for
/// token age; TMDB ignores it) and returns the impl **as the interface type**.
/// The differing bits — this source's own ids and how it forms image URLs —
/// ride on the case; the normalized expectations are hardcoded and shared.
class _Case {
  const _Case({
    required this.label,
    required this.build,
    required this.showId,
    required this.movieId,
    required this.imagePath,
    required this.imageUrlContains,
  });

  final String label;
  final MetadataSource Function(Clock clock) build;
  final int showId;
  final int movieId;
  final String imagePath;
  final String imageUrlContains;
}

final _cases = <_Case>[
  _Case(
    label: 'TmdbSource',
    build: (_) => TmdbSource(client: _tmdbClient(), apiKey: 'test-key'),
    showId: 95396,
    movieId: 545611,
    imagePath: '/poster.jpg',
    imageUrlContains: 'image.tmdb.org',
  ),
  _Case(
    label: 'TvdbSource',
    build: (clock) =>
        TvdbSource(client: _tvdbClient(), apiKey: 'test-key', clock: clock),
    showId: 371980,
    movieId: 168899,
    imagePath: 'https://artworks.thetvdb.com/banners/v4/x.jpg',
    imageUrlContains: 'thetvdb.com',
  ),
];

void main() {
  // Injected fixed Clock (#12) — keeps the TVDB token-age path deterministic
  // and proves the contract doesn't depend on wall-clock time.
  final clock = Clock.fixed(DateTime.utc(2026, 7, 8));

  for (final c in _cases) {
    group('MetadataSource contract · ${c.label}', () {
      late MetadataSource source;
      setUp(() => source = c.build(clock));

      test('search → results carry a provider id, title, and year', () async {
        final results = await source.search('severance', kind: MediaKind.tv);

        expect(results, isNotEmpty);
        final r = results.firstWhere((r) => r.title == 'Severance');
        expect(r.kind, MediaKind.tv);
        expect(
          r.tmdbId ?? r.tvdbId,
          isNotNull,
          reason: 'a backend-native id must be present',
        );
        expect(r.year, 2022);
      });

      test('showDetails → seasons populated, next episode present', () async {
        final d = await source.showDetails(c.showId);

        expect(d.kind, MediaKind.tv);
        expect(d.title, 'Severance');
        expect(d.imdbId, 'tt11280740');
        expect(d.seasons, isNotEmpty);
        expect(d.nextEpisode, isNotNull);
        expect(d.nextEpisode!.airDate, DateTime.parse('2027-01-15'));
      });

      test('movieDetails → runtime/year/imdb normalized, no seasons', () async {
        final d = await source.movieDetails(c.movieId);

        expect(d.kind, MediaKind.movie);
        expect(d.title, 'Everything Everywhere All at Once');
        expect(d.imdbId, 'tt6710474');
        expect(d.year, 2022);
        expect(d.runtimeMinutes, 139);
        expect(d.seasons, isEmpty);
      });

      test('seasonEpisodes → aired-ordered and contiguous (ADR-4)', () async {
        final eps = await source.seasonEpisodes(c.showId, 1);

        expect(eps.map((e) => e.episodeNumber), [1, 2, 3]);
        expect(eps.every((e) => e.seasonNumber == 1), isTrue);
        expect(eps.first.title, 'Good News About Hell');
        expect(eps.first.airDate, DateTime.parse('2022-02-18'));
      });

      test('resolveByExternalId(imdb) → matches the title back', () async {
        final r = await source.resolveByExternalId('tt11280740');

        expect(r, isNotNull);
        expect(r!.kind, MediaKind.tv);
        expect(r.imdbId, 'tt11280740');
        expect(r.title, 'Severance');
      });

      test('upcomingForTracked → the next dated episode', () async {
        final upcoming = await source.upcomingForTracked([c.showId]);

        expect(upcoming, hasLength(1));
        expect(upcoming.single.imdbId, 'tt11280740');
        expect(upcoming.single.airDate, DateTime.parse('2027-01-15'));
      });

      test('imageUrl(medium) → non-empty, provider-correct', () {
        final url = source.imageUrl(c.imagePath, ImageSize.medium);

        expect(url, isNotEmpty);
        expect(url, contains(c.imageUrlContains));
      });

      test('attribution().notice → non-empty', () {
        final a = source.attribution();

        expect(a.notice, isNotEmpty);
        expect(a.linkUrl, isNotEmpty);
      });
    });
  }
}
