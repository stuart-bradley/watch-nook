# Milestone M2 — Core tracking · implementation plan

GitHub milestone **#3** ("M2 — Core tracking"), branch **`auto/m3`**. Covers every
open issue: **#15–#22**. Advisory autopilot plan — a human merges.

## 0. Branch base (deviation — read first)

`origin/main` has **zero Dart source**: every foundational layer (M0 scaffold +
Flutter project + Drift DB + go_router + theme, and M1 metadata sources + SWR
cache + backend-switch) lives **unmerged on `origin/auto/m2`**. The autopilot
`start` recipe says branch from `origin/main`, but doing so would give `auto/m3`
no `pubspec.yaml`, no DB, no `MetadataSource` — nothing would compile and CI
would be red by construction, blocking every `work` step.

**Decision:** `auto/m3` is branched from **`origin/auto/m2`** so M2 builds on its
foundation. This mirrors how `auto/m2` itself stacked M0+M1. The PR diff vs
`main` therefore includes M0+M1 (already in the `auto/m2` PR); when a human
merges the stack in order (m1→m2→m3) the diff collapses to just M2.

## 1. What already exists (do NOT rebuild)

- **DB (schema v2, `lib/core/database/`)** — `LibraryItems` + `WatchEvents`
  (user domain) and `CachedMedia` + `CachedEpisodes` (disposable cache) are
  **fully defined**, including every denormalized field M2 needs
  (`watchedCount`, `lastWatchedSeason/Episode`, `genresCsv`, `runtimeMinutes`,
  `episodeCountTotal`, `showStatus`, `relinkFailed`). **M2 adds NO tables and NO
  columns — `schemaVersion` stays 2, no new migration.**
- **`LibraryDao`** — thin: `insertItem`, `getAll`, `watchAll`, `updateItem`,
  `watchEventsFor`. M2 extends it (reads/writes below).
- **`MediaCacheDao`** — full cache access incl. `getEpisodes` /
  `replaceSeasonEpisodes`.
- **Metadata (`lib/core/metadata/`)** — `MetadataSource` interface, `TmdbSource`,
  `TvdbSource`, `CachingMetadataRepository` (SWR, cache-first streams),
  `BackendSwitchService`, normalized models (`MediaSearchResult`,
  `MediaDetails`, `EpisodeInfo`, `SeasonInfo`, `UpcomingEpisode`, `Attribution`).
- **Providers** — `appDatabaseProvider`, `libraryDaoProvider`,
  `mediaCacheDaoProvider`, `remoteConfigServiceProvider`,
  `activeMetadataBackendProvider`, `appRouterProvider`.
- **Shell** — `main.dart`, Honey Material 3 dark theme + tokens
  (`WatchnookSpacing/Radii/Tokens`), go_router with routes `/` (placeholder
  `HomeScreen`) + `/onboarding`.

