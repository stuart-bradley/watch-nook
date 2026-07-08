// bin/api_smoke.dart — live metadata-backend probe (issue #8, gates M1).
//
// The GROUND-TRUTH probe run BEFORE TmdbSource (#10) / TvdbSource (#11)
// hard-code any endpoints: it hits TMDB and TheTVDB v4 *live* and prints the
// real HTTP shapes those sources will parse — auth, pagination, error bodies,
// TVDB login/token-refresh, and a per-IP-not-per-key rate-limit probe.
//
// Live-run is HUMAN-GATED: it needs real keys, which CI/the overnight loop
// don't ship (secrets.json is gitignored). Committed here it must only
// `flutter analyze` clean; a human runs it on a dev box and logs the
// rate-limit findings on the PR. See .autopilot/plan-m2.md · #8.
//
// Usage (pure-Dart script — imports no Flutter, so `dart run` works):
//
//   dart run bin/api_smoke.dart                 # TMDB, keys from secrets.json
//   dart run bin/api_smoke.dart --backend=tvdb
//   dart run bin/api_smoke.dart --backend=both
//   dart run bin/api_smoke.dart --title="The Wire"
//   dart run bin/api_smoke.dart --use-v4-token  # TMDB v4 Bearer, not v3 key
//   dart run bin/api_smoke.dart --rate-limit-calls=20
//
// Keys resolve from (highest first): --tmdb-key/--tmdb-token/--tvdb-key args,
// then the nested secrets.json (--secrets=<path>, default ./secrets.json —
// the same file `--dart-define-from-file` feeds the app, so no rebuild needed).
//
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _tmdbBase = 'https://api.themoviedb.org/3';
const _tvdbBase = 'https://api4.thetvdb.com/v4';

/// TheTVDB aired/broadcast season type. **INVARIANT (ADR-4):** episode
/// identity is pinned to AIRED order, so TvdbSource (#11) must request this
/// season type — never `absolute`, `dvd`, or `alternate`, which would scramble
/// watched flags. `default` is TVDB's aired/broadcast order.
const _tvdbAiredSeasonType = 'default';

typedef _Opts = ({
  String backend,
  String title,
  int rateLimitCalls,
  bool useV4Token,
});

typedef _Keys = ({String tmdbKey, String tmdbToken, String tvdbKey});

Future<void> main(List<String> args) async {
  final flags = _parseFlags(args);
  if (flags.containsKey('help') || flags.containsKey('h')) {
    print(_usage);
    return;
  }

  final opts = (
    backend: flags['backend'] ?? 'tmdb',
    title: flags['title'] ?? 'Breaking Bad',
    rateLimitCalls: int.tryParse(flags['rate-limit-calls'] ?? '') ?? 5,
    useV4Token: flags.containsKey('use-v4-token'),
  );
  final keys = _resolveKeys(flags['secrets'] ?? 'secrets.json', flags);

  final client = http.Client();
  try {
    if (opts.backend == 'tmdb' || opts.backend == 'both') {
      await _tmdbSmoke(client, keys, opts);
    }
    if (opts.backend == 'tvdb' || opts.backend == 'both') {
      await _tvdbSmoke(client, keys, opts);
    }
    if (opts.backend != 'tmdb' &&
        opts.backend != 'tvdb' &&
        opts.backend != 'both') {
      stderr.writeln('unknown --backend "${opts.backend}" (tmdb|tvdb|both)');
      exitCode = 2;
    }
  } finally {
    client.close();
  }
}

// --- TMDB ------------------------------------------------------------------

