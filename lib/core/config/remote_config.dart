import 'package:flutter/foundation.dart';

/// Which metadata backend the app talks to (ADR-1). The M0 config only
/// *selects* the enum; M1 (#9–#11) adds a separate
/// `activeMetadataSourceProvider` that maps it to a `MetadataSource` instance.
enum MetadataBackend {
  tmdb,
  tvdb;

  /// Maps a persisted/config name back to the enum, defaulting to [tmdb] for an
  /// absent or unrecognised value (safe default — TMDB is the primary source).
  static MetadataBackend fromName(String? name) => MetadataBackend.values
      .firstWhere((b) => b.name == name, orElse: () => MetadataBackend.tmdb);
}

/// Immutable metadata configuration (ADR-2). Carries **both** the TMDB v3 query
/// key (`tmdbApiKey`) and the v4 Bearer token (`tmdbReadToken`) so M1 can pick
/// which it calls with, plus TheTVDB's login key — no M1 model reshape needed.
@immutable
class RemoteConfig {
  const RemoteConfig({
    required this.backend,
    required this.tmdbApiKey,
    required this.tmdbReadToken,
    required this.tvdbApiKey,
    this.minVersion,
  });

  /// Strict parse of the hosted/cached config JSON (flat shape — see [toJson]).
  ///
  /// Deliberately throws (not falls back) on a wrong-typed field: `as`-cast
  /// failures raise `TypeError` (an `Error`, not an `Exception`) — a CLAUDE.md
  /// Dart gotcha. Callers (`current()`/`refresh()`) guard with `on Object` and
  /// keep the previous value, so a malformed payload never overwrites good
  /// cache. The baked-in defaults path ([bakedDefaultsFromDefines]) can't fail
  /// this way — it reads flat string defines that are simply empty when absent.
  factory RemoteConfig.fromJson(Map<String, dynamic> json) => RemoteConfig(
    backend: MetadataBackend.fromName(json['backend'] as String),
    tmdbApiKey: json['tmdbApiKey'] as String,
    tmdbReadToken: json['tmdbReadToken'] as String,
    tvdbApiKey: json['tvdbApiKey'] as String,
    minVersion: json['minVersion'] as int?,
  );

  /// Empty config — the offline/no-secrets fallback (CI ships empty defines).
  static const empty = RemoteConfig(
    backend: MetadataBackend.tmdb,
    tmdbApiKey: '',
    tmdbReadToken: '',
    tvdbApiKey: '',
  );

  final MetadataBackend backend;

  /// TMDB v3 API key (query-param auth).
  final String tmdbApiKey;

  /// TMDB v4 read access token (Bearer auth).
  final String tmdbReadToken;

  /// TheTVDB v4 login/API key.
  final String tvdbApiKey;

  /// Optional minimum supported app version (force-update hook for later).
  final int? minVersion;

  Map<String, dynamic> toJson() => {
    'backend': backend.name,
    'tmdbApiKey': tmdbApiKey,
    'tmdbReadToken': tmdbReadToken,
    'tvdbApiKey': tvdbApiKey,
    'minVersion': minVersion,
  };
}

/// Builds the baked-in fallback [RemoteConfig] from the
/// `--dart-define-from-file=secrets.json` values.
///
/// The defines are **flat top-level strings** (`tmdbApiKey`,
/// `tmdbReadToken`, `tvdbApiKey`) — the only shape that round-trips
/// through `--dart-define-from-file`. A **nested** object does NOT arrive
/// as its JSON string: Flutter serialises it with Dart's `Map.toString()`
/// (unquoted → invalid JSON), so it silently resolves empty and the app
/// ships with no key (issue #52). Keep `secrets.json` flat; never re-nest.
///
/// Absent defines (CI ships none) resolve to '' → the app runs on
/// [RemoteConfig.empty]'s safe defaults. Note: TMDB embeds fine (public by
/// design — per-IP rate limiting), but TheTVDB is attributed per-key/contract,
/// so decide its delivery model before baking a real `tvdbApiKey` in.
RemoteConfig bakedDefaultsFromDefines({
  required String activeSource,
  required String tmdbApiKey,
  required String tmdbReadToken,
  required String tvdbApiKey,
}) => RemoteConfig(
  backend: MetadataBackend.fromName(activeSource),
  tmdbApiKey: tmdbApiKey,
  tmdbReadToken: tmdbReadToken,
  tvdbApiKey: tvdbApiKey,
);
