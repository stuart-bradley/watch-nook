# CLAUDE.md — Project Instructions for Claude Code

Update this file whenever Claude does something incorrectly so it learns not to repeat the mistake. Keep it lean.

## Project Overview

**Watchnook** is an Android-first Flutter app: a **local-first TV & movie tracker** to replace TV Time. No backend, no accounts, no social, no ads. The one network dependency is a **metadata API** (TMDB or TheTVDB v4) for catalogue/artwork/air-dates — everything the user owns lives on-device.

Core features: track shows/movies with a status; mark movies & episodes watched/unwatched with **bulk** actions + rewatch logging; upcoming episodes for tracked titles; metadata display with attribution; **import** from TV Time/IMDb/Letterboxd/Trakt; **export** (JSON + Letterboxd CSV); Android Auto Backup; watch stats. All offline-first.

### Key docs
- `docs/PRD.md` — requirements, user stories (US-N), architecture decisions (ADR-N), data model, milestones.
- `docs/GITHUB_ISSUES.md` — milestone/issue breakdown (M0–M5); mirrors the GitHub milestones/issues.
- `docs/DESIGN_BRIEF.md` — UX brief for the design system.
- `docs/MANUAL_SETUP.md` — human prerequisites (API keys, real export fixtures) done before development.

## Task Management

Work is tracked via **GitHub Issues** (milestones M0–M5) on this repo.

1. Pick the lowest-numbered open, unblocked issue in the active milestone. Skip anything labelled `needs-human`.
2. Feature branch (autopilot uses `auto/m<N>`; manual work `feat/short-desc`).
3. Reference the issue in **every** commit: `feat(metadata): tmdb source (#8)`.
4. Push and open a PR with `Closes #N` — CI runs on PRs.
5. Don't scope-creep beyond the issue; file a new issue for unrelated work you find.

The **acceptance criteria in the issue body are the contract** — implement to them.

## Development Workflow

1. Make changes.
2. `just check` (codegen + analyze + format-check + test) — same as CI.
3. `dart format .` to auto-fix formatting; re-run `just check` before a PR.

### Definition of Done (beyond green `just check`)
`just check` is necessary, not sufficient. "Run the real artifact" = an emulator/device smoke (via the `android-emulator` skill) of any change touching surfaces tests can't reach: **network/metadata fetching, image loading, import (real file), backup/restore, navigation, the launcher icon**. Write **adversarial** tests (what does a regression look like?), not confirmatory ones. When you add a shared value / invariant, audit every consumer in the same change.

## Invariants (document, don't rediscover)

Cross-file rules that aren't obvious locally — keep them in a comment at the site **and** here:

- **Two data domains.** User-owned tables (`LibraryItems`, `WatchEvents`) are precious — exported + auto-backed-up. Cache tables (`CachedMedia`, `CachedEpisodes`) are disposable — re-fetchable, **excluded from export/backup**. `ExportData` reads **only** user tables (and never SharedPreferences), so no key/entitlement can leak. Regression-test the exclusion.
- **Watched = idempotent toggle.** "Mark watched" ensures exactly **one** non-rewatch `WatchEvents` row for `(item, season, episode)` — a double-tap is a no-op. "Log rewatch" **appends** a row with `isRewatch = true`. "Unwatch" deletes **all** rows for that episode. `LibraryItems.watchedCount` is denormalized and maintained on every write (so the library grid never does a cross-domain join per card).
- **Episode identity is pinned to AIRED order.** TMDB is aired-order natively; `TvdbSource` must request the aired/official season type. `WatchEvents` stores aired `(season, episode)` + the item's `recordedSource`. On a backend switch, relink the show via `imdbId` (universal join key) then reconcile episodes by **air-date**; set `relinkFailed = true` on anomalies (absolute-numbered/anime, specials) — never silently scramble watched flags.
- **Import ≠ restore.** Restore uses a **replace** path (wipe + insert). Import uses an **additive MergeApplier** (upsert by id-block: imdb/tmdb/tvdb, then title+year) that merges watch history and **never wipes** existing rows. Re-importing must not duplicate or destroy history.
- **Stats read snapshotted facts.** `runtimeMinutes` is snapshotted onto `WatchEvents` at mark-time; `genresCsv`/`year`/`runtimeMinutes` onto `LibraryItems` at add-time. Stats never depend on the disposable cache (which can TTL-evict or be excluded from a restore). On the read side, runtime coalesces `WatchEvents.runtimeMinutes` → the item's runtime → zero. Imported events legitimately carry **neither** runtime nor genres (`MergeApplier` writes null; the `Resolver` returns a `MediaSearchResult`, which has no such fields), so an imported library has complete **counts and decades** but empty **hours and genres** — surface that with the footnote, and **never** back-fill either from the cache.
- **Remote config never blocks boot.** Use the cached/baked-in key immediately; fetch-and-update fire-and-forget, wrapped `try { } on Object { }`. An unguarded `await` before `runApp()` risks a boot loop.