Future<void> _tmdbSmoke(http.Client client, _Keys keys, _Opts o) async {
  print('\n=== TMDB smoke (base $_tmdbBase) ===');
  final useV4 =
      o.useV4Token || (keys.tmdbKey.isEmpty && keys.tmdbToken.isNotEmpty);
  final missing = useV4 ? keys.tmdbToken.isEmpty : keys.tmdbKey.isEmpty;
  if (missing) {
    print(
      '  SKIP: no TMDB ${useV4 ? 'read token' : 'api key'} — set it in '
      'secrets.json or pass --tmdb-key/--tmdb-token.',
    );
    return;
  }
  print('  auth: ${useV4 ? 'v4 Bearer token' : 'v3 api_key query param'}');
  final headers = useV4 ? {'Authorization': 'Bearer ${keys.tmdbToken}'} : null;

  Uri tmdb(String path, [Map<String, String> query = const {}]) =>
      Uri.parse('$_tmdbBase$path').replace(
        queryParameters: {
          if (!useV4) 'api_key': keys.tmdbKey,
          ...query,
        },
      );

  // 1. Search + pagination shape.
  final searchRes = await _get(
    client,
    'search/tv page1',
    tmdb('/search/tv', {'query': o.title, 'page': '1'}),
    headers: headers,
  );
  final search = _decode(searchRes.body);
  final results = search['results'] as List<dynamic>? ?? const [];
  print(
    '      page ${search['page']}/${search['total_pages']}, '
    '${search['total_results']} total results',
  );
  if (results.isEmpty) {
    print('  no TMDB results for "${o.title}" — stopping (check the key?).');
    return;
  }
  final top = results.first as Map<String, dynamic>;
  final id = top['id'];
  print('      top hit: ${top['name']} (id $id)');

  // 2. Details in ONE call (append_to_response) — the #10 shape.
  final detailsRes = await _get(
    client,
    'tv/$id details',
    tmdb('/tv/$id', {
      'append_to_response': 'external_ids,next_episode_to_air',
    }),
    headers: headers,
  );
  final details = _decode(detailsRes.body);
  final ext = details['external_ids'] as Map<String, dynamic>?;
  final imdb = ext?['imdb_id'] as String?;
  print(
    '      imdb_id: $imdb  status: ${details['status']}  '
    'seasons: ${details['number_of_seasons']}',
  );
  print(
    '      last aired: '
    '${_tmdbEp(details['last_episode_to_air'] as Map<String, dynamic>?)}',
  );
  print(
    '      next air:   '
    '${_tmdbEp(details['next_episode_to_air'] as Map<String, dynamic>?)}',
  );

  // 3. Season 1 episodes — TMDB is aired-order native (ADR-4).
  final seasonRes = await _get(
    client,
    'tv/$id season 1',
    tmdb('/tv/$id/season/1'),
    headers: headers,
  );
  final eps = _decode(seasonRes.body)['episodes'] as List<dynamic>? ?? const [];
  print('      season 1: ${eps.length} episodes (aired order)');

  // 4. resolveByExternalId shape — /find/{imdb}.
  if (imdb != null && imdb.isNotEmpty) {
    final findRes = await _get(
      client,
      'find $imdb',
      tmdb('/find/$imdb', {'external_source': 'imdb_id'}),
      headers: headers,
    );
    final find = _decode(findRes.body);
    final tv = find['tv_results'] as List<dynamic>? ?? const [];
    print('      /find matched ${tv.length} tv result(s)');
  }

  // 5. Error shape — bad id → 404 {status_code,status_message}.
  final errRes = await _get(
    client,
    'tv/0 (bad id)',
    tmdb('/tv/0'),
    headers: headers,
  );
  print('      error body: ${_truncate(errRes.body)}');

  // 6. Rate-limit probe (per-IP, not per-key — see ADR / issue #8).
  await _rateLimitProbe(
    client,
    o.rateLimitCalls,
    () => tmdb('/configuration'),
    headers,
  );
}

String _tmdbEp(Map<String, dynamic>? ep) => ep == null
    ? '(none)'
    : 'S${ep['season_number']}E${ep['episode_number']} '
          '"${ep['name']}" @ ${ep['air_date']}';

// --- TheTVDB ---------------------------------------------------------------