### Gap to close (prerequisite wiring — lands in #16)
There is **no** `activeMetadataSourceProvider` (a live `MetadataSource`) and **no**
`metadataRepositoryProvider` (a `CachingMetadataRepository`), despite the docs
referencing them — M1 deferred them. Every network-facing screen (#16/#18/#20/#21)
needs them, so they are built first, inside #16.

## 2. High-level requirements → user stories (acceptance criteria)

| Req | User story | Issue(s) |
|-----|-----------|----------|
| R2 Track catalogue | **US-1** search & add a title with a status | #15, #16 |
| R3 Watched + bulk + rewatch | **US-2** one-tap watched · **US-3** bulk mark season/show · **US-4** log a rewatch keeping the first date | #19, #20 |
| R4 Upcoming (tracked only) | **US-5** this week's episodes for my shows | #21 |
| R5 Metadata display + attribution | **US-6** open a title, see full metadata + attribution | #18 |
| R10 Offline-first | **US-13** browse + mark offline; it persists | #17 (grid), #18 (cache), all writes |
| — Widget coverage | regression-shaped widget tests across the flows | #22 |

## 3. Architecture decisions

- **AD-1** Branch stacks on `auto/m2` (§0).
- **AD-2** Metadata wiring (#16): `httpClientProvider` (shared disposed
  `http.Client`), `activeMetadataSourceProvider` → `TmdbSource`/`TvdbSource`
  chosen from `activeMetadataBackendProvider` + `RemoteConfig` keys,
  `metadataRepositoryProvider` → `CachingMetadataRepository(source, kind, dao)`.
  All `keepAlive`. UI always goes through these — never an HTTP client directly.
- **AD-3** **Snapshot-at-add** (stats invariant): the add-flow fetches
  `movie/showDetails` **once** on add to snapshot `genresCsv`, `runtimeMinutes`,
  `episodeCountTotal`, `showStatus`, `year`, `posterPath` onto `LibraryItems`.
  Stats/grid then never depend on the disposable cache.
- **AD-4** **Denormalized maintenance is one function** — `recomputeDenormalized(itemId)`
  in `LibraryDao`, called inside the same transaction after **every** `WatchEvents`
  write. Single source of truth for `watchedCount` (non-rewatch rows only) and
  `lastWatchedSeason/Episode` (max aired coordinate among non-rewatch rows). The
  grid reads only these columns — **no cross-domain join** (#15 acceptance).
- **AD-5** Nav shell (#17): `NavigationBar` bottom nav via
  `StatefulShellRoute.indexedStack` — tabs **Library** (home) + **Up Next**;
  **Search** and **Settings** as app-bar actions / pushed routes; **Title
  detail** as pushed route `/title/:id`. All navigation via go_router (no direct
  `Navigator.push`).
- **AD-6** Riverpod convention: providers exposing a **Drift-generated row** are
  plain `StreamProvider`/`FutureProvider` (not `@riverpod`). `@riverpod` for the
  rest. `dart run build_runner build` after provider/table changes.
- **AD-7** Every watch write is a **transaction**; idempotency enforced inside it.

## 4. Issue-by-issue tasks (TDD — tests land with each issue)

### #15 — LibraryItems table + DAO (denormalized progress) · `feat` · [next]
DB only, no UI. Extend `LibraryDao`:
- Reads: `watchLibrary({TrackStatus? status, MediaType? type})` →
  `Stream<List<LibraryItem>>` filtered on the indexed denormalized columns;
  `findByIdentity(...)` (imdb → (mediaType, tmdbId/tvdbId) → title+year) for
  add-dedupe; `getItem(id)`.
- Writes: `addOrGetItem(companion)` (upsert by identity, no duplicate),
  `updateStatus`, `updateRating`, `deleteItem` (cascades `WatchEvents`).
- **`recomputeDenormalized(itemId)`** — reads `WatchEvents`, writes
  `watchedCount`/`lastWatched*` (the primitive #19/#20 call). Land + test here.
- **Tests:** `recomputeDenormalized` sets `watchedCount` = count of **non-rewatch**
  rows and `lastWatched*` = max aired coordinate (insert `WatchEvents` directly,
  incl. a rewatch that must NOT inflate the count or move `lastWatched` backward);
  `watchLibrary` returns only matching status/type and repaints on write;
  `findByIdentity` dedupes across id-blocks. **Acceptance:** grid query needs no
  cross-domain join.

### #16 — Search & add flow · `feat`
- **AD-2 wiring first** (+ its provider test with an overridden backend/config).
- `SearchScreen` (route `/search`): debounced query → `source.search(q)` →
  result rows (poster via `cached_network_image`, title, year). Loading/empty/
  error states.
- Tap result → status-picker bottom sheet (Watchlist/Watching/Completed/On-hold/
  Dropped) → **AD-3** fetch details once, snapshot fields, `addOrGetItem`.
- **Tests:** widget test with a **fake `MetadataSource`** (returns fixed results)
  + in-memory DB: search renders results; add with chosen status inserts a
  `LibraryItem` with that status **and** snapshotted `genresCsv`/`runtimeMinutes`;
  re-adding the same title does **not** duplicate. **Acceptance:** added item
  appears in library.

### #17 — Library grid (filter status/type, offline) · `feat`
- **AD-5 nav shell** (Library home tab + Up Next tab placeholder; Search/Settings
  app-bar actions).
- `LibraryGrid`: poster-2:3 rail cards (title + progress). Progress string built
  **only from denormalized fields** — TV `"S{lastWatchedSeason}E{lastWatchedEpisode} · {episodeCountTotal - watchedCount} left"`,
  movie watched/unwatched. Filter chips (status + type) drive `watchLibrary`.
  Empty state. Poster offline-safe (`cached_network_image` placeholder).
- **Tests:** selecting a filter chip narrows the stream; progress string renders
  from denormalized fields with **no metadata fetch** (offline — no source
  provider overridden / a throwing one); movie vs TV progress format.
  **Acceptance:** "S2E4 · 3 left" shows offline.

### #18 — Title detail (metadata + seasons/episodes + attribution) · `feat`
- Route `/title/:id`. Load `metadataRepository.showDetails/movieDetails` (cache-first
  stream) + `seasonEpisodes` per season. Render backdrop, overview, rating,
  seasons→episodes list (per-episode watched toggle — wired in #19), next-air
  date, and a **mandatory attribution footer** from `source.attribution()` (TMDB
  logo asset + "not endorsed by TMDB" notice, or TheTVDB link).
- **Tests:** attribution widget present and correct **per source** (override the
  source's `attribution()` for tmdb vs tvdb); seasons/episodes list renders from a
  fake details+episodes; renders from cache when the source throws (offline).
  **Acceptance:** seasons/episodes list renders.

### #19 — Watched state: mark/unwatch (idempotent) + rewatch log · `feat`
- Watch-write DAO methods (in `LibraryDao`, transactional, each ends with
  `recomputeDenormalized`):
  - `markWatched(itemId, {season, episode, watchedAt, runtimeMinutes})` —
    **idempotent**: ensures exactly **one** non-rewatch row for
    `(item, season, episode)`; double-tap is a no-op. Movie = null season/episode.
  - `logRewatch(...)` — **appends** an `isRewatch = true` row (keeps the first
    watch's date; does not raise `watchedCount`).
  - `unwatch(itemId, {season, episode})` — deletes **all** rows (incl. rewatches)
    for that episode.
  - `runtimeMinutes` snapshotted at mark-time from the cached episode/details.
- Wire per-episode toggle (detail, #18) + movie mark button.
- **Tests (adversarial):** double-tap `markWatched` ⇒ exactly one row; `logRewatch`
  appends and `watchedCount` unchanged; `unwatch` removes rewatch rows too;
  `lastWatched*` reflects max non-rewatch coordinate after a partial unwatch;
  movie mark/unwatch. **Acceptance:** semantics per the CLAUDE.md watched invariant.

### #20 — Bulk mark (season/show/up-to-episode) · `feat`
- Derive the episode set from `CachedEpisodes`; if a season is uncached, fetch via
  `metadataRepository.seasonEpisodes` first. **Exclude specials (season 0) by
  default.** Bulk = `markWatched` per episode in **one transaction**, idempotent
  (re-bulk is a no-op), **single** `recomputeDenormalized` at the end.
  "Up to episode" = all aired-order episodes ≤ `(season, episode)`.
- UI: "mark season / show watched" buttons in detail; "watch up to here" on an
  episode row.
- **Tests:** bulk from a **partial cache** (some cached, some fetched) marks the
  whole season; specials excluded; re-running is idempotent; up-to-episode
  boundary is inclusive and doesn't touch later episodes. **Acceptance:** one
  action marks a whole season.

### #21 — Upcoming/calendar (tracked only) · `feat`
- Up Next tab. Show ids = tracked shows only (status in
  watching/watchlist/on-hold; **skip dropped and ended-completed** per the caching
  invariant). `source.upcomingForTracked(showIds)` → episodes **grouped by day**
  (this week). Tracked **movie** releases with a future date grouped alongside.
- **Tests:** an untracked show's upcoming episode does **not** appear; a dropped/
  ended-completed tracked show is skipped; this-week grouping. Inject a `Clock`.
  **Acceptance:** this-week view populated.

### #22 — Widget tests (bulk, filters, idempotency) · `test`
- Widget-layer coverage tying the flows together (`ProviderScope` overrides, **never
  the real DB**): library filter chips, detail bulk-mark button → grid progress
  updates, per-episode toggle idempotency at the widget level, search→add. Fill
  gaps left by the per-issue tests. **Acceptance:** green.

## 5. Testing strategy

- **Unit:** DAO denormalized maintenance + filters (#15), watched semantics
  (#19), bulk from partial cache (#20), upcoming filtering (#21) — all on
  `NativeDatabase.memory()`, `Clock` injected where time matters.
- **Widget:** every screen via `ProviderScope` overrides with a **fake
  `MetadataSource`** + in-memory DB — never the real DB or network.
- **Adversarial, not confirmatory:** each test written as "what does a regression
  look like?" (double-tap, re-bulk, unwatch-with-rewatches, untracked-in-upcoming,
  offline-render-without-source).
- **Gate:** `just check` (codegen → analyze → format-check → test) — same as CI —
  green before every commit; `/quality-gate` advisory each `work` step.
- **Run the real artifact (finalize):** emulator smoke via the `android-emulator`
  skill of search→add→detail→mark-watched→library-progress→upcoming, since these
  touch network/image/navigation surfaces tests can't reach.

## 6. Dependency order (autopilot works #15→#22 in order)

`#15` (DB) → `#16` (wiring + search/add) → `#17` (shell + grid) → `#18` (detail)
→ `#19` (watched) → `#20` (bulk) → `#21` (upcoming) → `#22` (widget sweep).

## 7. Assumptions / open questions (no human in the loop — defaulted)

- **Branch base** stacked on `auto/m2`, not empty `main` (§0) — the load-bearing
  deviation; flagged in the PR.
- **Add-flow** does one details fetch to satisfy the snapshot invariant (AD-3);
  if offline at add-time, snapshot what the search result carries and leave
  `genresCsv`/`runtimeMinutes` null (backfilled on next detail view).
- **Upcoming movies** use `LibraryItems.year`/cached release date; if absent, the
  movie is simply omitted from Up Next.
- **"Watch up to here"** is a long-press / overflow action on an episode row.
