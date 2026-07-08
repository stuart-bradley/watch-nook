import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/config/remote_config.dart';

void main() {
  group('bakedDefaultsFromDefines', () {
    // Regression guard for the #6 contract: the committed secrets.json is
    // NESTED, and --dart-define-from-file delivers each nested object as its
    // JSON-STRING. A flat String.fromEnvironment would silently resolve empty.
    test('parses the nested secrets.json JSON-string defines', () {
      final config = bakedDefaultsFromDefines(
        activeSource: 'tvdb',
        tmdbJson: '{"apiKey":"v3key","apiReadAccessToken":"v4token"}',
        tvdbJson: '{"apiKey":"tvdbkey"}',
      );

      expect(config.backend, MetadataBackend.tvdb);
      expect(config.tmdbApiKey, 'v3key');
      expect(config.tmdbReadToken, 'v4token');
      expect(config.tvdbApiKey, 'tvdbkey');
    });

    test(
      'degrades to empty defaults when defines are absent (CI ships none)',
      () {
        final config = bakedDefaultsFromDefines(
          activeSource: '',
          tmdbJson: '',
          tvdbJson: '',
        );

        expect(config.backend, MetadataBackend.tmdb); // safe default
        expect(config.tmdbApiKey, isEmpty);
        expect(config.tmdbReadToken, isEmpty);
        expect(config.tvdbApiKey, isEmpty);
      },
    );

    // Adversarial: a malformed define must not blow up boot.
    test('degrades to empty on malformed JSON rather than throwing', () {
      final config = bakedDefaultsFromDefines(
        activeSource: 'tmdb',
        tmdbJson: '{not valid json',
        tvdbJson: '{}',
      );

      expect(config.tmdbApiKey, isEmpty);
      expect(config.tvdbApiKey, isEmpty);
      expect(config.backend, MetadataBackend.tmdb);
    });
  });

  group('RemoteConfig JSON', () {
    test('round-trips through toJson/fromJson', () {
      const original = RemoteConfig(
        backend: MetadataBackend.tvdb,
        tmdbApiKey: 'a',
        tmdbReadToken: 'b',
        tvdbApiKey: 'c',
        minVersion: 7,
      );

      final restored = RemoteConfig.fromJson(original.toJson());

      expect(restored.backend, MetadataBackend.tvdb);
      expect(restored.tmdbApiKey, 'a');
      expect(restored.tmdbReadToken, 'b');
      expect(restored.tvdbApiKey, 'c');
      expect(restored.minVersion, 7);
    });

    // A wrong-typed field raises TypeError (an Error, not an Exception) — the
    // caller's `on Object` guard is what keeps a bad payload out of the cache.
    test('fromJson throws on a wrong-typed field', () {
      expect(
        () => RemoteConfig.fromJson(const {'backend': 123}),
        throwsA(isA<TypeError>()),
      );
    });
  });
}
