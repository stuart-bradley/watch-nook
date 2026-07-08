import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/config/remote_config.dart';
import 'package:watch_nook/core/config/remote_config_service.dart';

void main() {
  const baked = RemoteConfig(
    backend: MetadataBackend.tmdb,
    tmdbApiKey: 'baked-v3',
    tmdbReadToken: 'baked-v4',
    tvdbApiKey: 'baked-tvdb',
  );

  Future<SharedPreferences> emptyPrefs() {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  RemoteConfigService serviceWith(
    SharedPreferences prefs,
    MockClientHandler handler,
  ) => RemoteConfigService(
    prefs: prefs,
    bakedDefaults: baked,
    client: MockClient(handler),
  );

  group('current()', () {
    test('returns the baked-in default when nothing is cached', () async {
      final prefs = await emptyPrefs();
      final service = serviceWith(prefs, (_) async => http.Response('', 500));

      expect(service.current().tmdbApiKey, 'baked-v3');
      expect(service.current().backend, MetadataBackend.tmdb);
    });

    test('does not touch the network (synchronous, non-blocking)', () async {
      final prefs = await emptyPrefs();
      var hitNetwork = false;
      final service = serviceWith(prefs, (_) async {
        hitNetwork = true;
        return http.Response('', 200);
      });

      // Read WITHOUT awaiting refresh() — returns immediately from defaults.
      expect(service.current().tvdbApiKey, 'baked-tvdb');
      expect(hitNetwork, isFalse);
    });
  });

  group('refresh()', () {
    // The `on Object` guard: a thrown request must not propagate off the
    // fire-and-forget path, and current() stays on the baked default.
    test(
      'swallows a network failure and leaves current() on the baked default',
      () async {
        final prefs = await emptyPrefs();
        final service = serviceWith(
          prefs,
          (_) async => throw Exception('offline'),
        );

        await service.refresh(); // must not rethrow

        expect(service.current().tmdbApiKey, 'baked-v3');
      },
    );

    test('ignores a non-200 response, cache untouched', () async {
      final prefs = await emptyPrefs();
      final service = serviceWith(prefs, (_) async => http.Response('{}', 404));

      await service.refresh();

      expect(service.current().tmdbApiKey, 'baked-v3');
    });

    // Structurally-valid-but-malformed: key present, wrong type. `as String`
    // raises TypeError (an Error) — proves the guard is `on Object`, not
    // `on Exception` — and the good cache is never overwritten.
    test(
      'swallows wrong-typed remote JSON without corrupting the cache',
      () async {
        final prefs = await emptyPrefs();
        final service = serviceWith(
          prefs,
          (_) async => http.Response('{"backend": 123}', 200),
        );

        await service.refresh();

        expect(service.current().tmdbApiKey, 'baked-v3');
      },
    );

    test(
      'caches valid remote JSON so the next current() reflects it',
      () async {
        final prefs = await emptyPrefs();
        final remote = jsonEncode(
          const RemoteConfig(
            backend: MetadataBackend.tvdb,
            tmdbApiKey: 'remote-v3',
            tmdbReadToken: 'remote-v4',
            tvdbApiKey: 'remote-tvdb',
            minVersion: 5,
          ).toJson(),
        );
        final service = serviceWith(
          prefs,
          (_) async => http.Response(remote, 200),
        );

        await service.refresh();

        final config = service.current();
        expect(config.backend, MetadataBackend.tvdb);
        expect(config.tmdbApiKey, 'remote-v3');
        expect(config.minVersion, 5);
      },
    );
  });
}
