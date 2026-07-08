# GitHub Issues — Watchnook

Each milestone = a GitHub Milestone; issues are worked **lowest-number-first** on `auto/m<N>` branches with `Closes #N` in the PR. Issue numbers below match the GitHub issues (created in order). `needs-human` issues are skipped by autopilot and must be done by a person. Acceptance criteria also live in each GitHub issue body — that's the contract the implementer works to.

---

## Milestone M0 — Scaffold & foundation

### #1 — Scaffold watch_nook Flutter project · `chore`
Clone the `well-quill` skeleton; `applicationId com.stuartbradley.watchnook`; Java 17 + desugaring; `key.properties` signing with debug fallback; strip boilerplate.
- **Tests:** `flutter analyze` clean; app boots to a blank home screen.
- **Acceptance:** `just check` passes locally.

### #2 — CI/CD via ci-shared@v1 + justfile · `chore`
Thin caller workflows `.github/workflows/{ci,e2e,release}.yml` on `stuart-bradley/ci-shared@v1`; `justfile` with `check`, `codegen`, `build-debug`, `e2e`, `release-ci`. Default branch `main`.
- **Tests:** CI `check` job runs on a PR.
- **Acceptance:** green `check` on a PR.

### #3 — Drift DB + Riverpod provider + migration scaffold · `feat`
`AppDatabase`, `database_provider` (`@Riverpod(keepAlive:true)`), `schemaVersion=1`, `beforeOpen` foreign_keys ON, in-memory test harness (`AppDatabase.forTesting`).
- **Tests:** DAO round-trip on `NativeDatabase.memory()`; migration test.
- **Acceptance:** DB opens; migration test passes.

### #4 — go_router + onboarding redirect + Material 3 theme · `feat`
Router provider with first-run onboarding redirect; Material 3 `ThemeData` builder (light+dark) + optional `DynamicColorBuilder`. **Theme is delivered** — lift `docs/design/flutter/lib/core/theme/{watchnook_theme,watchnook_tokens}.dart` (Honey · gold) into `lib/core/theme/`; add `google_fonts`; swap `withOpacity`→`withValues`.
- **Tests:** redirect logic unit test.
- **Acceptance:** onboarding → home navigates; theme applied.

### #5 — RemoteConfigService (non-blocking) + backend toggle scaffold · `feat`
Fetch `{ backend, tmdbKey, tvdbKey, minVersion? }`; cached/baked-in fallback; fire-and-forget update wrapped `try { } on Object { }`; `activeMetadataSourceProvider`.
- **Tests:** returns baked-in key offline; does not block first paint.
- **Acceptance:** config loads without network on boot.

### #6 — [needs-human] Provide TMDB + TheTVDB API keys & config · `chore` `needs-human`
Obtain a TMDB key (instant) and apply for the TheTVDB v4 free key; put both in the RemoteConfig JSON + baked-in default. See `docs/MANUAL_SETUP.md`.
- **Acceptance:** `bin/api_smoke.dart` (M1) can authenticate at least TMDB.

### #7 — [needs-human] Drop real service exports into `test/fixtures/` · `chore` `needs-human`
Pull **TV Time (before 2026-07-15)**, IMDb, Letterboxd, Trakt exports into `test/fixtures/` (see its README). Blocks M3 parser TDD.
- **Acceptance:** fixtures present for all four sources (+ one malformed sample each).

---

## Milestone M1 — Metadata layer (both backends)  *(needs M0)*

