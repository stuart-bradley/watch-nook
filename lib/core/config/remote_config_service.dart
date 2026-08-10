import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_nook/core/config/remote_config.dart';

/// Where the hosted config JSON lives. May 404 until the human publishes it —
/// `refresh` degrades silently to the cached/baked-in value in that case.
// ponytail: const for now; becomes remote-config-driven only if the host moves.
const _configUrl =
    'https://stuart-bradley.github.io/watch-nook/remote_config.json';

const _prefsKey = 'remote_config';

/// Serves metadata config **without ever blocking boot** (ADR-2 + the
/// "remote config never blocks boot" invariant).
///
/// [current] is synchronous: cached-prefs JSON → baked-in default → empty. It
/// never touches the network, so first paint is instant and offline-safe.
/// [refresh] is a fire-and-forget network update whose whole body is guarded
/// `on Object` — it can never throw onto the startup path.
class RemoteConfigService {
  RemoteConfigService({
    required SharedPreferences prefs,
    http.Client? client,
    RemoteConfig? bakedDefaults,
  }) : _prefs = prefs,
       _client = client ?? http.Client(),
       _baked = bakedDefaults ?? _bakedFromEnvironment();

  final SharedPreferences _prefs;
  final http.Client _client;
  final RemoteConfig _baked;

  /// The config to use *right now*, synchronously. Prefers a previously-cached
  /// remote payload; falls back to the baked-in default if there's no cache
  /// (or the cache is corrupt). Never blocks, never hits the network.
  RemoteConfig current() {
    final cached = _prefs.getString(_prefsKey);
    if (cached != null) {
      try {
        return RemoteConfig.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
      } on Object {
        // Corrupt cache — fall through to the baked-in default.
      }
    }
    return _baked;
  }

  /// Fetches the hosted config and caches it for the *next* boot's [current].
  /// Fire-and-forget: the entire body is guarded so a network error, non-200,
  /// or malformed/wrong-typed JSON is swallowed (logged) and the existing cache
  /// is left untouched — never overwritten with garbage.
  Future<void> refresh() async {
    try {
      final res = await _client.get(Uri.parse(_configUrl));
      if (res.statusCode != 200) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      // Validate-by-parsing before writing: a wrong-typed field throws here
      // (TypeError) and is caught below, so cache stays on the good value.
      final config = RemoteConfig.fromJson(json);
      await _prefs.setString(_prefsKey, jsonEncode(config.toJson()));
    } on Object catch (e) {
      debugPrint(
        'wn-error: RemoteConfigService.refresh failed (using cached/baked): $e',
      );
    }
  }
}

// Flat string defines — the only shape that round-trips through
// --dart-define-from-file (a nested object arrives as Dart Map.toString(), not
// JSON, and silently resolves empty — issue #52). Keep secrets.json flat.
const _activeSourceDefine = String.fromEnvironment('activeSource');
const _tmdbApiKeyDefine = String.fromEnvironment('tmdbApiKey');
const _tmdbReadTokenDefine = String.fromEnvironment('tmdbReadToken');
const _tvdbApiKeyDefine = String.fromEnvironment('tvdbApiKey');

RemoteConfig _bakedFromEnvironment() => bakedDefaultsFromDefines(
  activeSource: _activeSourceDefine,
  tmdbApiKey: _tmdbApiKeyDefine,
  tmdbReadToken: _tmdbReadTokenDefine,
  tvdbApiKey: _tvdbApiKeyDefine,
);
