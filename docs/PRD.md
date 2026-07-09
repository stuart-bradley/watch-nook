# Watchnook — Product Requirements & Technical Context

## Context

TV Time shuts down **2026-07-15**, stranding people who track TV/movies. The best-looking replacement (Refract) is account-backed and its backend melted under the TV Time exodus; every Play-Store competitor (Refract, Serializd, Moviebase, Telly) is backend-dependent and fell over at the same time. **Watchnook** is a local-first, backend-free tracker positioned on reliability + privacy: no accounts, no social, works offline, first-class import from the services people are fleeing.

Feasibility (researched, primary sources): a shared, app-embedded metadata key is viable because **TMDB rate-limits per-IP, not per-key** — one key serves all installs without a proxy. TMDB's free tier is **non-commercial**; **TheTVDB v4** is free even commercially **under $50k/yr** (attribution only, no per-user PINs) but is approval-gated. So the app is **provider-agnostic** and can flip backend via config. Only social (dropped) and "where to watch" streaming data (no free/keyless source — deferred) would require a server.

Primary user: the developer, for himself. **No revenue is fine — and monetization is not a realistic goal here** (corrected 2026-07-09; the earlier "pay-once becomes possible with no recurring cost" was wrong — it priced the *licence* but ignored key *distribution*). The app ships **free on TMDB**, whose dev key permits free non-commercial use. Monetizing is licensing-gated and impractical for a minimal-revenue app: the TMDB dev key forbids **any** revenue — donations included (see ADR-8) — so it needs a TMDB commercial licence or TheTVDB; and TheTVDB's key is attributed **per-key/contract, not per-IP**, so it can't be safely embedded in a distributed client without a proxy (recurring cost). Treat Watchnook as a **free tool, not a product**.

## Product overview

Track existing + upcoming movies/TV; mark watched/unwatched (bulk); view metadata from the source; watch statistics. Import from TV Time, IMDb, Letterboxd, Trakt. Export portable JSON + Letterboxd CSV. Android Auto Backup + manual export/import. Built on the existing local-first Flutter portfolio conventions (clone the `well-quill` skeleton).

## Architecture decisions