Future<void> _tvdbSmoke(http.Client client, _Keys keys, _Opts o) async {
  print('\n=== TheTVDB smoke (base $_tvdbBase) ===');
  if (keys.tvdbKey.isEmpty) {
    print(
      '  SKIP: no TVDB api key — set tvdb.apiKey in secrets.json or pass '
      '--tvdb-key.',
    );
    return;
  }

  // 1. Login → bearer token (the exchange TvdbSource #11 caches in memory).
  final token = await _tvdbLogin(client, keys.tvdbKey);
  if (token == null) {
    print('  login failed — stopping TVDB probe.');
    return;
  }
  print('  logged in (token length ${token.length}).');
  Map<String, String> auth(String t) => {'Authorization': 'Bearer $t'};

  // 2. Token-refresh probe: a bad token must 401 — that's the trigger #11's
  //    source re-logins on (401 → re-login once → retry).
  final badRes = await client.get(
    Uri.parse('$_tvdbBase/user'),
    headers: auth('deliberately-invalid-token'),
  );
  print(
    '  refresh probe: bad token ⇒ ${badRes.statusCode} '
    '(expect 401 ⇒ source should re-login & retry)',
  );

  // 3. Search series.
  final searchRes = await _get(
    client,
    'search',
    Uri.parse('$_tvdbBase/search').replace(
      queryParameters: {'query': o.title, 'type': 'series'},
    ),
    headers: auth(token),
  );
  final results = _decode(searchRes.body)['data'] as List<dynamic>? ?? const [];
  if (results.isEmpty) {
    print('  no TVDB results for "${o.title}" — stopping.');
    return;
  }
  final top = results.first as Map<String, dynamic>;
  final seriesId = top['tvdb_id'] ?? top['id'];
  print('      top hit: ${top['name']} (id $seriesId)');

  // 4. Series extended → remoteIds (IMDb join key) + nextAired.
  final extRes = await _get(
    client,
    'series/$seriesId/extended',
    Uri.parse('$_tvdbBase/series/$seriesId/extended'),
    headers: auth(token),
  );
  final data = _decode(extRes.body)['data'] as Map<String, dynamic>?;
  final remoteIds = data?['remoteIds'] as List<dynamic>? ?? const [];
  print(
    '      imdb: ${_tvdbImdb(remoteIds)}  '
    'nextAired: ${data?['nextAired']}',
  );

  // 5. Episodes in AIRED order (ADR-4 INVARIANT: never absolute/dvd).
  final epsRes = await _get(
    client,
    'series/$seriesId/episodes/$_tvdbAiredSeasonType',
    Uri.parse('$_tvdbBase/series/$seriesId/episodes/$_tvdbAiredSeasonType'),
    headers: auth(token),
  );
  final epsBody = _decode(epsRes.body);
  final epsData = epsBody['data'] as Map<String, dynamic>?;
  final eps = epsData?['episodes'] as List<dynamic>? ?? const [];
  print('      ${eps.length} episodes (aired "$_tvdbAiredSeasonType" order)');
  if (eps.isNotEmpty) {
    final e = eps.first as Map<String, dynamic>;
    print(
      '      first: S${e['seasonNumber']}E${e['number']} '
      '"${e['name']}" @ ${e['aired']}',
    );
  }
  final links = epsBody['links'] as Map<String, dynamic>?;
  print(
    '      pagination: next=${links?['next']} '
    'total=${links?['total_items']}',
  );

  // 6. Error shape — bad series id.
  final errRes = await client.get(
    Uri.parse('$_tvdbBase/series/0/extended'),
    headers: auth(token),
  );
  print(
    '  error shape: series/0 ⇒ ${errRes.statusCode} '
    '${_truncate(errRes.body)}',
  );

  // 7. Rate-limit probe.
  await _rateLimitProbe(
    client,
    o.rateLimitCalls,
    () => Uri.parse('$_tvdbBase/series/$seriesId'),
    auth(token),
  );
}

Future<String?> _tvdbLogin(http.Client client, String apiKey) async {
  final res = await client.post(
    Uri.parse('$_tvdbBase/login'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'apikey': apiKey}),
  );
  _report('login', res);
  if (res.statusCode != 200) {
    print('      body: ${_truncate(res.body)}');
    return null;
  }
  final data = _decode(res.body)['data'] as Map<String, dynamic>?;
  return data?['token'] as String?;
}

String _tvdbImdb(List<dynamic> remoteIds) {
  for (final raw in remoteIds) {
    final id = (raw as Map<String, dynamic>)['id'] as String? ?? '';
    if (id.startsWith('tt')) return id;
  }
  return '(none)';
}

// --- shared helpers --------------------------------------------------------

Future<http.Response> _get(
  http.Client client,
  String label,
  Uri url, {
  Map<String, String>? headers,
}) async {
  final res = await client.get(url, headers: headers);
  _report(label, res);
  return res;
}

void _report(String label, http.Response res) {
  print('  [$label] ${res.statusCode} ${res.reasonPhrase ?? ''}'.trimRight());
  _printRateHeaders(res);
}

