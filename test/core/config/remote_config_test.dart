import 'package:flutter_test/flutter_test.dart';
import 'package:watch_nook/core/config/remote_config.dart';

void main() {
  group('bakedDefaultsFromDefines', () {
    // Regression guard for #52: defines are FLAT strings. A nested object
    // passed to --dart-define-from-file arrives as Dart Map.toString() (not
    // JSON) and resolves EMPTY on-device — flat strings are the only shape
    // that survives the build. This suite pins the flat contract;
    // `just build-debug` + the emulator smoke are the real-artifact backstop
    // the old nested test lacked.
    test('reads flat string defines', () {
      final config = bakedDefaultsFromDefines(
        activeSource: 'tvdb',
        tmdbApiKey: 'v3key',
        tmdbReadToken: 'v4token',
        tvdbApiKey: 'tvdbkey',
      );

      expect(config.backend, MetadataBackend.tvdb);
      expect(config.tmdbApiKey, 'v3key');
      expect(config.tmdbReadToken, 'v4token');
      expect(config.tvdbApiKey, 'tvdbkey');
    });

    test('empty defines (CI ships none) resolve to safe empty defaults', () {
      final config = bakedDefaultsFromDefines(
        activeSource: '',
        tmdbApiKey: '',
        tmdbReadToken: '',
        tvdbApiKey: '',
      );

      expect(config.backend, MetadataBackend.tmdb); // safe default
      expect(config.tmdbApiKey, isEmpty);
      expect(config.tmdbReadToken, isEmpty);
      expect(config.tvdbApiKey, isEmpty);
    });

    // An unrecognised activeSource must not throw — it falls back to TMDB.
    test('unrecognised activeSource falls back to TMDB', () {
      final config = bakedDefaultsFromDefines(
        activeSource: 'bogus',
        tmdbApiKey: 'k',
        tmdbReadToken: '',
        tvdbApiKey: '',
      );

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
