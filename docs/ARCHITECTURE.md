# Watchnook — Architecture

Watchnook is an **Android-first, local-first** TV & movie tracker. Everything the user owns
lives on-device; the only network dependency is a **metadata API** (TMDB, or TheTVDB v4) for
catalogue, artwork, and air-dates. No backend, no accounts, no social, no ads.

For the full product context, requirements, user stories, and architecture-decision records
(ADR-1…ADR-8), see [`PRD.md`](PRD.md). This document is the contributor-facing summary of the
structure and the **load-bearing invariants** — the cross-file rules that aren't obvious locally.

## Project structure

```
lib/
  core/            # shared infrastructure
    config/        # RemoteConfig + baked/cached key delivery
    database/      # Drift AppDatabase, DAOs, providers
    metadata/      # MetadataSource interface + TMDB/TVDB impls + SWR cache
    routing/       # go_router
    theme/         # Material 3 theme + design tokens
    import_export/ # importers, resolver, MergeApplier, export service
    widgets/       # shared widgets (e.g. attribution footer)
  features/<feature>/{data,domain,presentation}/   # split where it earns it
```

- **State: Riverpod only** (`@riverpod` + `riverpod_generator`) — no `setState` for app state.
  Run `dart run build_runner build` after changing providers or Drift tables (generated `*.g.dart`
  is **not** committed).
  - A provider exposing a **Drift-generated row** must be a plain `StreamProvider`/`FutureProvider`,
    not `@riverpod` (the generator throws `InvalidTypeException` on types from another library's
    generated part).
- **Navigation: go_router** (`lib/core/routing/`) — no direct `Navigator.push`.
- **Database: Drift** — all access via DAOs; no raw SQL outside table definitions. Every schema
  change bumps `schemaVersion` + adds a `MigrationStrategy` step. Tests use an in-memory DB
  (`NativeDatabase.memory()`).
- **Metadata: provider-agnostic** — one `MetadataSource` interface, two impls (`TmdbSource`,
  `TvdbSource`), selected at runtime by `activeMetadataSourceProvider`. UI/features never call an
  HTTP client directly — always go through `MetadataSource`.
- **Caching: stale-while-revalidate** — return cache instantly (offline-capable), background-refetch
  if stale, let Drift `.watch()` streams repaint. Refresh only tracked shows on app-resume; skip
  `dropped` / ended-`completed`. Images via `cached_network_image`.

## Invariants (the load-bearing rules)

These are documented at their call sites too. Break one and something breaks elsewhere.

1. **Two data domains.** User-owned tables (`LibraryItems`, `WatchEvents`) are precious — exported
   and Android-Auto-Backed-up. Cache tables (`CachedMedia`, `CachedEpisodes`) are disposable —
   re-fetchable, and **excluded from export/backup**. The export reads **only** user tables (and
   never SharedPreferences), so no key/entitlement can leak. Regression-tested.

2. **Watched = idempotent toggle.** "Mark watched" ensures exactly **one** non-rewatch `WatchEvents`
   row for `(item, season, episode)` — a double-tap is a no-op. "Log rewatch" **appends** a row with
   `isRewatch = true`. "Unwatch" deletes **all** rows for that episode. `LibraryItems.watchedCount`
   is denormalized and maintained on every write, so the library grid never does a cross-domain join
   per card.

3. **Episode identity is pinned to AIRED order.** TMDB is aired-order native; `TvdbSource` requests
   the aired/official season type. `WatchEvents` stores aired `(season, episode)` + the item's
   `recordedSource`. On a backend switch, relink by `imdbId` (the universal join key), then reconcile
   episodes by **air-date**; set `relinkFailed = true` on anomalies (absolute-numbered/anime,
   specials) — never silently scramble watched flags.

4. **Import ≠ restore.** Restore uses a **replace** path (wipe + insert). Import uses an **additive
   MergeApplier** (upsert by id-block: imdb/tmdb/tvdb, then title+year) that merges watch history and
   **never wipes** existing rows. Re-importing must not duplicate or destroy history.

5. **Stats read snapshotted facts.** `runtimeMinutes` is snapshotted onto `WatchEvents` at mark-time;
   `genresCsv`/`year`/`runtimeMinutes` onto `LibraryItems` at add-time. Stats never depend on the
   disposable cache. Imported events legitimately carry **neither** runtime nor genres, so an imported
   library has complete **counts and decades** but empty **hours and genres** — surfaced with a
   footnote, and **never** back-filled from the cache.

6. **Remote config never blocks boot.** Use the cached/baked-in key immediately; fetch-and-update is
   fire-and-forget, wrapped `try { } on Object { }`. An unguarded `await` before `runApp()` risks a
   boot loop.

## Metadata & attribution

- The API key is embedded / remote-config-delivered and **public by design** — TMDB rate-limits
  per-IP, not per-key, so a shared key is fine and rotation is a config swap (no release).
- **Attribution is mandatory** and per-source. TMDB requires **both** the TMDB **logo** and the exact
  notice *"This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise
  approved by TMDB."* TheTVDB requires a linked credit. Rendered on the detail screen + settings.
- **Licensing:** the TMDB dev key is **non-commercial** — any revenue (donations included) counts as
  commercial use and needs a TMDB commercial licence or TheTVDB. Watchnook ships **free**.

## Testing

- **Unit:** importers (against real fixtures in `test/fixtures/` + malformed inputs),
  resolver/MergeApplier, watched-semantics, export/import round-trip, the `MetadataSource` **contract
  suite** (both impls) via `package:http/testing.dart` `MockClient`, TVDB token-refresh. Inject a
  `Clock`.
- **Widget:** key screens via `ProviderScope` overrides (never the real DB). A DB-backed
  `StreamProvider` screen (e.g. the library grid) **must** override that provider with a synchronous
  `Stream.value(snapshot)` — a live Drift `.watch()` stream never quiesces under `flutter_test`
  fake-async, so `pumpAndSettle()` hangs for its full 10-minute timeout. This bites full-app boot
  tests too (home is the DB-backed grid).
- **E2E (Patrol, `integration_test/`):** import sample data → library populated → bulk-mark → export
  → re-import matches.
- Write **adversarial** tests (what does a regression look like?), not confirmatory ones.

## Dart/Flutter gotchas worth knowing

- **`as`-cast failures throw `TypeError`, not `Exception`.** `json['x'] as String` on a null/wrong
  value raises `TypeError` (a subclass of `Error`), so `on Exception`/`on FormatException` won't catch
  it. Test structurally-valid-but-malformed input, not just syntactically-invalid input.
- **Unguarded `await` in `main()` before `runApp()` = boot loop** if the trigger persists on disk.
  Wrap startup restore/parse/migration in `try { } on Object { }` and degrade to a safe no-op.
