# Milestone M4 — Export & backup · implementation plan

GitHub milestone **#5** ("M4 — Export & backup"), branch **`auto/m5`**. Covers
every open issue: **#30, #31, #32, #33**. Advisory autopilot plan — a human
merges.

## 0. Branch base (deviation — read first)

`origin/main` still has **zero Dart source** (`lib/` does not exist there). M0–M3
live unmerged on the stack `origin/auto/m1` → `auto/m2` → `auto/m3` → `auto/m4`
(PRs #42/#43/#44/#46, all open). Branching `auto/m5` from `origin/main` per the
literal autopilot recipe would leave no `pubspec.yaml`, no Drift DB, no
`LibraryDao` — M4 could not compile.

**Decision:** `auto/m5` is branched from **`origin/auto/m4`**, exactly as m4
stacked on m3, m3 on m2, m2 on m1. The PR targets `main` (matching #42–#46), so
its diff shows the whole stack until a human merges m1→m5 in order.

## 1. What already exists (do NOT rebuild)

- **DB, schema v2** (`lib/core/database/`): `LibraryItems`, `WatchEvents` (user
  domain) + `CachedMedia`, `CachedEpisodes` (disposable). **M4 adds no tables
  and no columns — `schemaVersion` stays 2, no new migration.** (Risk-path note:
  no migration ⇒ no migration review needed.)
- **`LibraryDao`** — `getAll`, `getItem`, `watchEventsFor`, `insertItem`,
  `updateItem`, `deleteItem`, `markWatched`, `markManyWatched`, `logRewatch`,
  `unwatch`, `recomputeDenormalized`, `transaction`. M4 adds exactly **two**
  methods (§5.1); everything else composes.
- **Import side (M3)** — `ImportArchive`, `parseArchive`, four importers,
  `Resolver`, `MergeApplier`, `ImportSummary`. M4 does **not** touch any of it.
- **`csv` package** is already a dependency (`ListToCsvConverter` for #31);
  `path_provider` is already a dependency (backup dir for #32). **No new deps.**
- **`clock`** is a dependency and is already the project's injected time source —
  `exportedAt` uses `clock.now()`, never `DateTime.now()`.
- **`dart_test.yaml`** pins a 60s per-test timeout (hang-guard).
- **`android/app/src/main/AndroidManifest.xml`** already sets
  `android:allowBackup="true"` and carries a TODO comment pointing at #32.

## 2. Requirements → user stories (acceptance criteria)

| Req | User story | Issue(s) |
|-----|-----------|----------|
| R7 Export | **US-10** As a privacy-minded user, I export all my data portably so I am never locked in | #30 |
| R7 Export | **US-12** As a Letterboxd user, I export my films as a CSV Letterboxd will re-import | #31 |
| R8 Backup | **US-11** As a user who reinstalls, my library restores automatically with no action | #32 |
| ADR-3 | **US-13** As a privacy-minded user, my export contains *only* what I own — never cache, never keys | #33 |

## 3. Architecture decisions (milestone-local, AD-N)

- **AD-1 — One serializer, three consumers.** `ImportExportService.exportJson()`
  is the single producer of the canonical JSON. Manual export (M5 UI), the
  auto-backup snapshot (#32), and the regression test (#33) all call it. This
  *is* ADR-6 ("export = backup format") made literal — there is no second
  serializer to drift out of sync.
- **AD-2 — Derived columns are not exported, they are recomputed.**
  `LibraryItems.id`, `watchedCount`, `lastWatchedSeason`, `lastWatchedEpisode`,
  `WatchEvents.id`, `WatchEvents.libraryItemId` are all derivable. Omitting them
  means the file cannot lie about them, and restore ends each item with the
  existing `recomputeDenormalized(itemId)`. Round-trip identity still holds
  because recompute is deterministic over the events we *do* export.
- **AD-3 — Watches nest inside their item.** No FK ids in the file ⇒ no id
  remapping on restore, and the shape lines up with `ImportRecord.watches`.
- **AD-4 — Restore replaces; import merges (the CLAUDE.md invariant).**
  `ImportExportService.restore()` runs `wipe user tables → insert` inside **one**
  `dao.transaction`, so a mid-restore failure rolls back to a clean, retryable
  state. It never calls `MergeApplier`.
- **AD-5 — Parse defensively, never with `as`.** `json['x'] as String` raises
  `TypeError`, which `on Exception` does not catch (CLAUDE.md gotcha). Every
  field goes through typed `_str/_int/_bool/_date/_enum` helpers returning null
  on a type mismatch. A structurally-valid-but-malformed item is **dropped and
  counted** (AD-7 in M3's plan: a bad row costs a row, never the file); a
  missing required field (`mediaType`, `title`, `trackStatus`,
  `recordedSource`, `addedAt`) drops that item.
- **AD-6 — The backup path never blocks or aborts boot.** `restoreIfEmpty()` is
  awaited in `main()` **inside `try { } on Object { }`**, and its DB work is one
  transaction. A corrupt backup file that throws every launch would otherwise be
  a permanent boot loop (CLAUDE.md Dart gotcha).
- **AD-7 — The manifest allowlist is the *only* thing standing between the cache
  and Google's servers.** Android Auto Backup's default includes `databases/`
  and `shared_prefs/` — i.e. our disposable cache tables **and** the metadata API
  key. `<include>` makes both rule files allowlists (any `<include>` ⇒ only those
  paths are backed up). This is a load-bearing invariant enforced by a test
  (§5.3), not by a comment.

## 4. Data model — the canonical export JSON (`version: 1`)

Exactly three top-level keys. The key set is frozen by the #33 allowlist test.

```jsonc
{
  "version": 1,                              // format version, NOT drift schemaVersion
  "exportedAt": "2026-07-09T12:00:00.000Z",  // clock.now().toUtc().toIso8601String()
  "items": [
    {
      "mediaType": "tv",                     // MediaType.name
      "recordedSource": "tmdb",              // MetadataSourceKind.name
      "tmdbId": 1396, "tvdbId": null, "imdbId": "tt0903747",
      "title": "Breaking Bad", "year": 2008,
      "posterPath": "/x.jpg",
      "genresCsv": "Drama,Crime",            // stats snapshot
      "runtimeMinutes": 47,                  // stats snapshot
      "trackStatus": "watching",             // TrackStatus.name
      "showStatus": "Ended",
      "episodeCountTotal": 62,
      "rating": 10, "ratedAt": "2020-01-01T00:00:00.000Z",
      "addedAt": "...", "updatedAt": "...",
      "relinkFailed": false,
      "watches": [
        { "season": 1, "episode": 1, "watchedAt": "...", "runtimeMinutes": 58, "isRewatch": false }
      ]
    }
  ]
}
```

Nulls are **omitted**, not written, to keep the file small; the reader treats
absent and null identically. `season`/`episode` both absent ⇒ a movie watch
(same convention as `WatchEvents` and `ImportWatch`).

Restore rejects `version > 1` (returns 0 items restored, no wipe).

## 5. Issue-by-issue

Order is forced by dependency: **#30 → #31 → #32 → #33**. One commit each,
`(#N)` in the subject.

### 5.1 · #30 — `ImportExportService` (JSON canonical, user-tables-only) · `feat`

**New file** `lib/core/import_export/export/import_export_service.dart` — the
whole issue lives here (model + serializer + restore), because #33's static
guard greps exactly this file for cache/prefs symbols.

```dart
class ImportExportService {
  const ImportExportService(this.dao);
  final LibraryDao dao;                       // ← the ONLY collaborator. No prefs. No cache DAO.

  static const formatVersion = 1;

  Future<String> exportJson() async { ... }   // pretty-printed, stable key order
  Future<Map<String, Object?>> exportMap() async { ... }
  Future<RestoreSummary> restore(String json) async { ... }  // REPLACE path
}

typedef RestoreSummary = ({int itemsRestored, int watchEventsRestored, int skippedItems});
```

- `exportMap()` reads `dao.getAll()` then `dao.watchEventsFor(item.id)` per item.
  It **constructs the map field-by-field from named columns** — never
  `row.toJson()` — so a future column addition is a deliberate export decision,
  not an accident.
- `restore()`: `dao.transaction(() async { await dao.deleteAllUserData(); for each
  item { insertItem(...); insertWatchEvents(...); recomputeDenormalized(id); } })`.
- **Two new `LibraryDao` methods** (`lib/core/database/library_dao.dart`), the
  only DAO change in M4:
  - `Future<void> deleteAllUserData()` — `delete(watchEvents)` then
    `delete(libraryItems)`, in a transaction. (Cascade would cover events; being
    explicit means the method is correct even if `foreign_keys` is off.)
  - `Future<void> insertWatchEvent(WatchEventsCompanion entry)`.
  Both get a doc comment naming the restore-vs-import invariant.

**Tests** `test/core/import_export/import_export_service_test.dart` (in-memory DB):
1. **Round-trip identity (the acceptance):** seed 1 movie + 1 show with
   first-watches, a rewatch, a rating, a `relinkFailed=true` row → `exportJson()`
   → `deleteAllUserData()` → `restore()` → every `LibraryItem` column matches
   (ignoring `id`) and every `WatchEvent` matches on
   `(season, episode, watchedAt, runtimeMinutes, isRewatch)`.
2. **`watchedCount`/`lastWatched*` are recomputed, not trusted:** hand-edit the
   JSON to claim `watchedCount: 999` — wait, they aren't in the file at all, so
   instead assert the restored row's `watchedCount` equals the number of
   non-rewatch events and `lastWatched*` the max coordinate. (AD-2.)
3. **Empty library** exports `items: []` and restores to empty.
4. **Adversarial — structurally valid, wrongly typed:** `{"version":1,"items":[
   {"mediaType":42,"title":null,...}]}` → does **not** throw (`TypeError` trap,
   AD-5), drops the item, `skippedItems == 1`, DB left empty.
5. **Adversarial — syntactically invalid** (`"not json"`) → throws
   `FormatException`; caller (#32) is the one that swallows it.
6. **Adversarial — future version** (`"version": 99`) → no wipe, 0 restored.
7. **Adversarial — a bad item mid-file does not lose the good ones**, and the
   pre-existing rows are gone exactly once (replace, not merge).
8. `exportedAt` comes from an injected `Clock` (`withClock`), asserting no
   `DateTime.now()` leaked in.

### 5.2 · #31 — Letterboxd CSV export (movies) · `feat`

**New file** `lib/core/import_export/export/letterboxd_export.dart`.

```dart
String letterboxdCsv(List<(LibraryItem, List<WatchEvent>)> movies);
```
Pure function over already-read rows (no DAO) so it is trivially testable; a
thin `ImportExportService.exportLetterboxdCsv()` does the reads.

- Header, exactly as the issue specifies:
  `Name,Year,Rating,Rewatch,WatchedDate,tmdbID,imdbID`
- **Rows are watch events, not titles** (Letterboxd's import is diary-shaped):
  one row per `WatchEvent`, `Rewatch` = `Yes` for `isRewatch`, else `No`.
- `WatchedDate` = `yyyy-MM-dd` of `watchedAt`; **empty** when the event carries
  no date (Letterboxd then files it as watched-undated rather than misdating it).
- `Rating` = `rating / 2` on Letterboxd's 0.5–5.0 scale, one decimal (`4.5`),
  empty when unrated. This is the exact inverse of `LetterboxdImporter`'s
  doubling — asserted by a round-trip test.
- **Only `MediaType.movie`** rows (Letterboxd tracks films and nothing else).
  A movie with **no watch events and no rating is skipped** — it is a watchlist
  entry, and emitting it would tell Letterboxd the user had watched it. A movie
  with a rating but no events emits **one** dateless `Rewatch=No` row (a rating
  implies a viewing — the same inference `LetterboxdImporter` already makes).
- Written with `const ListToCsvConverter().convert(rows)` (rung 4: the `csv` dep
  is already here). Quoting/escaping is its problem, not ours.

**Tests** `test/core/import_export/letterboxd_export_test.dart`:
1. **Shape (the acceptance):** header is byte-exact; a movie with 1 watch + 2
   rewatches yields 3 rows with `Rewatch` = `No,Yes,Yes`.
2. **Rating rescale:** `rating: 9` → `4.5`; `rating: null` → `` (empty).
3. **TV shows never appear.**
4. **Watchlist movie (no events, no rating) is omitted; rated-unwatched movie
   emits one dateless row.**
5. **Adversarial — a title containing a comma and a double-quote** round-trips
   through `parseCsv()` (the project's own reader) unmangled.
6. **Adversarial round-trip (the "re-importable" acceptance):** feed the
   generated CSV back through `LetterboxdImporter.parse()` (it sniffs on the
   `Letterboxd URI` column, which we do not emit — so this test asserts the
   *rows* survive `parseCsv`, and documents that our CSV is for
   letterboxd.com/import, not for our own importer). If `canRead` must be true,
   that is a scope change ⇒ raise, do not silently add a `Letterboxd URI`
   column the issue never asked for.
7. Dateless event → empty `WatchedDate`, not `1970-01-01`.

### 5.3 · #32 — `AutoBackupService` + manifest allowlist · `feat`

**New file** `lib/core/import_export/export/auto_backup_service.dart`:

```dart
class AutoBackupService {
  AutoBackupService({required this.service, required this.directory});
  final ImportExportService service;
  final Directory directory;                  // injected ⇒ tests use a temp dir, not path_provider

  File get file => File('${directory.path}/watchnook_backup.json');

  /// Serialize → temp file → rename. A crash or a serialize throw leaves the
  /// PREVIOUS backup intact; a half-written file is never visible under [file].
  Future<void> snapshot() async { ... }

  /// Fresh-install restore, keyed on an EMPTY LibraryItems. Returns true when
  /// it restored. Never wipes a non-empty library.
  Future<bool> restoreIfEmpty() async { ... }
}
```

- `snapshot()`: `directory.create(recursive: true)` → build the JSON **first**
  (so a serialize failure never even creates the temp) → `tmp.writeAsString(json,
  flush: true)` → `tmp.rename(file.path)`. Same-directory rename is atomic on
  POSIX; that is the whole trick, and it is why the temp is a sibling.
- `restoreIfEmpty()`: `if ((await dao.getAll()).isNotEmpty) return false;` then
  `if (!file.existsSync()) return false;` then `service.restore(await
  file.readAsString())`. Guard on the **library**, not on a "first run" pref —
  prefs are excluded from backup (§AD-7) so they cannot be trusted here.

**New file** `lib/core/import_export/export/export_providers.dart` — `@Riverpod
(keepAlive: true)` `importExportService` (sync) + `autoBackupService`
(`Future`, because `getApplicationSupportDirectory()` is async).
`getApplicationSupportDirectory()` maps to Android's `getFilesDir()` = backup
domain `file`, which is what the rule files allowlist.

**Wiring — `lib/main.dart`:**
- Boot (AD-6):
  ```dart
  try {
    final backup = await container.read(autoBackupServiceProvider.future);
    if (await backup.restoreIfEmpty()) await prefs.setBool(onboardingSeenKey, true);
  } on Object catch (e, s) { debugPrint('backup restore skipped: $e\n$s'); }
  ```
  Setting the onboarding flag is required: a restored user has a full library and
  must not be shown first-run. This needs `_key` in
  `features/onboarding/presentation/onboarding_provider.dart` promoted to a
  public `const onboardingSeenKey` (one-line change; the provider keeps using it).
- Pause: `WatchnookApp` becomes a `ConsumerStatefulWidget` holding an
  `AppLifecycleListener(onPause: ...)` that fires `snapshot()` fire-and-forget,
  errors swallowed to a `debugPrint` (a failed backup must never crash the app).
  Disposed in `dispose()`.

**New files** `android/app/src/main/res/xml/backup_rules.xml` (API ≤30,
`fullBackupContent`) and `.../data_extraction_rules.xml` (API 31+): both
allowlist **only** `domain="file" path="backup"`. `AndroidManifest.xml` gains
`android:fullBackupContent="@xml/backup_rules"` and
`android:dataExtractionRules="@xml/data_extraction_rules"`, replacing the TODO
comment with the invariant. Backup file therefore moves to
`<filesDir>/backup/watchnook_backup.json`.

**Tests** `test/core/import_export/auto_backup_service_test.dart`
(temp dir + in-memory DB):
1. **Fresh-install restore (the acceptance):** empty DB + a valid backup file →
   `restoreIfEmpty()` true, library matches.
2. **Non-empty library is never wiped:** one existing item + a backup file with
   different items → returns false, the existing item survives.
3. **No backup file** → false, no throw.
4. **Atomic write — the previous backup survives a failed snapshot.** Inject a
   service whose `exportJson()` throws; assert the old `watchnook_backup.json`
   is byte-identical afterwards and **no `.tmp` sibling is left behind**.
5. **Atomic write — no partial file is ever visible:** after `snapshot()`, the
   directory contains exactly one file and it parses as JSON.
6. **Adversarial — a corrupt backup does not boot-loop:** `restoreIfEmpty()` over
   `"{{{"` and over a well-formed-but-wrongly-typed doc → throws at most a
   caught exception, DB left empty, and a *subsequent* `snapshot()` still works.
7. **Adversarial — restore does not resurrect the cache:** seed `CachedMedia`,
   snapshot, wipe everything, restore → cache stays empty (it was never in the
   file) and no exception.

**Tests** `test/android/backup_rules_test.dart` — pure XML string assertions, no
Flutter binding:
8. Both rule files exist, and each contains an `<include domain="file"
   path="backup"`.
9. **Adversarial:** neither file mentions `domain="database"` nor
   `domain="sharedpref"` (the cache tables and the API key). This test is the
   enforcement of AD-7.
10. `AndroidManifest.xml` references both rule files and still has
    `allowBackup="true"`.

**Real-artifact verification** (Definition of Done — `just check` cannot see any
of this): `android-emulator` skill → install, import a fixture, background the
app (`adb shell input keyevent KEYCODE_HOME`) and confirm
`<filesDir>/backup/watchnook_backup.json` exists → `bmgr backupnow
com.example.watch_nook` → uninstall → reinstall → launch → **library is back and
onboarding does not show**. Also `adb shell dumpsys backup` to confirm the
allowlist. Record the transcript in the PR triage comment.

### 5.4 · #33 — Export-excludes-cache regression test · `test`

**New file** `test/core/import_export/export_excludes_cache_test.dart`. This is
the adversarial test the two-domains invariant is enforced by — it must fail if
someone *adds* a leak, not merely pass today.

1. **Canary scan.** Seed `CachedMedia` + `CachedEpisodes` with values containing
   the literal `CACHE_LEAK_CANARY` (title, overview, payload) and
   `SharedPreferences` with `PREFS_LEAK_CANARY` (and a fake `apiKey`). Seed the
   user tables with ordinary data. Then
   `expect(await service.exportJson(), isNot(contains('CANARY')))` and
   `isNot(contains('apiKey'))`.
2. **Frozen key set — top level.** `exportMap().keys` is exactly
   `{version, exportedAt, items}`.
3. **Frozen key set — per item.** Every emitted item key ∈ the explicit
   allowlist of the 17 user columns + `watches`; and every `watches` key ∈
   `{season, episode, watchedAt, runtimeMinutes, isRewatch}`. A new cache-derived
   field cannot slip in unnoticed.
4. **Derived columns are absent** (AD-2): no `id`, `watchedCount`,
   `lastWatchedSeason`, `lastWatchedEpisode`, `libraryItemId`.
5. **Static guard.** Read `lib/core/import_export/export/import_export_service.dart`
   as text and assert it mentions neither `CachedMedia`/`cachedMedia`/
   `MediaCacheDao` nor `SharedPreferences`/`sharedPreferences`. Cheap, and it
   catches the leak at the import statement rather than at the JSON.
6. **Backup snapshot inherits the exclusion**: the file `AutoBackupService`
   writes is the same string ⇒ assert the on-disk backup contains no canary
   either (guards against a future "just add the cache to the backup" shortcut).

Commit: `test(export): export-excludes-cache regression (#33)`.

## 6. Non-goals (do not build; file follow-ups instead)

- **No export/backup UI.** Settings ("export/backup, theme, about") is **#35 in
  M5**. M4 ships services + providers only. Wiring a share-sheet here would be
  scope creep.
- **No `WatchnookImporter`.** Picking a Watchnook JSON in the *import* screen (a
  merge, via `MergeApplier`, rather than a replace) is genuinely useful and is
  in **no issue**. File it as a follow-up rather than smuggling it into #30 —
  `restore()` is the replace path ADR-6 names, and that is what #30 asks for.
- **No `share_plus` / file-save picker.** No new dependency in M4.
- **No schema change.** `schemaVersion` stays 2.

## 7. Risks

| Risk | Mitigation |
|------|-----------|
| Allowlist typo silently backs up `databases/` (cache + no user gain) or `shared_prefs/` (**API key to Google**) | §5.3 tests 8–10 + `dumpsys backup` on the emulator |
| `getApplicationSupportDirectory()` is not the `file` backup domain | Verified on-emulator by locating the real path before `bmgr backupnow` |
| A corrupt backup boot-loops the app | AD-6: `try { } on Object { }` around the awaited restore; §5.3 test 6 |
| `restore()` wipes a live library because "empty" was mis-detected | The guard reads `LibraryItems`, never a pref; §5.3 test 2 |
| Round-trip test passes by comparing `toJson()` to `toJson()` | Test 1 compares **column by column** against re-read DB rows |
| Letterboxd rejects our CSV | Columns are exactly the issue's contract; verification is a human upload (flag in the triage comment as unverifiable by CI) |

## 8. Unresolved questions

1. #31 acceptance says "re-importable to Letterboxd" — CI cannot verify that.
   Accept the column contract as proxy, or mark `needs-human`?
2. Should `exportLetterboxdCsv` also emit `Letterboxd URI` so our own
   `LetterboxdImporter.canRead()` claims our CSV? Issue says no. Confirm.
3. Backup file at `<filesDir>/backup/` vs `<filesDir>/` root — the subdir buys a
   tighter allowlist path. Any objection?
4. `_key` → `const onboardingSeenKey` (public) needed so `main()` can pre-set the
   flag on restore. OK?