## Conventions

### State & structure
- **Riverpod only** (`@riverpod` + `riverpod_generator`). No `setState` for app state, no GetX/Provider. Run `dart run build_runner build` after changing providers/Drift tables.
- A provider exposing a **Drift-generated row** must be a plain `StreamProvider`/`FutureProvider`, not `@riverpod` (the generator throws `InvalidTypeException` on types from another library's generated part).
- Feature layout: `lib/features/<feature>/{data,domain,presentation}/` (split where it earns it). Shared code in `lib/core/{metadata,database,routing,theme,import_export,utils,widgets}/`.
- Navigation via **go_router** (`lib/core/routing/`). No direct `Navigator.push`.

### Metadata (provider-agnostic — ADR-1)
- One `MetadataSource` interface; two impls (`TmdbSource`, `TvdbSource`), selected at runtime by `activeMetadataSourceProvider` from `RemoteConfigService`. Never call an HTTP client directly from UI/features — go through `MetadataSource`.
- The API key is embedded/remote-config-delivered and **public by design** (per-IP rate limiting on TMDB means a shared key is fine). Keep rotation cheap (config swap, no release).
- **Attribution is mandatory** and per-source. TMDB's terms require **both** the TMDB **logo** *and* the **exact** notice: "This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB." (Current app ships neither the logo nor the exact wording — compliance gap, must fix before public release. TheTVDB = linked credit.) Show it on the detail screen + settings.
- **Licensing coupling:** TMDB's free developer key is **non-commercial only** — and per the TMDB API terms **any** revenue counts as commercial, **donations included**. So do **not** add monetization *or a donations link* while on a TMDB developer key; it needs a TMDB commercial licence or TheTVDB first. Note TheTVDB's key is per-key/contract-attributed (not per-IP), so it can't be safely embedded client-side without a proxy — for a minimal-revenue app, monetization is effectively out of scope (see PRD ADR-8). Keep it **free**.

### Database (Drift)
- All access via DAOs; no raw SQL outside table definitions. Every schema change bumps `schemaVersion` + adds a `MigrationStrategy` step. In-memory DB (`NativeDatabase.memory()`) in tests.

### Caching
- Stale-while-revalidate: return cache instantly (offline-capable), background-refetch if stale, let Drift `.watch()` streams repaint. Refresh **only tracked** shows, on app-resume; skip `dropped` / ended-`completed`. Images via `cached_network_image` (raise its cache cap).

## Testing (alongside every change)
- **Unit:** importers (against real fixtures in `test/fixtures/` + malformed inputs), resolver/MergeApplier, watched-semantics, export/import round-trip, `MetadataSource` **contract suite** (both impls) via `package:http/testing.dart` MockClient, TVDB token-refresh. Inject a `Clock`.
- **Widget:** key screens via `ProviderScope` overrides (never the real DB). A DB-backed `StreamProvider` screen (e.g. the library grid) **must** have that provider overridden with a synchronous `Stream.value(snapshot)` — a live Drift `.watch()` stream never quiesces under flutter_test fake-async, so `pumpAndSettle()` hangs for its full **10-minute** timeout and then fails with *"A Timer is still pending after the widget tree was disposed"*. This bites **full-app boot tests too** (`smoke_test`, onboarding) — home is the DB-backed library grid, so they must stub `libraryGridProvider` even though they only assert on routing.
- **E2E (patrol, `integration_test/`):** import sample TV Time → library populated → bulk-mark → export → re-import matches. Pin `patrol_cli` to the version matching `patrol`; no `/` in a `patrolTest` name; patrol-generated bundles are gitignored.

## Commit Message Format
```
type(scope): description (#issue)
```
Types: `feat`, `fix`, `test`, `refactor`, `chore`, `docs`. **Do not co-author commits with Claude/Anthropic.** Commit with the personal identity `Stuart Bradley <stuy.bradley@gmail.com>` (via `-c`, don't modify git config).

## Things Claude Should NOT Do
- Don't add a backend, accounts/auth, or social features. The only network calls are the metadata API.
- Don't add monetization while on a TMDB developer key (non-commercial — see Metadata).
- Don't write iOS-only code (Android is the target).
- Don't put cache data in the export/backup, or user data in the cache tables.
- Don't use `BuildContext` across async gaps without checking `mounted`.
- Don't commit generated files (`*.g.dart`).
- Don't use `GetX`/`Provider` (Riverpod only), `any`-style dynamic, or skip error handling.
- Don't commit without running `just check`.

## Self-Improvement
After every correction or mistake, add a concise rule here. Keep this file lean.