void _printRateHeaders(http.Response res) {
  const keys = [
    'x-ratelimit-limit',
    'x-ratelimit-remaining',
    'x-ratelimit-reset',
    'retry-after',
  ];
  for (final k in keys) {
    final v = res.headers[k];
    if (v != null) print('      $k: $v');
  }
}

/// Loops [calls] back-to-back GETs with the SAME key. Identical remaining/OK
/// counts across many calls ⇒ TMDB/TVDB limit per source IP, not per key — the
/// premise that lets the app ship one embedded key (see issue #8 / metadata
/// ADR). Logs each status + the rate headers; stops early on the first 429.
Future<void> _rateLimitProbe(
  http.Client client,
  int calls,
  Uri Function() url,
  Map<String, String>? headers,
) async {
  print(
    '  rate-limit probe: $calls back-to-back calls on a shared key '
    '(expect per-IP limiting, not per-key)',
  );
  for (var i = 1; i <= calls; i++) {
    final res = await client.get(url(), headers: headers);
    final signal =
        res.headers['x-ratelimit-remaining'] ??
        res.headers['retry-after'] ??
        '—';
    print('      call $i: ${res.statusCode} (remaining/retry-after: $signal)');
    if (res.statusCode == 429) {
      print(
        '      429 hit after $i calls; retry-after: '
        '${res.headers['retry-after']}',
      );
      return;
    }
  }
}

Map<String, dynamic> _decode(String body) {
  try {
    return jsonDecode(body) as Map<String, dynamic>;
  } on Object {
    return const {};
  }
}

String _truncate(String s, [int max = 200]) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

Map<String, String> _parseFlags(List<String> args) {
  final flags = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    final body = arg.substring(2);
    final eq = body.indexOf('=');
    if (eq == -1) {
      flags[body] = 'true';
    } else {
      flags[body.substring(0, eq)] = body.substring(eq + 1);
    }
  }
  return flags;
}

/// Resolves keys: CLI args win, else the nested [path] secrets.json (same
/// shape #6 bakes in via `--dart-define-from-file`). Missing/malformed file
/// degrades to empty strings — the per-backend SKIP branches handle that.
_Keys _resolveKeys(String path, Map<String, String> flags) {
  var tmdbKey = flags['tmdb-key'] ?? '';
  var tmdbToken = flags['tmdb-token'] ?? '';
  var tvdbKey = flags['tvdb-key'] ?? '';
  if (tmdbKey.isNotEmpty && tmdbToken.isNotEmpty && tvdbKey.isNotEmpty) {
    return (tmdbKey: tmdbKey, tmdbToken: tmdbToken, tvdbKey: tvdbKey);
  }
  final file = File(path);
  if (file.existsSync()) {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final tmdb = json['tmdb'] as Map<String, dynamic>? ?? const {};
      final tvdb = json['tvdb'] as Map<String, dynamic>? ?? const {};
      if (tmdbKey.isEmpty) tmdbKey = (tmdb['apiKey'] as String?) ?? '';
      if (tmdbToken.isEmpty) {
        tmdbToken = (tmdb['apiReadAccessToken'] as String?) ?? '';
      }
      if (tvdbKey.isEmpty) tvdbKey = (tvdb['apiKey'] as String?) ?? '';
    } on Object catch (e) {
      stderr.writeln('warning: could not read keys from $path: $e');
    }
  }
  return (tmdbKey: tmdbKey, tmdbToken: tmdbToken, tvdbKey: tvdbKey);
}

const _usage = '''
api_smoke.dart — live TMDB / TheTVDB probe (issue #8, gates M1).

  dart run bin/api_smoke.dart [--backend=tmdb|tvdb|both] [options]

Options:
  --backend=tmdb|tvdb|both   which backend(s) to probe (default: tmdb)
  --title="Show Name"        title to look up (default: Breaking Bad)
  --use-v4-token             TMDB: auth with the v4 Bearer token, not the v3 key
  --rate-limit-calls=N       calls in the rate-limit probe loop (default: 5)
  --secrets=path             secrets.json path (default: ./secrets.json)
  --tmdb-key / --tmdb-token / --tvdb-key   override individual keys
  -h, --help                 show this help

Keys are read from CLI args first, else the nested secrets.json. secrets.json
is gitignored; CI ships none, so live-running this is a human step.''';
