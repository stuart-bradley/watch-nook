# Milestone M1 — Metadata layer (both backends) · plan

> Autopilot branch `auto/m2` · GitHub milestone **M1** · issues **#8–#14**.
> (The autopilot milestone counter is off-by-one from the doc labels: internal
> milestone `2` == docs' **M1**. `auto/m1` is M0.)

## ⚠️ Branch base decision (read first)

M1 is **`needs M0`** (PRD milestones). M0 lives entirely in **PR #42
(`auto/m1`), which is OPEN, not merged**. `origin/main` currently has **no
Flutter project** — no `pubspec.yaml`, no `lib/`, no Drift DB, no
`RemoteConfigService`. Every M1 issue builds directly on those.

Autopilot **never merges**, so #42 can't be landed here to unblock. Basing
`auto/m2` on `origin/main` would mean writing the metadata layer against an
empty repo (`just check` would fail immediately — no pubspec).

**Decision:** `auto/m2` is stacked on **`origin/auto/m1`** (standard stacked-PR
flow). In the morning the human merges **#42 first**, then this PR. Until #42
lands, this PR's diff against `main` includes M0's commits (#1–#5); once #42
merges (merge-commit or rebase), the diff reduces to just M1. This is the only
way overnight M1 progress is possible without merging. Flagged for triage.

## High-level requirements

Delivers **R1 (provider-agnostic metadata)** and **R10 (offline-first)** from
the PRD, plus the caching + backend-switch machinery M2 will consume.

- One `MetadataSource` interface, two impls (`TmdbSource`, `TvdbSource`),
  selected at runtime — flipping `backend` in config swaps source, no code
  change (ADR-1). *US-14.*
- Normalized models cover **both** providers' fields so the rest of the app is
  provider-agnostic.
- Stale-while-revalidate cache: detail/library render instantly & offline,
  refetch-if-stale in the background; 429/500 → cache fallback (ADR-7). *US-13.*
- Backend switch relinks by `imdbId` + air-date reconciliation, never
  scrambling watched flags; anomalies flagged `relinkFailed` (ADR-4).

## Architecture decisions (from PRD; how M1 realizes them)

- **ADR-1** — `MetadataSource` interface; `activeMetadataSourceProvider` maps
  `activeMetadataBackend` (already in M0) → the concrete impl.
- **ADR-4** — aired-order episode identity; `imdbId` universal join key.
- **ADR-7** — SWR + TTL-by-volatility; `cached_network_image` for posters.
- **Never call an HTTP client from UI/features** — always through
  `MetadataSource` (CLAUDE.md).

## Shared normalized models (introduced in #9, consumed by all)

Plain immutable classes in `lib/core/metadata/models/`, each with
`fromJson`/`toJson` (round-tripped through the cache `payload`). They are
**backend-neutral** — the source impls do provider-specific parsing and emit
these:

- `MediaSearchResult` — `kind {movie,tv}`, `tmdbId?`, `tvdbId?`, `imdbId?`,
  `title`, `year?`, `posterPath?`, `overview?`.
- `MediaDetails` — search fields **+** `backdropPath?`, `genres` (List),
  `runtimeMinutes?`, `showStatus?`, `episodeCountTotal?`, `nextEpisode?`
  (`EpisodeInfo`), `seasons` (List<`SeasonInfo`>).
- `SeasonInfo` — `seasonNumber`, `episodeCount`, `name?`.
- `EpisodeInfo` — `seasonNumber`, `episodeNumber` (**aired order**), `title?`,
  `airDate?`, `overview?`, `runtimeMinutes?`.
- `UpcomingEpisode` — the item's ids + `EpisodeInfo` + `airDate`.
- `Attribution` — `logoAsset?`, `notice`, `linkUrl` (per-source; **mandatory**
  display on detail — M2 consumes).
- `MediaKind` enum {movie, tv} (distinct from DB `MediaType`; adapter maps).

`MetadataSource` interface methods (per #9):
`search`, `movieDetails`, `showDetails`, `seasonEpisodes`,
`upcomingForTracked`, `resolveByExternalId(imdbId)`, `imageUrl(path,size)`,
`attribution()`. `imageUrl` abstracts TMDB size-buckets vs TVDB full URLs.

Design ref for attribution copy/logos: `docs/design/flutter/.../title_detail_screen.dart`.

---

## Build order & per-issue plan

Reconcile picks lowest-numbered open unblocked issue, so natural order is
**8 → 9 → 10 → 11 → 12 → 13 → 14**. Each issue = one `work` turn = one
`(#N)` commit. Tests land **in the same commit** as the code they cover (TDD).

### #8 — `bin/api_smoke.dart` (gates M1) · chore

Standalone script (`dart run bin/api_smoke.dart --backend=tmdb|tvdb`) hitting
TMDB + TheTVDB **live**: auth (v3 key vs v4 token for TMDB; login-token
exchange for TVDB), pagination, error shapes, TVDB token refresh; prints a
known title's live episode + next-air; **probes per-IP-not-per-key** rate
limiting (loops N calls, logs headers/status).

- **Uses the real HTTP shapes** the M1 sources will depend on — it's the
  ground-truth probe *before* `TmdbSource`/`TvdbSource` hardcode endpoints.
- **Tests:** none (it *is* the manual probe); must `flutter analyze` clean.
- **⚠️ Live-run is human-gated.** The script needs **real keys** (#6 secrets),
  which the overnight loop / CI don't have (secrets ship empty). Deliverable
  here = the committed, anal-clean script + usage dartdoc; **actually running
  it live + logging rate-limit findings is a `needs-human` step** (real keys on
  a dev box). Flag in PR triage. Keys read from `--dart-define-from-file` or
  `--tmdb-key`/`--tvdb-key` args so a human can run without rebuilding.

### #9 — `MetadataSource` interface + normalized models · feat

The interface + models above, in `lib/core/metadata/`. No HTTP yet.

- **Tests (`test/core/metadata/models_test.dart`):** model (de)serialization
  round-trip for every model; **adversarial** — a null/wrong-typed field in a
  payload map raises the expected error (CLAUDE.md `as`-cast `TypeError`
  gotcha), so cache-payload parsing is guarded downstream.
- **Acceptance:** interface + models compile; fields cover TMDB **and** TVDB.

### #10 — `TmdbSource` · feat

`lib/core/metadata/tmdb/tmdb_source.dart`. Base `https://api.themoviedb.org/3`.
- Auth: v3 `api_key` query param (config `tmdbApiKey`), or v4 Bearer
  (`tmdbReadToken`) — pick per #8 findings; default v3.
- `showDetails` inlines `append_to_response=external_ids,next_episode_to_air`;
  `movieDetails` `append_to_response=external_ids`. Genres inline.
- `resolveByExternalId`: `/find/{imdb}?external_source=imdb_id`.
- `imageUrl`: `https://image.tmdb.org/t/p/{size}{path}` (buckets
  w185/w342/w500/original; map a size enum).
- `attribution`: TMDB logo asset + "uses the TMDB API but not endorsed/certified
  by TMDB" notice.
- **Tests:** MockClient (`package:http/testing.dart`) with TMDB fixture JSON in
  `test/fixtures/metadata/tmdb/`. Injected `http.Client`. Passes contract suite
  (#12).

### #11 — `TvdbSource` · feat

`lib/core/metadata/tvdb/tvdb_source.dart`. Base `https://api4.thetvdb.com/v4`.
- **Login/token cache + 401-refresh:** POST `/login {apikey}` → bearer token,
  cached in-memory; on 401 re-login once & retry. Inject `Clock` (token
  age/expiry).
- **Aired/official season type** (INVARIANT, ADR-4): request
  `/series/{id}/episodes/default` (aired order) — pinned in a named const +
  code comment; contract test asserts aired ordering. Never absolute/dvd.
- **Separate calls** (no `append_to_response`): series extended → episodes →
  (translations if needed). `remoteIds` on extended carries IMDb.
- `imageUrl`: TVDB returns **full URLs** → pass-through (size arg ignored).
- `attribution`: TheTVDB link/logo.
- **Tests:** MockClient incl. a **token-refresh** case (first call 401 → login →
  retry succeeds). TVDB fixtures in `test/fixtures/metadata/tvdb/`.

### #12 — Contract test suite (both sources) · test

`test/core/metadata/metadata_source_contract.dart` — one parameterized suite
run against **both** impls (each backed by its own MockClient + fixtures).
Asserts the **normalized output shape** is identical regardless of backend:
- `search` → results carry ids + title + year.
- `showDetails` → `nextEpisode` present when the fixture has one; seasons
  populated.
- `seasonEpisodes` → **aired-ordered**, contiguous.
- `resolveByExternalId(imdb)` → returns the matching result.
- `imageUrl(path, w342)` → non-empty, provider-correct.
- `attribution().notice` → non-empty.
- Inject `Clock`.
- **Acceptance:** green for TMDB **and** TVDB (#10, #11 verified against it).

### #13 — Cache tables + TTL + SWR + `cached_network_image` · feat

- **Schema → v2.** Add `CachedMedia`, `CachedEpisodes` to `tables.dart`
  (**cache domain** — disposable, NEVER exported/backed-up; INVARIANT). Bump
  `AppDatabase.schemaVersion` → 2 + add `onUpgrade` step creating the two
  tables. `MediaCacheDao`.
  - `CachedMedia`: PK (`source`,`mediaType`,`sourceId`); `imdbId?`, `payload`
    (raw JSON), `fetchedAt`; promoted `title,year?,posterPath?,backdropPath?,
    overview?,showStatus?,nextAirDate?,runtimeMinutes?,genresCsv?`.
  - `CachedEpisodes`: PK (`source`,`showSourceId`,`seasonNumber`,
    `episodeNumber`); `title?,airDate?,overview?,runtimeMinutes?,fetchedAt`;
    idx (`source`,`showSourceId`).
- **SWR wrapper** (`CachingMetadataRepository`, `lib/core/metadata/cache/`):
  wraps the active `MetadataSource`. Reads: return cache instantly; if stale
  (TTL by volatility — **ended ~30d, airing 6–24h, images 60d**, ADR-7) OR
  missing, background-refetch and upsert (Drift `.watch()` repaints). On
  **429/500 → return cache** (never throw to UI). Inject `Clock` for TTL.
- **`cached_network_image` dep** + raised image cache cap (custom cache manager,
  60d / larger `maxNrOfCacheObjects`).
- **Tests:** TTL staleness math (fresh vs stale boundary via injected Clock);
  429 & 500 → cache-fallback (MockClient returns error, repo yields cached);
  offline/"airplane" render — widget reads cache with network stubbed to throw.
  **Adversarial:** stale + network-error must still yield stale cache, not empty.
- **Acceptance:** offline detail renders from cache.

### #14 — Backend-switch re-resolution service · feat

`lib/core/metadata/switch/backend_switch_service.dart`. On `backend` change,
for each `LibraryItem`:
1. Relink via `newSource.resolveByExternalId(imdbId)` (universal join key). No
   `imdbId` → can't relink → `relinkFailed = true`, leave ids/watched intact.
2. Update `tmdbId`/`tvdbId` + `recordedSource` to the new backend.
3. **Reconcile episodes by air-date:** map existing `WatchEvents` aired
   `(season,episode)` to the new source's episodes by matching `airDate`. Clean
   1:1 → keep watched rows as-is. Anomaly (absolute-numbered/anime, specials,
   ambiguous/mismatched counts) → `relinkFailed = true`, **never silently
   scramble watched flags** (INVARIANT).
- **Tests:** happy-path switch remaps a show's ids + keeps watched
  `(season,episode)` stable when air-dates line up; **adversarial** — mismatch
  (no imdbId / episode-count divergence / specials) sets `relinkFailed` and
  leaves `WatchEvents` untouched. In-memory DB + fake `MetadataSource`.
- **Acceptance:** toggling backend preserves watched state.

---

## Testing strategy (TDD, alongside every issue)

- **Unit:** models (#9), each source via MockClient + fixtures (#10/#11),
  contract suite both impls (#12), TTL/SWR/fallback (#13), re-resolution
  happy + anomaly (#14). Inject `Clock` (already a dep) everywhere time matters;
  inject `http.Client` everywhere network matters.
- **Adversarial, not confirmatory:** malformed/wrong-typed payloads (TypeError
  guard), 429/500 fallback, token-refresh, backend-switch anomalies, aired-order
  pinning. Each derives from "what does a regression look like?".
- **Fixtures:** real-shaped TMDB/TVDB JSON under `test/fixtures/metadata/{tmdb,tvdb}/`.
- **Invariant coverage:** aired-order (contract), cache-domain disposability
  (asserted structurally here; the export-exclusion regression test lands with
  export in M4 — noted, not silently skipped).
- **Gate:** `just check` (codegen → analyze → format-check → test) green per
  commit; `dart run build_runner build` after touching Drift tables/providers.
- **Real-artifact (human/local):** `bin/api_smoke.dart` live probe (#8) + an
  emulator smoke of offline cache render (#13) need real keys / a device —
  `needs-human`, flagged in triage (loop/CI can't reach network+keys).

## New dependencies

- `cached_network_image` (#13). Everything else (`http`, `drift`, `clock`,
  `riverpod`) is already in the M0 pubspec.

## Unresolved questions

1. TMDB auth: v3 `api_key` or v4 Bearer as default? (#8 probe decides; plan
   defaults v3.)
2. TVDB aired season type: `default` vs `official` endpoint — which is true
   aired order for anime/absolute shows? (#8/#11 to confirm against a known
   title; plan defaults `default`.)
3. #8 live-run + #13 device smoke need real keys — accept as `needs-human`, or
   is a dev-box key available to the loop?
4. Stack-on-`auto/m1` vs park-until-#42-merges — confirm the stacked-PR approach
   is acceptable (chosen here to keep overnight progress).
