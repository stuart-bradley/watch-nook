# Milestone M0 — Scaffold & foundation · Implementation Plan

Branch `auto/m1` · PR `Closes #1 #2 #3 #4 #5`. Issues worked lowest-first, one
commit per issue with a `(#N)` ref. `#6`/`#7` are `needs-human` and already
**closed** — out of scope. Human merges; every gate here is advisory.

Source of truth: `docs/PRD.md` (ADRs + data model), `docs/GITHUB_ISSUES.md`
(acceptance = contract), `.claude/CLAUDE.md` (invariants). Reference skeleton:
`/home/stuart/git/well-quill` (Flutter 3.44.0, Dart 3.12.0) — we adopt its
*conventions and config verbatim*, not its domain code.

> **Rev 2 (plan-reviewer pass).** Addressed 4 findings before implementing:
> (1) baked-in key path now matches the committed **nested** `secrets.json`
> shape (`tmdb.apiKey`/`tmdb.apiReadAccessToken`/`tvdb.apiKey`) — see #5;
> (2) `ci.yml` passes `smoke-build: true` so CI compiles the debug Android
> build (validates signing/desugar/`namespace` without an emulator) — see #2;
> (3) `e2e.yml`'s job is guarded to **skip** until `integration_test/` exists,
> so the M0 PR's e2e check is a green skip and auto-activates in M3 — see #2;
> (4) fonts: `GoogleFonts.config.allowRuntimeFetching = false` guarantees **zero**
> non-metadata network calls (offline-first invariant); real font bundling
> flagged as follow-up — see #4. Minor: D3 provider renamed to avoid a retype.

## Goal / high-level requirements

Stand up a buildable, CI-green, offline-first Flutter app skeleton that later
milestones build on: project + signing, CI/justfile, Drift+Riverpod DB harness,
go_router + delivered Honey theme, and a non-blocking RemoteConfig. No metadata
fetching, no library UI, no import — those are M1+. Acceptance for the milestone
= `just check` green locally **and** a green `check` on the PR.

