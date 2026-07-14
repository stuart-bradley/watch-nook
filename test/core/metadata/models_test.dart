import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// A fully-populated episode (every optional field set) so round-trips exercise
/// nested serialization and the `airDate` ISO string path.
final _episode = EpisodeInfo(
  seasonNumber: 2,
  episodeNumber: 5,
  title: 'The One With The Cache',
  airDate: DateTime.parse('2026-07-08T00:00:00.000'),
  overview: 'A stale-while-revalidate romp.',
  runtimeMinutes: 42,
);

void main() {
  // Round-trips compare the JSON maps (not object identity — the models have no
  // ==): fromJson(toJson()) must re-serialize to the same map. flutter_test's
  // default matcher deep-compares Maps/Lists, so nested models are covered.
  group('JSON round-trip', () {
    test('MediaSearchResult — carries both TMDB and TVDB ids', () {
      // Backend-neutrality (acceptance): one result can hold tmdbId AND tvdbId
      // AND imdbId at once, so the app is provider-agnostic.
      const original = MediaSearchResult(
        kind: MediaKind.tv,
        title: 'Severance',
        tmdbId: 95396,
        tvdbId: 371980,
        imdbId: 'tt11280740',
        year: 2022,
        posterPath: '/poster.jpg',
        overview: 'Work-life balance, taken literally.',
      );

      expect(
        MediaSearchResult.fromJson(original.toJson()).toJson(),
        original.toJson(),
      );
    });

    test('EpisodeInfo — full and sparse (null airDate)', () {
      expect(
        EpisodeInfo.fromJson(_episode.toJson()).toJson(),
        _episode.toJson(),
      );

      const sparse = EpisodeInfo(seasonNumber: 1, episodeNumber: 1);
      final restored = EpisodeInfo.fromJson(sparse.toJson());
      expect(restored.airDate, isNull);
      expect(restored.toJson(), sparse.toJson());
    });

    test('SeasonInfo', () {
      const original = SeasonInfo(
        seasonNumber: 2,
        episodeCount: 10,
        name: 'Season 2',
      );
      expect(
        SeasonInfo.fromJson(original.toJson()).toJson(),
        original.toJson(),
      );
    });

    test('MediaDetails — with seasons + nextEpisode', () {
      final original = MediaDetails(
        kind: MediaKind.tv,
        title: 'Severance',
        genres: const ['Drama', 'Sci-Fi'],
        seasons: const [
          SeasonInfo(seasonNumber: 1, episodeCount: 9, name: 'Season 1'),
          SeasonInfo(seasonNumber: 2, episodeCount: 10),
        ],
        tmdbId: 95396,
        tvdbId: 371980,
        imdbId: 'tt11280740',
        year: 2022,
        posterPath: '/poster.jpg',
        overview: 'Work-life balance, taken literally.',
        backdropPath: '/backdrop.jpg',
        runtimeMinutes: 50,
        showStatus: 'Returning Series',
        episodeCountTotal: 19,
        nextEpisode: _episode,
      );

      expect(
        MediaDetails.fromJson(original.toJson()).toJson(),
        original.toJson(),
      );
    });

    test('MediaDetails — movie-shaped (empty seasons, no nextEpisode)', () {
      const original = MediaDetails(
        kind: MediaKind.movie,
        title: 'Arrival',
        genres: ['Sci-Fi'],
        seasons: [],
        tmdbId: 329865,
        imdbId: 'tt2543164',
        year: 2016,
        runtimeMinutes: 116,
      );

      final restored = MediaDetails.fromJson(original.toJson());
      expect(restored.seasons, isEmpty);
      expect(restored.nextEpisode, isNull);
      expect(restored.toJson(), original.toJson());
    });

    test('Attribution', () {
      const original = Attribution(
        notice: 'Uses the TMDB API but not endorsed or certified by TMDB.',
        linkUrl: 'https://www.themoviedb.org/',
        logoAsset: 'assets/tmdb_logo.png',
      );
      expect(
        Attribution.fromJson(original.toJson()).toJson(),
        original.toJson(),
      );
    });
  });

  // Adversarial: a malformed cache payload must be *rejected*, not silently
  // coerced. `as`-casts raise TypeError and enum parsing raises ArgumentError —
  // both `Error`s (not `Exception`s), so downstream `on Object` guards catch
  // them. Each case is a distinct way a payload can be wrong.
  group('fromJson rejects malformed payloads', () {
    test('wrong-typed scalar (seasonNumber is a String) throws TypeError', () {
      expect(
        () => SeasonInfo.fromJson(const {
          'seasonNumber': 'two',
          'episodeCount': 10,
        }),
        throwsA(isA<TypeError>()),
      );
    });

    test('null required field (episodeNumber) throws TypeError', () {
      expect(
        () => EpisodeInfo.fromJson(const {
          'seasonNumber': 1,
          'episodeNumber': null,
        }),
        throwsA(isA<TypeError>()),
      );
    });

    test('unknown enum name (kind) throws ArgumentError', () {
      expect(
        () => MediaSearchResult.fromJson(const {
          'kind': 'podcast',
          'title': 'x',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('wrong-typed list (genres is a Map) throws TypeError', () {
      expect(
        () => MediaDetails.fromJson(const {
          'kind': 'tv',
          'title': 'x',
          'genres': <String, dynamic>{},
          'seasons': <dynamic>[],
        }),
        throwsA(isA<TypeError>()),
      );
    });
  });
}