- **ADR-1 — Provider-agnostic metadata.** One `MetadataSource` interface; impls `TmdbSource` (default) + `TvdbSource`. Selected at runtime via `activeMetadataSourceProvider` from `RemoteConfigService`. TheTVDB v4 requires a login token exchange (cached + 401-refresh) and makes separate calls where TMDB uses `append_to_response`/inline next-episode. A contract test suite both impls must pass enforces normalized output. `imageUrl(path,size)` abstracts TMDB size-buckets vs TVDB full URLs.
- **ADR-2 — Remote, updatable config.** Fetch a tiny unauthenticated JSON `{ backend, tmdbKey, tvdbKey, minVersion? }` (GitHub Pages/raw), cached to prefs, baked-in fallback. **Never `await` on boot.** Rotating a key or flipping the backend = edit the JSON, no release.
- **ADR-3 — Two data domains, one Drift DB.** User-owned tables (exported + backed-up) vs disposable cache tables (excluded). `ExportData` serializes only user tables. Library items carry denormalized display + progress fields so the grid renders offline with no per-card cross-domain join.
- **ADR-4 — Cross-backend identity + aired-order episodes.** Store `tmdbId/tvdbId/imdbId` + `recordedSource`; **IMDb id = universal join key**. Canonical numbering = **aired order**. Backend switch relinks by imdbId + air-date reconciliation, flags `relinkFailed` on anomalies.
- **ADR-5 — Import pipeline.** `Importer` (`ImportArchive` → `List<ImportRecord>`; supports multi-file zips) → `Resolver` (id-match auto; else title+year search → confident single hit auto, ambiguous → confirmation queue) → **`MergeApplier`** (additive upsert by id-block; distinct from restore's replace path).
- **ADR-6 — Export = backup format.** The JSON `AutoBackupService` writes on pause **is** the manual-export format (versioned, user-tables-only) + a Letterboxd-convention CSV for movies. Restore = replace path; import = MergeApplier.
- **ADR-7 — Caching / SWR.** Return cache instantly; background-refetch if stale; TTL by volatility (ended ~30d, airing 6–24h, images 60d). Refresh only tracked shows on app-resume; skip dropped/ended-completed. `cached_network_image` for posters.
- **ADR-8 — Monetization deferred + licensing-coupled (likely never).** v1 free, no IAP, **no donations**. The TMDB API terms count **any** revenue — donations included — as commercial use, which the free dev key forbids. Monetizing at all needs a TMDB commercial licence or TheTVDB. TheTVDB's key is attributed **per-key/contract (not per-IP like TMDB)**, so a shipped client key is a liability the only real fix for is a proxy (recurring cost) — it doesn't pencil out at minimal revenue. If ever revisited: TMDB commercial (key stays embedded, per-IP-safe), **not** TheTVDB. Attribution obligations (logo + exact notice) apply **even to the free build** — see the attribution invariant.

## Data model (Drift)

**User-owned (exported + backed up):**
- `LibraryItems`: `id` PK; `mediaType` enum{movie,tv}; `tmdbId?`,`tvdbId?`,`imdbId?`; `recordedSource` enum{tmdb,tvdb}; `title`,`year?`,`posterPath?`; `genresCsv?`,`runtimeMinutes?` (snapshot for stats); `trackStatus` enum{watchlist,watching,completed,onHold,dropped}; `showStatus?`; `episodeCountTotal?`,`watchedCount` (default 0),`lastWatchedSeason?`,`lastWatchedEpisode?`; `rating?` (0–10),`ratedAt?`; `addedAt`,`updatedAt`; `relinkFailed` (default false). Unique idx (mediaType,tmdbId),(mediaType,tvdbId),imdbId; idx trackStatus.
- `WatchEvents`: `id` PK; `libraryItemId` FK; `seasonNumber?`,`episodeNumber?` (both null = movie; **aired order**); `watchedAt?` (null = watched, date unknown); `runtimeMinutes?` (snapshot); `isRewatch` (default false). Idx (libraryItemId,seasonNumber,episodeNumber); idx watchedAt.

**Cache (disposable — NOT exported/backed up):**
- `CachedMedia`: PK (source,mediaType,sourceId); `imdbId?`,`payload` (raw JSON),`fetchedAt`; promoted `title,year,posterPath,backdropPath,overview,showStatus,nextAirDate?,runtimeMinutes?,genresCsv?`.
- `CachedEpisodes`: (source,showSourceId,seasonNumber,episodeNumber); `title,airDate?,overview,runtimeMinutes?,fetchedAt`. Idx (source,showSourceId).

See the **Invariants** in `.claude/CLAUDE.md` for the load-bearing rules (watched idempotency, aired-order, import-vs-restore, stats snapshotting, non-blocking config).

## Requirements, user stories & acceptance

- **R1 — Provider-agnostic metadata.** *US-14: As the dev, I rotate the key / switch backend with no app release.* **Tests:** contract suite both impls pass; TVDB token-refresh; offline returns baked-in key. **Acceptance:** flipping `backend` in config swaps source with no code change.
- **R2 — Track catalog.** *US-1: As a viewer, I search and add a title with a status.* **Tests:** add→library widget test. **Acceptance:** added item appears with chosen status.
- **R3 — Watched state + bulk + rewatch.** *US-2 one-tap watched; US-3 bulk mark season/show; US-4 log a rewatch keeping the first date.* **Tests:** double-tap idempotency, unwatch removes rewatches, bulk from partial cache. **Acceptance:** semantics per invariant; one action marks a season.
- **R4 — Upcoming (tracked only).** *US-5: As a viewer, I see this week's episodes for my shows.* **Tests:** only tracked items appear. **Acceptance:** this-week view populated from next-episode data.
- **R5 — Metadata display + attribution.** *US-6: As a viewer, I open a title and see full metadata.* **Tests:** attribution present per source. **Acceptance:** seasons/episodes/overview render; attribution shown.
- **R6 — Import.** *US-7 TV Time; US-8 IMDb/Letterboxd/Trakt; US-9 confirm ambiguous matches.* **Tests:** parser tests vs real fixtures + malformed inputs; re-import merges (no wipe). **Acceptance:** sample exports import; clean-ID auto, ambiguous confirmable.
- **R7 — Export.** *US-10: As a privacy-minded user, I export all my data portably.* **Tests:** round-trip export→wipe→import identical; CSV shape. **Acceptance:** JSON + Letterboxd CSV produced; re-importable.
- **R8 — Backup.** *US-11: As a user who reinstalls, my library restores automatically.* **Tests:** fresh-install restore keyed on empty `LibraryItems`; atomic write. **Acceptance:** reinstall restores library.
- **R9 — Stats.** *US-12: As a data nerd, I see episodes/hours/genre/decade.* **Tests:** stats correct after a cache clear (snapshotted facts). **Acceptance:** figures survive cache eviction.
- **R10 — Offline-first.** *US-13: As a user offline, I browse + mark; it persists.* **Tests:** airplane render from cache; 429/500→cache fallback. **Acceptance:** library/detail work offline; marking persists.

## Milestones

- **M0 — Scaffold & foundation:** project, CI/justfile, Drift+Riverpod, go_router+theme, non-blocking RemoteConfig.
- **M1 — Metadata layer (both backends):** api_smoke gate, MetadataSource + TMDB + TVDB, cache+TTL, contract tests, backend-switch re-resolution.
- **M2 — Core tracking:** library, search/add, detail, watched semantics, bulk, upcoming (tracked only).
- **M3 — Import:** pipeline + TV Time/IMDb/Letterboxd/Trakt + confirmation UI + Patrol E2E.
- **M4 — Export & backup:** JSON export + Letterboxd CSV + AutoBackup + exclusion regression test.
- **M5 — Stats, polish & release:** stats, onboarding/settings, apply design, ASO listing, release dry-run.
- **M6 — Deferred backlog (no issues):** Simkl importer; optional Simkl sync (PKCE); monetization (licensing-gated); "where to watch" (needs a proxy).

## Verification strategy

- `just check` (codegen → analyze → format-check → test) + `just e2e` (Patrol) green.
- `dart run bin/api_smoke.dart --backend=tmdb|tvdb` returns live data + logs rate-limit behaviour before any UI depends on the client.
- Manual: import a real TV Time export → library populates (TV by tvdbId, movies via fuzzy confirmation) → bulk-mark → export JSON + CSV → wipe → reimport identical → reimport again NOT duplicated. Toggle backend → re-resolution relinks. Airplane mode renders from cache. Fresh-install restore.

## Notes

- Name `Watchnook` — confirm free in Play Console before first upload (search showed zero collisions). `applicationId com.stuartbradley.watchnook` — never change once published.
- TheTVDB free-key approval may flip the default backend TMDB→TheTVDB (config change, no code).
