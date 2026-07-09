# Milestone M5 — Stats, polish & release · implementation plan

GitHub milestone **#6** ("M5 — Stats, polish & release"), branch **`auto/m6`**.
Covers every open, actionable issue: **#34, #35, #36**. (**#37** ASO listing and
**#38** Play internal dry-run are labelled `needs-human` — autopilot skips them;
they stay open for a human.) Advisory autopilot plan — a human merges.

## 0. Branch base (deviation — read first)

`origin/main` still has **zero Dart source**. M0–M4 live unmerged on the stack
`origin/auto/m1` → `auto/m2` → `auto/m3` → `auto/m4` → `auto/m5` (PRs
#42/#43/#44/#46/#49, all open). Branching `auto/m6` from `origin/main` per the
literal autopilot recipe would leave no `pubspec.yaml`, no Drift DB, no
`LibraryDao` — #34 could not compile.

**Decision:** `auto/m6` is branched from **`origin/auto/m5`**, exactly as m5
stacked on m4, m4 on m3, and so on. The PR targets `main` (matching #42–#49), so
its diff shows the whole stack until a human merges m1→m6 in order.

## 1. What already exists (do NOT rebuild)

- **DB, schema v2.** `LibraryItems`, `WatchEvents` (user domain, precious) +
  `CachedMedia`, `CachedEpisodes` (disposable). **M5 adds no tables and no
  columns — `schemaVersion` stays 2, no new migration.** (Risk-path note: no
  migration ⇒ no migration review needed.)
- **The stats facts are snapshotted onto the user tables** (that was the point of
  the invariant): `WatchEvents.runtimeMinutes` + `watchedAt`;
  `LibraryItems.genresCsv` / `year` / `runtimeMinutes` / `mediaType`. #34 is a
  **strictly read-only feature over user tables** — it adds no writes and must
  not touch the cache.
  **But the snapshot is only complete for titles added via search.** Rows created
  by an **import** carry `year` and `title` and nothing else: `merge_applier
  .dart:137-155` inserts no `runtimeMinutes` and no `genresCsv` (the `Resolver`
  returns a `MediaSearchResult`, which has neither field), and
  `merge_applier.dart:278-283` deliberately writes a null `runtimeMinutes` onto
  every imported `WatchEvent`. See §5.1 — this is a **documented decision, not a
  bug**, and #34 must surface it honestly rather than "fix" it.
- **`LibraryDao`** — `getAll`, `watchLibrary`, `watchEventsFor`, `markWatched`,
  `markManyWatched`, `logRewatch`, `unwatch`, `recomputeDenormalized`,
  `deleteAllUserData`, `hasAnyItems`, `transaction`. M5 adds exactly **one**
  read method (§5.1).
- **`ImportExportService`** (#30) — `exportJson()`, `exportLetterboxdCsv()`,
  `restore(json)`; `AutoBackupService` (#32) — `snapshot()`, `restoreIfEmpty()`.
  #35's Settings screen **calls these**; it writes no new serialization.
- **Theme is already lifted** (#36 is *partly* done): `lib/core/theme/
  watchnook_theme.dart` + `watchnook_tokens.dart` exist, Honey · gold, Newsreader
  + Manrope via `google_fonts` (already a dep), wired into `MaterialApp.router`.
  What is **missing** is listed in §7.
- **`clock`** is the injected time source. `DateTime.now()` is banned — the
  streak calculation (§5.2) reads `clock.now()`, so a test can pin "today".
- **`file_selector`** is already a dep (used by the import picker) —
  `getSaveLocation()` covers "export to a file" with **no new dependency**.
- **`dart_test.yaml`** pins a 60s per-test timeout (hang-guard).
- **Widget-test hazard (CLAUDE.md):** a screen backed by a live Drift `.watch()`
  stream hangs `pumpAndSettle()`. Every widget test below overrides its
  DB-backed provider with `Stream.value(...)` / a fixed value.

## 2. Requirements → user stories (acceptance criteria)

| # | User story | Issue | Acceptance |
|---|---|---|---|
| US-12 | As a data nerd, I see episodes/hours/genre/decade **and a streak**, so I can enjoy my own history. | #34 | Figures survive a cache eviction. |
| US-12a | As a user with a wiped cache (offline, TTL-evicted, fresh restore), my stats are unchanged, so I trust the numbers. | #34 | `deleteAllCache()` in a test leaves every figure identical. |
| US-12b | As a user whose library came from an import, I'm told *why* my hours and genres are empty, so I don't think the app is broken. | #34 | A null-runtime event renders the footnote; a fully in-app library does not. |
| US-13 | As a first-run user, I see a welcoming empty library that tells me what to do next, so I'm not staring at a void. | #35 | Every list/grid screen has a distinct empty state. |
| US-14 | As a user, I open **Settings** from the top bar to export my data, back it up, choose light/dark, and read the metadata attribution, so I own and understand my data. | #35 | Export JSON + Letterboxd CSV write a file the user picked; theme choice persists across restart. |
| US-15 | As a user, the app looks like the delivered "Honey · gold" design on a device with no network, so typography and artwork placeholders are never a downgrade. | #36 | `PosterPlaceholder` shared; fonts render offline; no `withOpacity`. |

## 3. Architecture decisions

- **AD-M5-1 — Stats aggregate in Dart, not SQL.** One `LibraryDao.watchStats()`
  returning a `Stream<StatsSnapshot>` off a single `join(watchEvents,
  libraryItems)` `.watch()`, folded in Dart. A personal library is hundreds — low
  thousands of rows; four GROUP BYs in SQL buy nothing and cost readability and
  three more `.watch()` streams to keep in sync.
  `// ponytail: in-Dart fold over a single join; move to SQL GROUP BY if a
  10k-event library measurably lags.`
- **AD-M5-2 — `StatsSnapshot` is a plain immutable class in `domain/`,** derived
  by a **pure function** `statsFrom(rows, now)`. All of #34's logic (streak,
  decade bucketing, genre splitting) is unit-tested with zero DB and zero widget
  tree. The DAO does I/O; the function does arithmetic.
- **AD-M5-3 — Stats reads user tables only.** The DAO query joins
  `WatchEvents` → `LibraryItems`. It never mentions `CachedMedia` /
  `CachedEpisodes`. This is the same shape as the `ExportData` invariant, and
  gets the same regression test (§6, T3).
- **AD-M5-4 — Theme mode is a SharedPreferences-backed `@riverpod` notifier**
  (`themeModeProvider`), mirroring `OnboardingSeen`. `main.dart` reads it via
  `ref.watch`; the current hardcoded `themeMode: ThemeMode.dark` becomes the
  **default value**, not a constant. Not in `ExportData` (prefs never export).
- **AD-M5-5 — Stats is the third bottom-nav tab** (`/stats`), not a Settings
  sub-page: it's a browse destination, and the design's `stats_screen` has its
  own `AppBar`. Settings is a **pushed** route (`/settings`) off the shell app
  bar, per the locked design ("settings in top bar"). The existing Import icon
  moves **into** Settings (its `ponytail:` comment in `app_router.dart` says to
  do exactly this once Settings lands).
- **AD-M5-6 — "Dynamic" appearance is out of scope.** The design mockup offers
  System / Light / Dark / Dynamic. Material You dynamic colour needs
  `dynamic_color` (a new dep) and a device to verify. Ship **System / Light /
  Dark**; file a follow-up issue for Dynamic.
  `// ponytail: three modes; dynamic_color is a dep + a device test, file it.`

## 4. Data model

**No schema change. `schemaVersion` stays 2. No migration.**

New pure-Dart type only (`lib/features/stats/domain/stats_snapshot.dart`):

```dart
class StatsSnapshot {
  final int episodesWatched;   // non-rewatch tv WatchEvents
  final int moviesWatched;     // non-rewatch movie WatchEvents
  final int rewatches;         // isRewatch == true
  final Duration timeWatched;  // sum of runtime, rewatches INCLUDED
  final int streakDays;        // consecutive local days ending today|yesterday
  final List<StatBucket> byGenre;   // desc by count, from LibraryItems.genresCsv
  final List<StatBucket> byDecade;  // desc by decade, from LibraryItems.year
  bool get isEmpty => episodesWatched == 0 && moviesWatched == 0;
}
class StatBucket { final String label; final int count; }
```

**Counting rules (pin these; they are the test contract):**
- `episodesWatched` / `moviesWatched` count **non-rewatch** rows (the idempotent
  marker) — consistent with `LibraryItems.watchedCount`.
- `timeWatched` **includes rewatches** — you really did watch those hours.
- Runtime per event: `event.runtimeMinutes ?? item.runtimeMinutes ?? 0`. The
  fallback matters (§5.1); a null runtime contributes zero, never crashes.
- `byGenre` counts **watch events**, not titles, splitting `genresCsv` on `,`;
  a 3-genre title's episode adds 1 to each of its 3 genres. Rows with a null
  `genresCsv` are omitted (no "Unknown" bucket).
- `byDecade` buckets on `LibraryItems.year` → `year - year % 10` → `"2010s"`.
  Null year omitted.
- **Streak** = consecutive **local calendar days**, walking back from
  `clock.now()`'s day, on which ≥1 event has a non-null `watchedAt`. If today has
  no event but yesterday does, the streak still counts (grace: you haven't
  watched *yet* today). Events with `watchedAt == null` (imported, date unknown)
  never contribute. **Rewatches DO extend the streak** — they are watch events
  with a date, and the streak measures "did you watch something", not "did you
  make progress". Bucket by local `(year, month, day)` after `toLocal()` (DST-safe
  — never by `Duration` arithmetic on instants). Max lookback 366 days.

## 5. Issue #34 — Stats screen

### 5.1 The writer audit (do this **first** — it decides what #34 can honestly show)

#34 is the first reader of `WatchEvents.runtimeMinutes` and of
`LibraryItems.genresCsv`. Per CLAUDE.md ("change which field a reader consumes
FROM ⇒ audit every WRITER"), here is **every** writer:

| Writer | `WatchEvents.runtimeMinutes` | `LibraryItems.runtimeMinutes` / `genresCsv` |
|---|---|---|
| `search_providers.dart:60-79` (add via search) | — | ✅ both, from `MediaDetails` |
| `detail_screen.dart:277` (mark movie) | ✅ `item.runtimeMinutes` | — |
| `detail_screen.dart:289` (log rewatch) | ✅ `item.runtimeMinutes` | — |
| `detail_screen.dart:547` (mark episode) | ✅ `episode.runtimeMinutes` | — |
| `bulk_mark.dart:58` → `markManyWatched` | ✅ `e.runtimeMinutes` per mark | — |
| `import_export_service.dart:151` (restore) | ✅ round-trips the stored value | ✅ round-trips |
| `merge_applier.dart:226/237/266` (**import**) | ❌ **always null** | ❌ **never set** (`:137-155`) |

**The import gap is a documented decision, not a bug.** `merge_applier.dart:
278-283` states it outright: *"an export knows what you watched, never how long
it ran. Imported history therefore contributes to watch counts but not to watch
time — the stats invariant forbids back-filling it from the disposable cache."*
The `Resolver` returns a `MediaSearchResult` (`metadata_models.dart:38-94`),
which carries neither runtime nor genres, so there is nothing to snapshot at
import time without a new `MediaDetails` fetch.

**Consequence for #34, stated plainly:** a library populated *only* by import
shows real **counts**, a real **decade** breakdown (`year` **is** imported,
`merge_applier.dart:134`), **zero hours**, and an **empty genre** breakdown.

**Decision — #34 stays read-only and tells the truth:**

1. **Do NOT touch `merge_applier`.** Snapshotting `item.runtimeMinutes` onto the
   event at import time would write `null` onto `null` (the item has no runtime
   either) — a no-op that churns M3 code for nothing. The earlier draft of this
   plan called this a "two-line fix"; it was neither.
2. **Coalesce in the reader:** `event.runtimeMinutes ?? item.runtimeMinutes ?? 0`.
   This is not a fix for the import case (both are null there) — it correctly
   handles the **mixed** case: a title added via search (so the item *does* carry
   a runtime) whose episodes were later marked by an import. Cheap, defensive,
   read-only.
3. **UI honesty (one line of copy, no logic):** the Hours and By-genre cards
   carry a footnote — *"Counts titles watched in the app; imported history has no
   runtime or genre data."* — rendered **only when** some watch event has a null
   runtime. A user must never conclude the numbers are broken.
   `// ponytail: a footnote, not a backfill. Enrichment is its own issue.`
4. **File a follow-up issue** (M6 backlog, not this milestone): *"Snapshot
   runtime + genres on import by resolving `MediaDetails`."* That is a real
   change — network during import, touches `Resolver` and `MergeApplier`, needs
   its own offline/rate-limit story. Out of scope for #34's issue body.

Document the reader-side rule in `.claude/CLAUDE.md`, extending the
stats-snapshot bullet: *"stats coalesce `WatchEvents.runtimeMinutes` to the
item's runtime, then to zero; imported events legitimately carry neither, so
counts and decades are complete for imports while hours and genres are not —
never back-fill either from the cache."*

### 5.2 Implementation

- `lib/features/stats/domain/stats_snapshot.dart` — the class + pure
  `StatsSnapshot statsFrom(Iterable<(WatchEvent, LibraryItem)> rows, DateTime now)`.
- `lib/core/database/library_dao.dart` — add
  `Stream<List<(WatchEvent, LibraryItem)>> watchAllEvents()` (one join, user
  tables only). Nothing else.
- `lib/features/stats/presentation/stats_providers.dart` — a plain
  `StreamProvider<StatsSnapshot>` (**not** `@riverpod`: it maps Drift-generated
  rows — CLAUDE.md's `InvalidTypeException` rule) mapping `watchAllEvents()`
  through `statsFrom(..., clock.now())`.
- `lib/features/stats/presentation/stats_screen.dart` — port the delivered
  mockup (`docs/design/flutter/lib/features/stats/stats_screen.dart`): two
  `_StatCard`s (Episodes, Watched-hours), the streak card, `_Bar` rows for genre
  and decade. Replace its placeholder constants with the provider; keep its
  widgets/spacing verbatim. Bars are normalized `count / maxCount`.
- Empty state: no watch events → "No stats yet — mark something watched." (shares
  the `_EmptyState` widget from #35; #34 lands first, so #34 introduces the
  widget in `lib/core/widgets/empty_state.dart` and #35 reuses it).
- Router (`app_router.dart`): third `StatefulShellBranch` → `/stats`,
  `Icons.insights_outlined` / `Icons.insights`.

### 5.3 Tests (alongside — TDD; write T1/T2 before `statsFrom` exists)

- **T1 `test/features/stats/stats_snapshot_test.dart`** (pure, no DB): counts
  split rewatch vs not; hours include rewatches; hours use the item fallback when
  the event's runtime is null; **both null → contributes 0, does not throw**;
  genre splitting of `"Drama,Sci-Fi"`; decade bucketing (`1999 → "1990s"`,
  `2000 → "2000s"`); null year/genre omitted.
- **T2 streak table-test** (pinned `now`): 0 events → 0; today only → 1;
  today+yesterday → 2; yesterday only (no today) → 1 (grace); a gap of one day
  breaks it; two events on the same day count once; a **rewatch** extends it;
  `watchedAt == null` ignored; events *in the future* don't extend it; a 400-day
  chain caps the walk.
  **Timezone hardening:** pinning `now` through `clock` is *not* sufficient — a
  fixture built as `now.subtract(Duration(days: n))` near midnight lands in a
  different local day depending on the CI box's UTC offset. Build every fixture
  as an **explicit local `DateTime(2026, 7, 8, 12)`** (local midday) and pin `now`
  to a local midday too, so no fixture is within 12h of a day boundary in any
  zone. Add one case asserting a `watchedAt` stored in UTC at `23:00Z` buckets by
  its **local** day.
- **T3 `test/features/stats/stats_cache_eviction_test.dart` — the acceptance
  criterion, adversarial:** in-memory DB → add items + mark watched → snapshot
  stats → `delete(cachedMedia).go()` + `delete(cachedEpisodes).go()` → assert the
  snapshot is **identical**. This fails loudly the day someone "optimizes"
  `watchAllEvents()` into a cache join.
- **T4 import→stats characterization test (pins §5.1's *documented* behaviour):**
  run `MergeApplier` over a TV Time fixture, then assert **all four** at once —
  `episodesWatched > 0`, `byDecade` is **non-empty** (`year` is imported),
  `timeWatched == Duration.zero`, and `byGenre` is **empty**. Comment it with the
  `merge_applier.dart:278-283` citation. This is deliberately a *characterization*
  test, not an aspiration: it documents the seam, and it is the test that will go
  red — correctly — the day the enrichment follow-up lands, forcing whoever does
  it to update the contract in one place.
- **T5 widget** `stats_screen_test.dart`: override the `StreamProvider` with
  `Stream.value(snapshot)` (**never** the real DB); assert the two stat cards,
  the streak line, and the genre/decade bar labels render; that the empty
  snapshot renders the empty state, not a `0 h` card; and that the §5.1(3)
  footnote appears **only** when a null-runtime event is present.

**Commit:** `feat(stats): stats screen — counts, hours, genre/decade, streak (#34)`

## 6. Issue #35 — Onboarding + empty states + settings

### 6.1 Settings (`lib/features/settings/presentation/settings_screen.dart`)

Pushed route `/settings`; entry = a gear `IconButton` in `_ShellScaffold`'s app
bar. **Remove** the Import icon from the app bar (its own `ponytail:` comment
instructs this); Import becomes a Settings row.

Sections (porting the delivered `settings_screen` mockup):
- **Appearance** — `SegmentedButton<ThemeMode>`: System / Light / Dark (AD-M5-6).
- **Your data** — `Import…` → `context.push('/import')`; `Export JSON` and
  `Export Letterboxd CSV` → `ImportExportService`, written via
  `file_selector`'s `getSaveLocation()`; `Back up now` → `AutoBackupService
  .snapshot()` with a `SnackBar` confirmation.
- **About** — app name + version (`package_info_plus`? **no** — read the version
  from a `const` in code; a new dep for one string is not worth it.
  `// ponytail: hardcoded version string, swap for package_info_plus if it drifts`),
  the "no account, no cloud, no ads" line, and the **mandatory** per-source
  attribution — reuse `_AttributionFooter` from `detail_screen.dart` by promoting
  it to `lib/core/widgets/attribution_footer.dart` (it already reads
  `attribution()` off the active source, so it flips with the backend).

Async gaps: every `await` before a `SnackBar`/`context` use is guarded with
`if (!context.mounted) return;` (CLAUDE.md).

Failures surface as a `SnackBar` — a cancelled save-dialog (`null` location) is a
silent no-op, not an error.

### 6.2 Theme mode

`lib/features/settings/data/theme_mode_provider.dart` — `@riverpod class
AppThemeMode` over `sharedPreferencesProvider`, key `'theme_mode'`, storing the
enum **name** (`'system'|'light'|'dark'`), defaulting to `dark` (today's
hardcoded value). `main.dart`: `themeMode: ref.watch(appThemeModeProvider)`.
Unknown/corrupt stored value → default, never throw.

### 6.3 Empty states

`lib/core/widgets/empty_state.dart` (introduced in #34) — icon + headline + body
+ optional action. Applied to:
- **Library grid** (no items): "Your library is empty" → `Search` / `Import` CTAs.
- **Library grid** (filter yields nothing): "Nothing matches this filter" — a
  *different* string; an empty filter result is not an empty library.
- **Up Next** (no tracked shows / nothing airing) — two distinct strings.
- **Search** (query typed, no results) — the existing branch, restyled.
- **Stats** (no watch events) — from #34.

### 6.4 Onboarding polish

Keep the single welcome page (no carousel — YAGNI). Add: the three value props
(track · offline · yours) and a secondary "I have data to import" button →
`markSeen()` then `context.push('/import')`. Verify the restore path still
pre-sets `onboardingSeenKey` before first paint (#32) — a restored user never
sees this screen.

### 6.5 Tests

- **T6 `theme_mode_provider_test.dart`:** default is `dark` with empty prefs;
  `set(light)` persists `'light'`; a garbage stored value (`'purple'`) falls back
  to `dark` and does not throw (adversarial — the `as`-cast/enum-lookup trap).
- **T7 `settings_screen_test.dart`:** override prefs + `ImportExportService` with
  a fake; tapping `Export JSON` calls `exportJson()` exactly once; a **cancelled**
  save location writes nothing and shows no error; the attribution footer renders
  the active source's credit; segmented button reflects and updates the mode.
- **T8 `empty_states_test.dart`:** for each screen, override its DB-backed
  provider with `Stream.value(const [])` and assert the specific empty copy —
  and, for the library, that "empty library" and "empty filter result" render
  **different** strings (adversarial: the easy bug is one shared message).
- **T9 `onboarding_screen_test.dart`** (extend): "I have data to import" marks
  seen **and** routes to `/import`.
- Router test: `/settings` and `/stats` resolve; `smoke_test` still stubs
  `libraryGridProvider` (and now the stats provider) or it hangs (CLAUDE.md).

**Commit:** `feat(polish): settings, empty states, onboarding (#35)`

## 7. Issue #36 — Apply the delivered design system

Already done in earlier milestones: `watchnook_theme.dart`, `watchnook_tokens
.dart`, `google_fonts` dep, `MaterialApp` wiring. **Remaining:**

1. **`PosterPlaceholder` + `TypeBadge`** → `lib/core/widgets/poster_placeholder
   .dart` (lifted from `docs/design/flutter/lib/core/widgets/`). Delete the two
   private `_PosterPlaceholder` copies in `library_screen.dart:244` and
   `search_screen.dart:187`; both call sites take `width`/`height` + a `tag`.
2. **`withOpacity` → `withValues(alpha:)`** across `lib/` (deprecated ≥ Flutter
   3.27). `grep -rn 'withOpacity' lib/` must return nothing.
3. **Bundle the fonts.** `watchnook_theme.dart` sets
   `GoogleFonts.config.allowRuntimeFetching = false` and the families are *not*
   bundled — so today the app silently renders Roboto and the design is **not
   applied**. Add `assets/fonts/` (Newsreader + Manrope static `.ttf`, OFL —
   include `OFL.txt`), declare them in `pubspec.yaml`'s `fonts:` so `google_fonts`
   resolves them locally.
   **Fallback if the `.ttf` files cannot be fetched in the sandbox:** do *not*
   fake it — leave the platform fallback, and open a `needs-human` follow-up
   issue "bundle Newsreader + Manrope". A silently-wrong font is worse than a
   tracked gap.
4. **Sweep the screens against the mockups** for spacing/token drift, using
   `WatchnookSpacing` / `WatchnookTokens` rather than magic numbers. Do **not**
   lift the mockup screens (they are `setState` + placeholder data).

### 7.1 Tests

- **T10 `poster_placeholder_test.dart`:** renders at the requested size; the
  `tag` renders a `TypeBadge`; a null tag renders none.
- **T11 lint-as-test** `test/design_tokens_test.dart`: reads `lib/**.dart` and
  asserts zero `withOpacity(` occurrences. Cheap, and it stays true.
- Golden tests: **skipped** (font-dependent goldens are flaky in CI without
  bundled fonts and a pinned renderer).
  `// ponytail: no goldens; add once fonts are bundled and CI pins skia.`
- Re-run the existing widget suites — swapping in a shared `PosterPlaceholder`
  changes the widget tree; any finder keyed on `_PosterPlaceholder` must be
  updated, not deleted.

**Commit:** `feat(design): shared poster placeholder, bundled fonts, token sweep (#36)`

## 8. Testing strategy (summary)

| Layer | What | Where |
|---|---|---|
| Pure unit | `statsFrom` counts/hours/genre/decade; streak table-test | T1, T2 |
| DB integration | cache-eviction invariance (in-memory DB) | T3 |
| Characterization | import → counts + decades, but zero hours / no genres (§5.1) | T4 |
| Unit | theme-mode persistence + corrupt-value fallback | T6 |
| Widget | stats, settings, empty states, onboarding (all providers overridden) | T5, T7, T8, T9 |
| Widget | shared poster placeholder | T10 |
| Static | no `withOpacity` in `lib/` | T11 |
| Manual | emulator smoke: nav to Stats + Settings, toggle theme, export a file | §9 |

Every test runs under the 60s `dart_test.yaml` cap. No screen test mounts a live
Drift `.watch()` stream.

## 9. Definition of done (beyond `just check`)

`just check` green is necessary, not sufficient. #35 and #36 touch surfaces tests
cannot reach — **file writing** (`file_selector` → a real save dialog), **font
rendering**, **theme persistence across a process restart**, and **image
placeholders**. Before finalize, run the `android-emulator` skill: boot, tap
through Library → Stats → Settings, toggle Light/Dark, kill and relaunch the app
(theme must persist), export a JSON file and `adb shell cat` it, and confirm the
poster placeholders render. Capture the outcome in the PR triage comment.

## 10. Sequencing & risks

1. **#34** — first: it introduces `lib/core/widgets/empty_state.dart` that #35
   consumes. It touches **no** existing write path (§5.1) — it is additive:
   one DAO read method, one domain file, one screen, one router branch.
2. **#35** — depends on #34's `EmptyState`; promotes `_AttributionFooter` out of
   `detail_screen`.
3. **#36** — last: it rewrites the poster widget used by the screens #35 just
   touched; doing it first would mean editing the same call sites twice.

**Risks**
- *Font bundling needs a network fetch of `.ttf`s in a sandbox.* Mitigated by the
  explicit §7.3 fallback (a tracked `needs-human` issue, never a silent fake).
- *Streak is timezone-sensitive.* `watchedAt` is stored UTC; the streak buckets on
  **local** calendar `(y,m,d)` via `toLocal()`. Pinning `now` through `clock` is
  **not** enough on its own — see T2's fixture rule (explicit local middays), or
  the test flakes on a CI box in another zone.
- *Stats under-report for imported libraries, by design.* The numbers are correct
  but incomplete (§5.1); the mitigation is the UI footnote + T4, not a backfill.
  If a human decides that's unacceptable, the enrichment follow-up — not this
  milestone — is where it belongs.
- *Three nav tabs + a pushed Settings changes the shell.* `smoke_test` and the
  routing tests must stub the stats provider or they hang (CLAUDE.md).

**Not in scope (file follow-ups):** import enrichment — snapshot runtime/genres
by resolving `MediaDetails` (§5.1(4)); Material You dynamic colour (AD-M5-6);
golden tests (§7.1); `package_info_plus` (§6.1); #37 and #38 (`needs-human`).