### #8 — bin/api_smoke.dart (gates M1) · `chore`
Standalone script hitting TMDB + TheTVDB live: auth, pagination, error shapes, TVDB token refresh; **probe per-IP-not-per-key rate limiting**.
- **Tests:** prints live episode + next-air for a known title per backend.
- **Acceptance:** both backends return data; rate-limit findings logged. *(needs #6 keys)*

### #9 — MetadataSource interface + normalized models · `feat`
`search/movieDetails/showDetails/seasonEpisodes/upcomingForTracked/resolveByExternalId/imageUrl/attribution`; normalized models covering both providers.
- **Tests:** model (de)serialization.
- **Acceptance:** interface + models compile; cover TMDB+TVDB fields.

### #10 — TmdbSource · `feat`
Inline `next_episode_to_air` + `append_to_response`; size-bucket image URLs; attribution (logo + notice).
- **Tests:** MockClient fixtures.
- **Acceptance:** passes the contract suite (#12).

### #11 — TvdbSource · `feat`
Login/token cache + 401-refresh; **aired/official season type**; separate calls; full-URL images; TheTVDB attribution link.
- **Tests:** MockClient incl. token-refresh.
- **Acceptance:** passes the contract suite (#12).

### #12 — Contract test suite (both sources) · `test`
One suite both impls satisfy (normalized output shape).
- **Acceptance:** green for TMDB + TVDB.

### #13 — Cache tables + TTL + SWR + cached_network_image · `feat`
`CachedMedia`/`CachedEpisodes` + DAO; stale-while-revalidate; TTL tiers; raised image cache cap.
- **Tests:** TTL; 429/500 → cache fallback; airplane render.
- **Acceptance:** offline detail renders from cache.

### #14 — Backend-switch re-resolution service · `feat`
Relink shows by `imdbId` + air-date reconciliation; set `relinkFailed` on anomalies.
- **Tests:** switch remaps episodes; anomaly flagged.
- **Acceptance:** toggling backend preserves watched state.

---

## Milestone M2 — Core tracking  *(needs M1)*

### #15 — LibraryItems table + DAO (denormalized progress) · `feat`
- **Tests:** `watchedCount`/`lastWatched*` stay correct on writes.
- **Acceptance:** grid query needs no cross-domain join.

### #16 — Search & add flow · `feat`
Results → add with status picker.
- **Tests:** add→library widget test.
- **Acceptance:** added item appears in library.

### #17 — Library grid (filter status/type, offline) · `feat`
- **Tests:** filter tests; renders from denormalized fields offline.
- **Acceptance:** "S2E4 · 3 left" shows offline.

### #18 — Title detail (metadata + seasons/episodes + attribution) · `feat`
- **Tests:** attribution present per source.
- **Acceptance:** seasons/episodes list renders.

### #19 — Watched state: mark/unwatch (idempotent) + rewatch log · `feat`
- **Tests:** double-tap idempotency; unwatch removes rewatches.
- **Acceptance:** semantics per the CLAUDE.md invariant.

### #20 — Bulk mark (season/show/up-to-episode) · `feat`
Fetch season if uncached; specials (season 0) excluded by default.
- **Tests:** bulk from partial cache.
- **Acceptance:** one action marks a whole season.

### #21 — Upcoming/calendar (tracked only) · `feat`
Tracked shows' episodes this week + tracked movie releases.
- **Tests:** only tracked items appear.
- **Acceptance:** this-week view populated.

### #22 — Widget tests (bulk, filters, idempotency) · `test`
- **Acceptance:** green.

---

## Milestone M3 — Import  *(needs M1, M2; fixtures from #7)*

### #23 — Import core: ImportArchive / ImportRecord / Resolver / MergeApplier · `feat`
Multi-file archive support; id-match + fuzzy(title,year) with threshold; additive upsert by id-block.
- **Tests:** re-import merges, does NOT wipe history.
- **Acceptance:** clean-ID auto; ambiguous → confirmation queue.

### #24 — TV Time importer · `feat`
Unzip ~80 CSVs; TV = tvdbId (clean), movies = UUID → title+year fuzzy.
- **Tests:** real export fixture + malformed input (`as`-cast TypeError guard).
- **Acceptance:** sample TV Time imports.

### #25 — Trakt importer · `feat`
JSON, full id block, episode-level.
- **Tests:** fixture.
- **Acceptance:** clean-ID import.

### #26 — IMDb importer · `feat`
CSV `tt` id → TMDB find.
- **Tests:** fixture.
- **Acceptance:** ratings/watchlist import.

### #27 — Letterboxd importer · `feat`
CSV (no ids) → title+year fuzzy / URI resolve.
- **Tests:** fixture.
- **Acceptance:** diary/ratings import via confirmation.

### #28 — Import UI: pick / progress / fuzzy confirmation · `feat`
- **Tests:** widget test for the confirmation flow.
- **Acceptance:** ambiguous matches are confirmable.

### #29 — Patrol E2E: import → mark → export → reimport · `test`
- **Acceptance:** end-to-end flow green.

---

## Milestone M4 — Export & backup  *(needs M2, M3)*

### #30 — ImportExportService (JSON canonical, user-tables-only) · `feat`
Versioned; reads only user Drift rows (never prefs).
- **Tests:** round-trip export → wipe → import identical.
- **Acceptance:** portable JSON produced.

### #31 — Letterboxd CSV export (movies) · `feat`
Name/Year/Rating/Rewatch/WatchedDate + tmdbID/imdbID columns.
- **Tests:** CSV shape.
- **Acceptance:** re-importable to Letterboxd.

### #32 — AutoBackupService + manifest allowlist · `feat`
JSON snapshot on pause; restore on fresh install keyed on empty `LibraryItems`; allowlist backup/extraction rules; atomic temp→rename write.
- **Tests:** fresh-install restore; atomic write.
- **Acceptance:** reinstall restores the library.

### #33 — Export-excludes-cache regression test · `test`
- **Acceptance:** export never contains cache tables (or, later, entitlement keys).

---

## Milestone M5 — Stats, polish & release  *(needs M2, M4)*

### #34 — Stats screen · `feat`
Counts, hours (snapshotted runtimes), by genre/decade, streak.
- **Tests:** stats correct after a cache clear.
- **Acceptance:** figures survive cache eviction.

### #35 — Onboarding + empty states + settings · `feat`
Settings: export/backup, theme, about + attribution.
- **Tests:** widget tests.
- **Acceptance:** first-run + empty states polished.

### #36 — Apply Claude-designed theme / design system · `feat`
**Design output delivered** at `docs/design/flutter/` (the `needs-human` blocker is resolved). Port `theme/`, `tokens`, `poster_placeholder` into `lib/core/`; the `features/*` screens are `setState` mockups — reimplement with Riverpod + go_router + real data (reference only). Swap `withOpacity`→`withValues`. See `docs/DESIGN_BRIEF.md` → "Delivered".
- **Acceptance:** design applied.

### #37 — ASO listing (`docs/ASO_LISTING.md`) · `docs` `needs-human`
Via the aso-listing skill.
- **Acceptance:** listing drafted.

### #38 — Release pipeline dry-run to Play internal · `chore` `needs-human`
Keystore + `PLAY_STORE_JSON_KEY` + device.
- **Acceptance:** internal-track build uploaded.

---

## M6 — Deferred backlog (no issues created; run stops after M5)
Simkl importer · optional Simkl sync (PKCE, no secret shipped) · monetization port (licensing-gated) · "where to watch" (needs a proxy).
