# Milestone M3 — Import · implementation plan

GitHub milestone **#4** ("M3 — Import"), branch **`auto/m4`**. Covers every open
issue: **#23–#29**. Advisory autopilot plan — a human merges.

## 0. Branch base (deviation — read first)

`origin/main` still has **zero Dart source** (4 commits, M0 docs/CI scaffold
only). M0+M1+M2 live unmerged on `origin/auto/m1` → `auto/m2` → `auto/m3` (PRs
#42/#43/#44, all open). Branching `auto/m4` from `origin/main` per the literal
autopilot recipe would leave no `pubspec.yaml`, no Drift DB, no `LibraryDao`, no
`MetadataSource` — M3 could not compile.

**Decision:** `auto/m4` is branched from **`origin/auto/m3`**, exactly as `m3`
stacked on `m2` and `m2` on `m1`. The PR targets `main` (matching #42–#44), so
its diff shows the whole stack until a human merges m1→m2→m3 in order.

## 1. What already exists (do NOT rebuild)

- **DB, schema v2** (`lib/core/database/`): `LibraryItems`, `WatchEvents` (user
  domain) + `CachedMedia`, `CachedEpisodes` (disposable). **M3 adds no tables
  and no columns — `schemaVersion` stays 2, no new migration.**
- **`LibraryDao`** — everything the applier needs already exists and is already
  idempotent: `findByIdentity` (imdb → (type,tmdb) → (type,tvdb) → title+year —
  *this is the ADR-5 id-block cascade*), `addOrGetItem`, `updateItem`,
  `markWatched`, `markManyWatched`, `logRewatch`, `watchEventsFor`,
  `recomputeDenormalized`.
- **Metadata** — `MetadataSource` (`search`, `resolveByExternalId(imdbId)`,
  `movieDetails`, `showDetails`, …), `TmdbSource`, `TvdbSource`,
  `CachingMetadataRepository`, `activeMetadataSourceProvider`.
- **Fixtures** — all four real/synthesized exports plus `test/fixtures/malformed/`
  (one per source) are committed. `test/fixtures/README.md` documents the shapes,
  the deliberate cross-source overlaps, and the edge cases.
- **CI** — `.github/workflows/e2e.yml` self-gates on `integration_test/*.dart`
  existing; adding the patrol test in #29 switches E2E on.

**Nothing in M3 needs a new DAO method.** The applier composes existing ones.

## 2. Requirements → user stories (acceptance criteria)

| Req | User story | Issue(s) |
|-----|-----------|----------|
| R7 Import | **US-8** As a TV Time refugee, I import my GDPR export so my shows + watched episodes arrive intact | #24, #23 |
| R7 Import | **US-9** As a Trakt/IMDb user, I import a clean-ID export and every title auto-matches without prompts | #25, #26 |
| R7 Import | **US-10** As a Letterboxd user, I import diary + ratings and confirm the handful of ambiguous films | #27, #28 |
| R7 Import | **US-11** As a user who imports twice, my history is merged, never duplicated or wiped | #23, #29 |
| R7 Import | **US-12** As a user mid-import, I see progress and can confirm/skip fuzzy matches | #28 |
| R10 Offline-first | **US-13** As an offline user, import still lands my rows (ids carried from the file; artwork fills in later) | #23 |

## 3. Architecture decisions

**AD-1 — Pipeline, per ADR-5.** `ImportArchive` → `Importer.parse` →
`List<ImportRecord>` → `Resolver` → `List<ResolvedRecord>` (+ ambiguous queue) →
`MergeApplier` → `ImportSummary`. `ImportService` orchestrates and emits progress.
Each stage is pure/injectable, so unit tests never touch the network or a picker.

**AD-2 — `ImportRecord` mirrors the DB, not the source.** One record = one title:
id-block (`imdbId`/`tmdbId`/`tvdbId`), `mediaType`, `title`, `year`, optional
`trackStatus`, `rating`, `ratedAt`, and `watches: List<ImportWatch>` where
`ImportWatch(season?, episode?, watchedAt?, isRewatch)` — both coordinates null =
a movie, matching `WatchEvents` 1:1. Importers do source-specific parsing and
nothing else; the resolver and applier never learn which source a record came from.

**AD-3 — Resolver strategy (cheapest rung that resolves).**
1. `imdbId != null` → `resolveByExternalId(imdbId)` → auto.
2. else id in the **active** source's namespace (`tmdbId` on TMDB / `tvdbId` on
   TVDB) → auto, **no network call**; title/year carried from the record.
3. else `search(title, kind)` → *confident* iff exactly one candidate has a
   normalized-title exact match **and** (`|year delta| <= 1` or the record has no
   year). One confident hit → auto; otherwise → **ambiguous**, top-5 candidates
   into the confirmation queue.
4. Any `MetadataException` (offline, 429, 5xx) → `unresolved`: the record is
   **still applied** using the ids/title it already carries (US-13). Import must
   never fail because the metadata API is down. `posterPath` stays null and the
   SWR cache fills it on first view.

Normalization: lowercase, strip diacritics, collapse non-alphanumerics to single
spaces, trim. (`Shōgun` == `shogun`; `Battlestar Galactica (2003)` keeps its year.)

**AD-4 — `MergeApplier` is additive; it never deletes.** Per record, in one
transaction: `addOrGetItem` (dedupes via the `findByIdentity` id-block cascade) →
`updateItem` to **fill null columns only** (missing ids, year, rating,
`ratedAt`) → watch events. **Existing `trackStatus` and `rating` are never
overwritten** — an import is a merge of someone else's facts into the user's own,
and the user's own wins. Re-import is therefore a no-op on unchanged data.
- non-rewatch watches → `markManyWatched` (already idempotent per coordinate).
- rewatches → `logRewatch`, but **only the deficit**: `max(0, wanted − existing
  rewatch rows for that coordinate)`. Without this, `plays: 3` re-appends two
  rewatch rows on every re-import. This is the sharpest re-import regression and
  gets a dedicated test.

**AD-5 — Only one network dependency stays.** Letterboxd's "URI resolve" is
**slug parsing** (`/film/blade-runner-2049/` → title + year hint), *not* an HTTP
fetch of letterboxd.com. Per CLAUDE.md, the metadata API is the only network call.

**AD-6 — New dependencies (3).** `csv` (RFC-4180 quoting — `"Love, Death &
Robots"` is in the real fixture; hand-rolling this is a known trap), `archive`
(zip), `file_picker` (Android SAF, returns bytes). Dev-only: `patrol` +
`patrol_cli` pinned to matching versions (#29). Added with `flutter pub add` in
the issue that first needs them.

**AD-7 — Malformed input degrades, never throws.** No `as` casts on parsed data
(they raise `TypeError`, which `on Exception` will not catch — CLAUDE.md). CSV
rows with the wrong field count, or an unparseable id/rating, are **skipped with a
counted warning**; the rest of the file imports. Every importer test asserts
against `test/fixtures/malformed/` as well as the real fixture.

## 4. Data model

**No schema change.** New in-memory types only (`lib/core/import_export/import/`):

```dart
enum ImportSourceKind { tvTime, trakt, imdb, letterboxd }

class ImportWatch { final int? season, episode; final DateTime? watchedAt;
                    final bool isRewatch; }

class ImportRecord {
  final MediaType mediaType;                 // movie | tv
  final String title; final int? year;
  final String? imdbId; final int? tmdbId, tvdbId;
  final TrackStatus? trackStatus;            // null → applier defaults
  final int? rating;                         // 0–10, normalized by the importer
  final DateTime? ratedAt;
  final List<ImportWatch> watches;
}

sealed class Resolution { }                  // Auto(record, match?) | Ambiguous(record, candidates) | Unresolved(record, reason)

class ImportSummary { final int itemsAdded, itemsUpdated, watchEventsAdded,
                            rewatchesAdded, skippedRows, ambiguous; }

class ImportProgress { final ImportPhase phase; final int done, total; }
```

Rating normalization at the importer boundary: Letterboxd `0.5–5.0` → `×2` → 1–10;
IMDb/Trakt are already 1–10.

## 5. Issue-by-issue plan (TDD — test alongside, not after)

### #23 — Import core · `feat`
`import_archive.dart` (bytes → named entries; zip via `archive`, plain file = one
entry; `readText(suffix)` matches on basename so a ~80-file TV Time zip works),
`import_record.dart`, `resolver.dart`, `merge_applier.dart`, `import_service.dart`
(detect → parse → resolve → apply, emits `ImportProgress`), `csv_utils.dart`
(tolerant header→row maps; short/long rows skipped + counted).
- **Tests** (`test/core/import_export/`): zip vs plain detection; resolver picks
  each AD-3 rung (MockClient `MetadataSource` fake); confident-vs-ambiguous
  threshold incl. two same-title candidates → ambiguous; `MetadataException` →
  `Unresolved` and still applied; **merge:** apply → apply again ⇒ identical row
  counts (no dup items, no dup watch events, no dup rewatch rows), existing
  `rating`/`trackStatus` survive a conflicting re-import, and a pre-existing
  watch event is **never deleted**.
- **Acceptance:** clean-ID auto; ambiguous → confirmation queue.

### #24 — TV Time importer · `feat`
Reads the export by basename: `followed_tv_show.csv` (tvdb id + `archived`),
`user_tv_show_data.csv` (`nb_episodes_seen`), `seen_episode_source.csv` +
`seen_episode_latest.csv` (**union** — latest is a delta), `tracking-prod-records.csv`
(movies: `entity_type=movie`; `type=follow` → watchlist, `type=watch` → watched
with `watch_date`, `rewatch_count` → rewatches). TV = tvdb id (clean); movies are
internal UUIDs → title + `release_date` year → resolver rung 3.
Status map: `archived=1` → `completed`, else `watching` (a TV Time user archives
what they've finished). `0001-01-01` release dates → null year.
- **Tests:** real fixture (23 shows / ~300 episode rows / 10 movies) → expected
  record counts, `"Love, Death & Robots"` (quoted comma), `Shōgun` (unicode),
  `ONE PIECE (2023)`; duplicate movie rows collapse; **malformed** fixture
  (`tv_show_id = N/A`, truncated final row) → skipped-and-counted, no throw.
- **Acceptance:** sample TV Time imports.

### #25 — Trakt importer · `feat`
`watched.{movies,shows}` (episode-level, `plays > 1` → rewatch deficit),
`ratings.*`, `watchlist.*`. Full `ids` block → resolver rung 1/2.
- **Tests:** fixture → ids/episodes/ratings; **malformed** (`year: "unknown"`
  string, missing `ids`) → year null, falls back to title+year, no `TypeError`.
- **Acceptance:** clean-ID import.

### #26 — IMDb importer · `feat`
`imdb_ratings.csv` (`Const` = `tt…`, `Your Rating`, `Title Type`, `Year`,
`Runtime (mins)`, `Genres`, `Date Rated`) and `imdb_watchlist.csv`. `Title Type`
→ `movie` / `tv` (`tvEpisode`, `short` skipped). A rating implies watched:
movies get a watch event dated `Date Rated` + `completed`; shows get the rating +
`completed` but **no episode events** (IMDb exports none — never invent them).
- **Tests:** fixture; **malformed** (`Your Rating = good` → rating null; row
  missing `Const` → title+year path).
- **Acceptance:** ratings/watchlist import.

### #27 — Letterboxd importer · `feat`
`watched.csv`, `ratings.csv` (`×2`), `diary.csv` (`Watched Date`, `Rewatch=Yes` →
`isRewatch`), `watchlist.csv`. No ids → title+year, with the URI **slug** as a
year hint (AD-5). All four files merge into one record per film.
- **Tests:** fixture (diary rewatch → rewatch row; ratings scale); **malformed**
  (`Rating = great`, truncated row); *The Social Network* / *Parasite* resolve to
  the **same** item as the IMDb/Trakt fixtures (cross-source dedupe).
- **Acceptance:** diary/ratings import via confirmation.

### #28 — Import UI · `feat`
`lib/features/import/`: settings entry → pick file (`file_picker`) → progress →
confirmation list for ambiguous matches (candidate poster/title/year, pick or
skip) → summary. `AsyncNotifier` drives phases; **no** `setState`.
- **Tests:** widget test over the confirmation flow with `ImportService` faked via
  `ProviderScope` overrides. **Any DB-backed `StreamProvider` on screen is
  overridden with `Stream.value(...)`** — a live Drift `.watch()` never quiesces
  under `pumpAndSettle` (CLAUDE.md).
- **Acceptance:** ambiguous matches are confirmable.

### #29 — Patrol E2E · `test`
`integration_test/import_flow_test.dart`: import the TV Time fixture → library
populated → bulk-mark a season → **re-import the same file** → item count and
watch-event count unchanged, watched history intact. Adds `patrol` + pinned
`patrol_cli`; no `/` in the test name; generated bundle stays gitignored.
- **Scope deviation (flag):** the issue title says `… → export → reimport`, but
  **export does not exist until M4 #30/#31**. The export leg is therefore left as
  an explicit `TODO(#30)` and a follow-up issue is filed to extend this test when
  `ImportExportService` lands. Building an exporter here would scope-creep M4.
- **Acceptance:** end-to-end flow green (adding `integration_test/` un-gates the
  E2E workflow, so CI runs it on the PR).

## 6. Testing strategy

- **Unit** — every importer against **both** its real fixture and its malformed
  twin; resolver rungs incl. the offline path; applier idempotency (the US-11
  regression). In-memory Drift (`NativeDatabase.memory()`); `Clock` injected.
- **Adversarial, not confirmatory** — the tests that matter are *"what does a
  regression look like?"*: a second import duplicating rows; a rewatch count
  climbing on every import; an import overwriting the user's own rating; a
  `TypeError` escaping a malformed CSV; artwork-less rows silently dropped when
  the API is down. Each has a named test.
- **Widget** — #28's confirmation flow, DB providers overridden.
- **E2E** — #29 (patrol), CI-gated.
- **Bounded** — `dart_test.yaml`'s 60s per-test cap stays; no test may hang.
- **Real artifact** — `just check` is necessary, not sufficient: #28 (file picker
  = Android SAF) and #29 need an emulator smoke via the `android-emulator` skill
  before the PR is called done.

## 7. Order of work

`#23` (core, blocks all) → `#24` (hardest fixture, proves the core) → `#25` →
`#26` → `#27` (cross-source dedupe lands here) → `#28` (UI) → `#29` (E2E).

## 8. Risks

| Risk | Mitigation |
|---|---|
| Stacked branch (#0) never merged in order | PR body states the merge order m1→m2→m3→m4 |
| `file_picker` Android SAF can't be exercised by `flutter test` | emulator smoke before done; UI logic lives in the notifier, not the picker |
| Patrol/emulator unavailable in the autopilot step | write + commit the test; CI runs it; label `needs-human` if CI can't |
| TV Time `archived` semantics guessed | documented at the mapping site; only affects `trackStatus`, never watch history |
| Resolver's fuzzy threshold too loose → wrong title auto-matched | single-confident-hit rule; anything else goes to the human confirmation queue |