Guiding user stories (from PRD; M0 lays their foundation, doesn't fulfil them):
- **US-14** (rotate key / switch backend with no release) → #5 RemoteConfig.
- **US-13** (offline-first) → #3 local DB + #5 config-loads-without-network.
- Design/theme (DESIGN_BRIEF "Delivered") → #4 theme port.

ADRs in play: **ADR-2** (remote, non-blocking config), **ADR-3** (two data
domains, one Drift DB). Invariant enforced this milestone: *"Remote config never
blocks boot"* (no unguarded `await` before `runApp()`).

---

## #1 — Scaffold watch_nook Flutter project · `chore`

**Approach (lazy: adopt skeleton config, write fresh minimal `lib/`).** Do NOT
copy well-quill's 100+ feature files and delete them — generate platform
scaffolding, then overlay adapted config + a minimal app.

Steps:
1. `flutter create --org com.stuartbradley --project-name watch_nook --platforms android .` (Android-only; no iOS/web/desktop, no linux dir).
2. Overlay adapted config from the skeleton:
   - `pubspec.yaml` — name `watch_nook`; **M0-only deps** (add later deps in their milestones): `flutter_riverpod ^3.1.0`, `riverpod_annotation ^4.0.0`, `go_router ^17.1.0`, `drift ^2.25.0`, `drift_flutter ^0.2.4`, `http ^1.6.0`, `shared_preferences ^2.3.0`, `path_provider ^2.1.5`, `google_fonts ^6.2.1`, `dynamic_color ^1.7.0`, `clock ^1.1.1`, `cupertino_icons`. Dev: `build_runner`, `drift_dev`, `riverpod_generator ^4.0.0+1`, `custom_lint`, `riverpod_lint ^3.1.0`, `very_good_analysis ^10.2.0`, `flutter_test`, `integration_test`, `patrol ^3.20.0`, `patrol_finders`, `flutter_launcher_icons`. (No `flutter_local_notifications`, `in_app_purchase`, `mobile_scanner`, `local_auth`, `permission_handler`, `fl_chart`, `file_picker`, `share_plus`, `timezone` — none are M0; import/export/stats deps land in M3–M5.)
   - `analysis_options.yaml` — copy verbatim; drop the wellquill-specific theme excludes (our theme is hand-portable, not generated) but keep `*.g.dart`/patrol excludes + the riverpod lint tweaks.
   - `android/app/build.gradle.kts` — `namespace`/`applicationId = com.stuartbradley.watchnook`; Java 17 + `isCoreLibraryDesugaringEnabled`; `key.properties` signing block with **debug fallback**; keep the Patrol runner + orchestrator (E2E lands M3, harmless now). `coreLibraryDesugaring(... desugar_jdk_libs:2.1.4)`.
   - `android/app/src/main/AndroidManifest.xml` — app label "Watchnook"; **`android:allowBackup="true"` + `fullBackupContent`/`dataExtractionRules` left default for now** (allowlist is M4 #32).
3. `lib/main.dart` — minimal `runApp(ProviderScope(child: WatchnookApp()))`; `WatchnookApp` = `MaterialApp` (default theme for now; #4 swaps in the router+theme) showing a blank `HomeScreen`. **No** notifications/backup/trial/lock boot (all wellquill-specific). No `await` before `runApp`.
4. `lib/features/home/presentation/home_screen.dart` — blank `Scaffold` with an `AppBar('Watchnook')` and an empty body (placeholder until M2 library grid).
5. Strip Flutter's counter-app boilerplate (per global CLAUDE.md "remove boilerplate").
6. `key.properties`/keystore stay gitignored (already in `.gitignore`); debug fallback means PR CI builds unsigned-release fine.

**Tests (alongside):**
- `test/smoke_test.dart` — pump `WatchnookApp`, assert the blank home renders (`AppBar` title "Watchnook" present). Adversarial angle: assert **no** MaterialApp `home:`+`routerConfig:` conflict and `debugShowCheckedModeBanner` off.
- `flutter analyze` clean (gate).
- **Android compile validation:** `just build-debug` (`flutter build apk --debug`) — compiles the Gradle config (signing debug-fallback, `coreLibraryDesugaring`, `applicationId`/`namespace`). Advisory locally (autopilot sandbox may lack the Android SDK), but the **CI `check` job compiles it for real** via `smoke-build: true` (#2) — that's the hard gate that `flutter test` alone can't reach.

**Acceptance:** `just check` passes locally; CI `smoke-build` compiles the APK; app boots to a blank home.
**Risk paths touched:** `android/**`, `**/signing*`, `**/key.properties`, `**/main.dart` → checkpoint surface (finalize will flag).

---

## #2 — CI/CD via ci-shared@v1 + justfile · `chore`

**Approach:** copy the three thin-caller workflows + `justfile` from the
skeleton, adapt names, **strip wellquill-only bits**.

Steps:
1. `.github/workflows/{ci,e2e,release}.yml` — thin callers on `stuart-bradley/ci-shared@v1`; pin `flutter-version: "3.44.0"` (skeleton's known-good; unpin note kept).
   - **`ci.yml`** (the `check` job on `flutter-ci.yml@v1`): pass **`smoke-build: true`** verbatim from the skeleton — this compiles the debug Android build in CI, so the signing/desugar/`namespace`/`applicationId` config from #1 is validated by a **hard gate** (closes the "`just check` doesn't compile Android" gap without needing an emulator).
   - **`e2e.yml`** (PR-only, `flutter-e2e.yml@v1`): keep the skeleton's path filters, but **guard the job to skip until integration tests exist** — job-level `if: ${{ hashFiles('integration_test/**/*_test.dart') != '' }}`. M0 has no `integration_test/`, so the e2e check is a **green skip** on the M0 PR (not a red "no tests" failure); it **auto-activates in M3** when the first `integration_test` lands (E2E is an M3 deliverable per CLAUDE.md — do **not** stand up patrol here). Keep the flutter-version pin + the "compileFlutterBuildDebug" note.
2. `justfile` — `default: check`; recipes `codegen` (`dart run build_runner build`), `analyze`, `format-check` (git-tracked `*.dart`), `format`, `test` (**drop** the wellquill `TZ=America/New_York` pin — no timezone-sensitive engine here; plain `flutter test`), `check: codegen analyze format-check test`, `build-debug`, `e2e` (`patrol test`), `release-sign`, **`release-build`** (`flutter build appbundle --release` — **strip** the `ic_stat_reminder` R8 assertion; Watchnook has no notification icon), `release-deploy`, `release`, `release-ci`, `setup`, `clean`.
3. `scripts/` — copy `release-sign.sh`/`release-deploy.sh` if the release recipes reference them; otherwise omit until M5 (#38 is `needs-human`). Lazy: keep only what `check`/`build-debug`/`e2e` need now; leave release scripts as a thin stub or defer to #38. **Decision D2 (flag):** don't hand-roll release scripts in M0 — `release-sign`/`release-deploy` recipes can reference `scripts/*.sh` that land with #38; M0 only needs `check` green.

**Tests (alongside):** the PR itself is the test — CI `check` job runs and goes green (acceptance). Locally `just check` mirrors CI.

**Acceptance:** green `check` on the PR.
**Risk paths touched:** `.github/**` → checkpoint surface.

---

## #3 — Drift DB + Riverpod provider + migration scaffold · `feat`

**Approach:** DB *harness* + the two **user-domain tables at v1** (canonical from
the PRD data model), thin DAO for round-trip, migration/integrity tests. A
migration scaffold needs real tables to be meaningful; the two user tables are
FK-linked so the `foreign_keys` pragma is actually testable — lazier and more
adversarial than a throwaway placeholder table.

**Scope boundary (Decision D1 — flag):**
- **#3 lands:** `LibraryItems` + `WatchEvents` *table definitions* (v1, per PRD §Data model) + a thin `LibraryDao` (basic insert/get) for the round-trip.
- **Deferred to owning issues:** denormalized-progress *maintenance logic* + grid query → #15 (M2); watched idempotency/rewatch/unwatch semantics → #19; bulk → #20; cache tables `CachedMedia`/`CachedEpisodes` → #13 (M1, schema **v2**). This keeps each later issue's contract intact.

Steps:
1. `lib/core/database/tables.dart` — `LibraryItems`, `WatchEvents` per PRD (enums via `IntEnum`/text columns; unique indices on `(mediaType,tmdbId)`,`(mediaType,tvdbId)`,`imdbId`; index `trackStatus`; `WatchEvents.libraryItemId` FK). `watchedCount` default 0, `relinkFailed` default false.
2. `lib/core/database/app_database.dart` — `@DriftDatabase(tables:[LibraryItems, WatchEvents], daos:[LibraryDao])`; `schemaVersion = 1`; `MigrationStrategy` (`onCreate: m.createAll()`); `beforeOpen` → `PRAGMA foreign_keys = ON`; default ctor `AppDatabase()` on `driftDatabase(name: 'watchnook')`; `AppDatabase.forTesting(super.e)` for `NativeDatabase.memory()`.
3. `lib/core/database/library_dao.dart` — thin `@DriftAccessor`; `insert`/`getAll`/`watchAll` only (progress logic is #15).
4. `lib/core/database/database_provider.dart` — `@Riverpod(keepAlive: true) AppDatabase appDatabase(Ref ref)` (dispose→close) + `libraryDao` accessor provider. **Rule (CLAUDE.md):** providers exposing Drift-generated rows must be plain `StreamProvider`/`FutureProvider`, not `@riverpod` — note it for the M2 UI providers.
5. `dart run build_runner build` (never commit `*.g.dart` — gitignored).

**Tests (alongside, adversarial):**
- `test/core/database/library_dao_test.dart` on `AppDatabase.forTesting(NativeDatabase.memory())`: insert a `LibraryItem` → read it back (round-trip).
- **FK enforcement:** inserting a `WatchEvent` with a non-existent `libraryItemId` **throws** (proves `foreign_keys = ON` in `beforeOpen`, not just the pragma being present). Regression guard for the invariant.
- **Migration/integrity:** open at v1, assert `verifySelfIntegrity()` (or `validateDatabaseSchema`) passes; assert `schemaVersion == 1`.

**Acceptance:** DB opens; migration test passes.
**Risk paths touched:** `**/database/**`, `**/*.g.dart` → checkpoint surface.

---

## #4 — go_router + onboarding redirect + Material 3 theme · `feat`

**Approach:** port the *delivered* Honey theme; add a router provider with a
first-run onboarding redirect gated on a prefs flag (no library dependency yet —
that refinement is an M4 restore concern).

Steps:
1. **Theme port** — lift `docs/design/flutter/lib/core/theme/{watchnook_theme,watchnook_tokens}.dart` → `lib/core/theme/`. Add `google_fonts` (done in #1 pubspec). **Swap `withOpacity(x)` → `withValues(alpha: x)`** — exactly **2 sites** (both `withOpacity(0.22)`): `watchnook_theme.dart:181` chip `selectedColor`, `:194` nav `indicatorColor` (there is **no** nav-label site). `grep -rn "withOpacity\|\.value\b\|MaterialStateProperty\|surfaceVariant\|background:" lib/core/theme/` once — `very_good_analysis` is strict and any post-3.22 deprecation fails the analyze gate. Keep both light+dark `ColorScheme`s.
   - **Fonts (offline-first invariant):** `GoogleFonts.newsreaderTextTheme`/`manropeTextTheme` HTTP-fetch from fonts.google.com on first use — that's a **non-metadata network call**, which CLAUDE.md forbids ("the only network calls are the metadata API"). Set **`GoogleFonts.config.allowRuntimeFetching = false`** in `main` (before `runApp`) so the app makes **zero** font network calls — it falls back to the platform font if a family isn't bundled. **Follow-up (flag D6):** bundle Newsreader + Manrope `.ttf` into `assets/fonts/` + declare in pubspec `fonts:` for the real design typography; needs the font files (asset/human step — the autopilot sandbox may be offline). Until bundled the app renders the platform fallback — correct-but-plain, and never leaks a network call.
2. `lib/features/settings/data/shared_preferences_provider.dart` — `@Riverpod(keepAlive:true)` exposing the `SharedPreferences` instance (override in `main` after `getInstance()`), mirroring the skeleton.
3. `lib/features/onboarding/presentation/onboarding_provider.dart` — `@Riverpod(keepAlive:true)` `onboardingSeen` bool (read/`markSeen()` via prefs).
4. `lib/features/onboarding/presentation/onboarding_screen.dart` — minimal single-page welcome + "Get started" → `markSeen()` (router redirect then routes to `/`).
5. `lib/core/routing/app_router.dart` — `@Riverpod(keepAlive:true) GoRouter appRouter(Ref ref)`; routes `/` (Home), `/onboarding`; `redirect`: `!seen && loc != '/onboarding' → '/onboarding'`; `seen && loc == '/onboarding' → '/'`; `refreshListenable` on `onboardingSeen`. **Lazy vs skeleton:** drop well-quill's `activeMedications`-empty gating — no library provider until M2; gate on the flag alone. Leave a `// M4:` note that restore should pre-set `seen`.
6. `main.dart` (#4 revision) — `await SharedPreferences.getInstance()` (allowed: fast local I/O, not network). **Guard it** `try { … } on Object { … }` degrading to an in-memory/empty prefs so a corrupt prefs file (which persists across launches) can't boot-loop — cheap insurance for the named M0 boot-loop invariant. Override `sharedPreferencesProvider`; set `GoogleFonts.config.allowRuntimeFetching = false` (see step 1); `MaterialApp.router(theme: WatchnookTheme.light, darkTheme: WatchnookTheme.dark, routerConfig: ref.watch(appRouterProvider))`. Optional `DynamicColorBuilder` — **skip for now** (YAGNI; theme ships fixed Honey, add Material You in #35/#36 if wanted; flag).

**Tests (alongside):**
- `test/core/routing/app_router_test.dart` (**redirect unit test, adversarial):** unseen → redirected to `/onboarding`; seen → `/onboarding` bounces to `/`; unseen already at `/onboarding` → no redirect loop (null). Override `onboardingSeenProvider`; no real router navigation needed for the pure redirect logic, but a widget-level pump of `MaterialApp.router` with overrides confirms end-to-end.
- Widget test: onboarding "Get started" → home renders (US acceptance).

**Acceptance:** onboarding → home navigates; theme applied.
**Risk paths touched:** `**/main.dart` → checkpoint surface.

---

## #5 — RemoteConfigService (non-blocking) + backend toggle scaffold · `feat`

**Approach:** a service that returns config **synchronously** from
cache/baked-in defaults on boot and fires a remote refresh *fire-and-forget*,
wrapped `try { } on Object { }`. Enforces ADR-2 + the "config never blocks boot"
invariant.

Steps:
1. `lib/core/config/remote_config.dart` — immutable `RemoteConfig { MetadataBackend backend; String tmdbApiKey; String tmdbReadToken; String tvdbApiKey; int? minVersion }` + `fromJson`/`toJson` (guard `as`-cast `TypeError` with a shape check → fall back to defaults on malformed JSON; CLAUDE.md Dart gotcha). **Model shape matches the committed `secrets.json` contract (from #6):** TMDB v4 uses a **Bearer** `apiReadAccessToken` *and* keeps the v3 `apiKey`, so the model carries **both** `tmdbApiKey` (v3 query param) and `tmdbReadToken` (v4 bearer) — M1 (#9–#11) picks which it calls with; carrying both now avoids an M1 model reshape. `tvdbApiKey` is TheTVDB's login key. This is the human's contract, not speculation.
2. `MetadataBackend` enum `{ tmdb, tvdb }`.
3. **Baked-in default** — populated locally by `--dart-define-from-file=secrets.json` (gitignored; keys are public-by-design but kept out of git). **The committed `secrets.json` is NESTED** (`{activeSource, tmdb:{apiKey, apiReadAccessToken}, tvdb:{apiKey}}`), and `--dart-define-from-file` does **NOT** dot-flatten nested JSON — a nested object arrives as its **JSON-string** value under the top-level key. So the defines are: `String.fromEnvironment('activeSource')` → `"tmdb"`; `String.fromEnvironment('tmdb')` → `'{"apiKey":"…","apiReadAccessToken":"…"}'`; `String.fromEnvironment('tvdb')` → `'{"apiKey":"…"}'`. Read these at **runtime** in a small `_bakedDefaults()` helper: `activeSource` maps to `MetadataBackend`; `jsonDecode` the `tmdb`/`tvdb` strings and pull `apiKey`/`apiReadAccessToken`, the whole parse wrapped `try { … } on Object { … }` → empty defaults on absent/malformed (CI ships empty → all empty, tests inject; matches the malformed-JSON gotcha). **Do not** `jsonDecode` in a `const` context (it's a runtime call), and **do not** commit a key to a Dart const.
   - *Guardrail:* `secrets.json` shape is the contract with #6 — a plain-string `String.fromEnvironment('TMDB_API_KEY')` (the earlier draft) silently resolves to empty against the nested file, killing the baked-in fallback and biting M1's `api_smoke` (#8). Regression-guard the `_bakedDefaults()` parse with a unit test feeding the nested-JSON-string form.
4. `lib/core/config/remote_config_service.dart` — `RemoteConfigService`:
   - `RemoteConfig current()` — synchronous: cached-prefs JSON → baked-in default. Never touches the network.
   - `Future<void> refresh()` — GET the hosted JSON (`http`), parse, write to prefs; the **whole body** wrapped `try { … } on Object { … }` (swallow + `debugPrint`). Injectable `http.Client` + `Clock` for tests.
   - Hosted URL = a `const` (GitHub Pages/raw) — may 404 until the human hosts it; fire-and-forget failure degrades to baked-in (flag).
5. `lib/core/config/remote_config_provider.dart` — `@Riverpod(keepAlive:true) RemoteConfigService remoteConfigService(Ref ref)`; `@Riverpod(keepAlive:true) MetadataBackend activeMetadataBackend(Ref ref)` → `remoteConfigService.current().backend`. **Scope note (Decision D3 — resolved, no churn):** the M0 provider is named `activeMetadataBackendProvider` and returns the **backend enum**. M1 (#9–#11) introduces a **separate, fresh** `activeMetadataSourceProvider` returning a `MetadataSource` instance — so there's no rename/retype of an existing provider, just an additive one. (CLAUDE.md refers to `activeMetadataSourceProvider` selecting the source at runtime; that's the M1 provider — the M0 enum provider is its input.)
6. `main.dart` (#5 revision) — after building the container, `unawaited(container.read(remoteConfigServiceProvider).refresh())` **after** `runApp` scheduling (or fire-and-forget pre-`runApp` with no `await`). First paint uses `current()`. Keep zero throwing `await` before `runApp`.

**Tests (alongside, adversarial):**
- `remote_config_service_test.dart` with `package:http/testing.dart` MockClient:
  - **Offline:** MockClient throws / times out → `current()` still returns the baked-in (or previously-cached) key; `refresh()` does **not** rethrow (the `on Object` guard).
  - **Does not block boot:** a test that constructs the service and reads `current()` **without** awaiting `refresh()` returns immediately with defaults (proves synchronous path).
  - **Malformed remote JSON:** MockClient returns `{"backend": 123}` (wrong-typed) → `refresh()` swallows the `as`-cast `TypeError`, prefs/cache unchanged (structurally-valid-but-malformed input, per the gotcha).
  - **Round-trip:** valid remote JSON → prefs updated → next `current()` reflects it.

**Acceptance:** config loads without network on boot.
**Risk paths touched:** `**/remote_config*`, `**/main.dart` → checkpoint surface.

---

## Data model introduced this milestone (v1)

Only the **user-owned** tables (ADR-3), at their PRD-canonical shape; cache
tables are #13 (schema v2). Denormalized-progress *fields exist* now but their
maintenance logic is #15/#19/#20.

- `LibraryItems` — see PRD §Data model (id PK; mediaType; tmdb/tvdb/imdbId; recordedSource; title/year/posterPath; genresCsv/runtimeMinutes snapshots; trackStatus; showStatus; episodeCountTotal/watchedCount/lastWatched*; rating/ratedAt; addedAt/updatedAt; relinkFailed). Unique idx `(mediaType,tmdbId)`,`(mediaType,tvdbId)`,`imdbId`; idx `trackStatus`.
- `WatchEvents` — id PK; `libraryItemId` FK→LibraryItems; season/episodeNumber (both null = movie, aired order); watchedAt?; runtimeMinutes? snapshot; isRewatch default false. Idx `(libraryItemId,season,episode)`; idx `watchedAt`.

## Cross-cutting testing strategy

- **TDD where it pays:** write the DAO round-trip + FK test (#3), the redirect
  test (#4), and the RemoteConfig offline/malformed tests (#5) from "what does a
  regression look like?" — FK-off, redirect-loop, unguarded-await-throws.
- **In-memory DB only** in tests (`NativeDatabase.memory()`), never the real file.
- **MockClient** (`package:http/testing.dart`) for all RemoteConfig HTTP; inject
  `Clock`. No live network in unit tests.
- **`just check`** (codegen → analyze → format-check → test) is the per-issue
  local gate; the PR `check` job is the milestone gate.
- **Real-artifact smoke (Definition of Done):** after #4/#5, an emulator smoke via
  the `android-emulator` skill — app boots to onboarding → home, theme applied,
  no boot loop offline. Advisory for autopilot; recorded, human verifies.

## Sequencing, branch & PR

Order #1 → #2 → #3 → #4 → #5 (lowest-first; each unblocks the next: #1 gives the
buildable app, #2 the gate, #3 the DB the later screens need, #4 the shell, #5
the config). One commit per issue: `chore(scaffold): … (#1)`, `chore(ci): … (#2)`,
`feat(db): … (#3)`, `feat(theme): … (#4)`, `feat(config): … (#5)`. Commit as
`Stuart Bradley <stuy.bradley@gmail.com>` via `-c` (not co-authored). Draft PR
opened at `start`; `finalize` runs `/deviations` + dialectic-pr-review +
riskflag, posts advisory triage, marks ready. **Never merge.**

## Risks & invariants

- **Boot-loop invariant** (#4/#5, `main.dart`): no throwing `await` before
  `runApp`; RemoteConfig refresh is fire-and-forget `try { } on Object { }`.
  `SharedPreferences.getInstance()` await is local-only (acceptable) but the
  restore/parse paths that *could* throw are all M4 — none added here.
- **Two-domains invariant** (#3): user tables only this milestone; cache tables
  are physically separate (#13) and excluded from export/backup (#30/#32/#33).
- **Risk-path surfaces touched:** signing (#1), CI (#2), database + `*.g.dart`
  (#3), `main.dart` (#1/#4/#5), `remote_config*` (#5) → the PR **will** trip
  `riskflag.sh`; `finalize` adds `needs-human` and a triage comment. Expected.
- **Flutter version drift:** CI pins 3.44.0; local is 3.44.0 — matched.
- **Metadata provider (D3, resolved):** M0 ships `activeMetadataBackendProvider`
  (enum); M1 adds a **separate** `activeMetadataSourceProvider` (`MetadataSource`)
  — additive, no retype of an existing provider.
- **Secrets shape (D4):** baked-in defaults parse the committed **nested**
  `secrets.json` (`tmdb.apiKey`/`tmdb.apiReadAccessToken`/`tvdb.apiKey`) at
  runtime — a flat `String.fromEnvironment('TMDB_API_KEY')` would silently
  resolve empty. Unit-tested. `RemoteConfig` carries both v3 key + v4 bearer.
- **Fonts (D6):** `allowRuntimeFetching = false` enforces the no-rogue-network
  invariant now; bundling the real `.ttf` families is a flagged follow-up
  (needs the font assets). Until then the platform fallback renders.

## Unresolved questions (for the human — concise)

1. **D1** — OK to land `LibraryItems`+`WatchEvents` table defs in #3, or keep #3 to a placeholder table and defer both to #15?
2. **D2** — release `scripts/*.sh` (`release-sign`/`release-deploy`) deferred to #38 (`needs-human`); M0 justfile references them but only `check` runs. OK?
3. **D3** *(resolved)* — M0 = `activeMetadataBackendProvider` (enum); M1 adds a fresh `activeMetadataSourceProvider`. Additive, no churn. Confirm?
4. **RemoteConfig URL** — what's the hosted JSON URL (GitHub Pages/raw)? Until set, refresh 404s and degrades to baked-in (safe). Provide or confirm placeholder.
5. **DynamicColor/Material You** — skip in M0 (fixed Honey theme), add in #35/#36? Or wire `DynamicColorBuilder` now?
6. **D4 — secrets shape** *(resolved to the committed contract)* — baked-in defaults parse the **nested** `secrets.json` (`activeSource` + `tmdb.{apiKey,apiReadAccessToken}` + `tvdb.apiKey`) via runtime `jsonDecode` of the JSON-string defines; CI ships empty (tests inject). Confirm the nested shape is the intended contract (vs flattening the file)?
7. **D6 — font bundling** — M0 sets `allowRuntimeFetching = false` (no font network call, platform fallback). Bundle Newsreader + Manrope `.ttf` as assets now (needs the files) or defer to a follow-up issue?
