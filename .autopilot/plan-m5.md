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
  `unwatch`, `recomputeDenormalized`, `transaction`. M4 adds exactly **three**
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
  missing required field drops that item. The required set is **every NOT NULL,
  no-default column** of `LibraryItems`: `mediaType`, `recordedSource`, `title`,
  `trackStatus`, `addedAt`, **`updatedAt`**. `updatedAt` is `dateTime()` with no
  default (tables.dart:123) — `LibraryItemsCompanion.insert` cannot be built
  without it, so it is required, and the parser defaults `updatedAt ??= addedAt`
  before dropping (a file that knows when a row was added but not when it was
  touched is recoverable; one missing both is not). `watchedCount` and
  `relinkFailed` have DB defaults and are never required.
- **AD-6 — The backup path never blocks or aborts boot.** `restoreIfEmpty()` is
  awaited in `main()` **inside `try { } on Object { }`**, and its DB work is one
  transaction. A corrupt backup file that throws every launch would otherwise be
  a permanent boot loop (CLAUDE.md Dart gotcha).
- **AD-7 — The manifest allowlist is the *only* thing standing between the cache
  and Google's servers.** Android Auto Backup's default includes `databases/`
  and `shared_prefs/` — i.e. our disposable cache tables **and** the metadata API
  key. An `<include>` turns a rule file into an allowlist (any `<include>` ⇒ only
  those paths are backed up). **Two traps make this sharper than it looks, and
  both fail *open*:**
  1. In `dataExtractionRules` (API 31+) `<include>`/`<exclude>` are **invalid at
     the root** — they must nest inside `<cloud-backup>` and `<device-transfer>`.
     A root-level `<include>` is a malformed file, the rules are **ignored**, and
     the default (cache + API key → Google) applies.
  2. **A missing section is a fully-enabled section.** Per the Android docs, "if
     there are no rules for a particular backup mode, such as if the
     `<device-transfer>` section is missing, that mode is fully enabled for all
     content" — so shipping only `<cloud-backup>` leaks `shared_prefs/` on a
     device-to-device transfer.

  Therefore both sections are always written, and §5.3's test asserts their
  **presence and exact contents positively**. Asserting the *absence* of
  `domain="database"` is worthless here: the leaking file is the one that
  mentions neither. Load-bearing invariant, enforced by a test, not a comment.

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

**Every** `DateTime` is written `.toUtc().toIso8601String()` — `exportedAt`,
`addedAt`, `updatedAt`, `ratedAt`, `watchedAt` alike. A local-vs-`Z` mismatch
would silently shift a round-tripped date across a day boundary.

**Version gate: restore accepts `version == 1` and nothing else.** Absent,
non-integer, `0`, or `> 1` all reject — return `(0, 0, 0)` and **do not wipe**.
"Reject" must not mean "treat as v1": `restoreIfEmpty()` only ever runs against
an empty DB, but M5's manual restore (#35) will not have that guard, so the
no-wipe-on-unknown-version rule is pinned here rather than discovered there.

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
- **Three new `LibraryDao` methods** (`lib/core/database/library_dao.dart`), the
  only DAO change in M4:
  - `Future<void> deleteAllUserData()` — `delete(watchEvents)` then
    `delete(libraryItems)`, in a transaction. (Cascade would cover events; being
    explicit means the method is correct even if `foreign_keys` is off.)
  - `Future<void> insertWatchEvent(WatchEventsCompanion entry)`.
  - `Future<bool> hasAnyItems()` — `LIMIT 1` existence probe, **not**
    `getAll().isNotEmpty`. #32's guard runs inside `main()` before `runApp`; a
    returning user with thousands of rows must not deserialize the whole library
    on every cold boot to answer "is it empty?".

  All three get a doc comment naming the restore-vs-import invariant.

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
   AD-5), drops the item, `skippedItems == 1`, DB left empty. Cases, one per
   required column: `mediaType` not a legal enum name; `title` null; `addedAt`
   an int; **`updatedAt` absent → item still restores, with `updatedAt ==
   addedAt`** (AD-5's fallback); **`addedAt` and `updatedAt` both absent → item
   dropped**. Unknown extra keys are ignored, not fatal.
5. **Adversarial — syntactically invalid** (`"not json"`) → throws
   `FormatException`; caller (#32) is the one that swallows it.
6. **Adversarial — the version gate never wipes.** Seed a non-empty library,
   then `restore()` each of `{"version":99,...}`, `{"version":0,...}`,
   `{"version":"1",...}`, and a doc with **no** `version` key at all — each
   returns 0 restored **and leaves the seeded rows untouched**. (The wipe must
   not precede the gate.)
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
  `(stars * 2).round()` — asserted by a round-trip test. **`rating == 0` emits
  empty, not `0.0`:** Letterboxd's scale floors at 0.5, and the importer already
  rejects `< 0.5`, so a zero here is "unrated" however it got into the column.
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
2. **Rating rescale:** `rating: 9` → `4.5`; `rating: 10` → `5.0`; `rating: 1` →
   `0.5`; `rating: null` → `` (empty); **`rating: 0` → `` (empty), not `0.0`**.
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
  AutoBackupService({required this.service, required this.dao, required this.directory});
  final ImportExportService service;
  final LibraryDao dao;
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
  **Single-flight:** `onPause` is fire-and-forget, so a fast pause→resume→pause
  can put two writers on the same temp name and let the second's rename publish
  the first's half-written bytes. Hold the in-flight `Future<void>?` in a field
  and return it instead of starting a second write. (One field, not a lock
  library — the only concurrency here is "the same callback twice".)
  **The field MUST be nulled in a `whenComplete`/`finally`.** Leave it set and
  every subsequent `snapshot()` returns the already-completed future: backups
  stop forever, silently, with no error anywhere. Test 5b cannot see this (both
  its calls are in the same flight) — only §5.3 test 6's *later, independent*
  `snapshot()` can, so that assertion is load-bearing, not incidental.
  Single-flight is **leading-edge**: the second caller's newer DB state is not
  captured until the next `onPause`. Accepted — `onPause` re-fires on every
  backgrounding and Android throttles off-device backup anyway, so the file
  re-converges. The corruption race is what mattered.
- `restoreIfEmpty()`: `if (await dao.hasAnyItems()) return false;` then
  `if (!await file.exists()) return false;` then `service.restore(await
  file.readAsString())`. Guard on the **library**, not on a "first run" pref —
  prefs are excluded from backup (§AD-7) so they cannot be trusted here. Uses the
  `LIMIT 1` probe, not `getAll()`: this runs on the cold-boot path (§5.1).

**New file** `lib/core/import_export/export/export_providers.dart` — `@Riverpod
(keepAlive: true)` `importExportService` (sync) + `autoBackupService`
(`Future`, because `getApplicationSupportDirectory()` is async).

**The provider injects the `backup/` subdirectory, not the support dir — and it
builds the path from a named const, never a bare literal:**

```dart
class AutoBackupService {
  /// MUST equal `path="backup"` in res/xml/backup_rules.xml and
  /// data_extraction_rules.xml, or nothing is ever backed up. See AD-7.
  static const backupDirName = 'backup';
}

final support = await getApplicationSupportDirectory();
return AutoBackupService(
  ...,
  directory: Directory('${support.path}/${AutoBackupService.backupDirName}'),
);
```

A second literal in the provider would make §5.3 test 12 decorative: it would
catch the XML drifting while the provider quietly moved to `backups/`.

`getApplicationSupportDirectory()` returns Android's `getFilesDir()` (verified:
`path_provider_android` returns `_applicationContext.filesDir`), which is backup
domain `file` with an empty relative path. The allowlist below says
`path="backup"`, so the service **must** write one level down. Get this wrong and
the app backs up nothing at all, silently, forever — the write path and the
allowlist path are one fact expressed in two files, and only the on-emulator
check below can see them disagree.

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

**New files** — two rule files, because the two Android backup eras read
different schemas (AD-7). Written out in full here so the nesting cannot be
guessed wrong at implementation time:

`android/app/src/main/res/xml/backup_rules.xml` (API ≤ 30, `fullBackupContent`) —
`<include>` lives at the root in *this* schema:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- ALLOWLIST (ADR-3). Only the user-owned backup JSON leaves the device.
     Omitting this file backs up databases/ (the disposable cache) and
     shared_prefs/ (the metadata API key). Enforced by backup_rules_test.dart. -->
<full-backup-content>
    <include domain="file" path="backup"/>
</full-backup-content>
```

`android/app/src/main/res/xml/data_extraction_rules.xml` (API 31+) — `<include>`
is **invalid at the root**; and a *missing* section is a **fully enabled**
section, so both `<cloud-backup>` and `<device-transfer>` must be present:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- ALLOWLIST (ADR-3). BOTH sections are mandatory: an absent <device-transfer>
     means "back up everything" on device-to-device transfer — i.e. the API key
     in shared_prefs/. Enforced by backup_rules_test.dart. -->
<data-extraction-rules>
    <cloud-backup>
        <include domain="file" path="backup"/>
    </cloud-backup>
    <device-transfer>
        <include domain="file" path="backup"/>
    </device-transfer>
</data-extraction-rules>
```

`AndroidManifest.xml` gains `android:fullBackupContent="@xml/backup_rules"` and
`android:dataExtractionRules="@xml/data_extraction_rules"`, replacing the TODO
comment with the invariant. Backup file therefore lives at
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
5b. **Single-flight:** two `snapshot()` calls awaited together (no `await`
   between them) produce one write and one valid file, no orphan `.tmp`.
6. **Adversarial — a corrupt backup does not boot-loop:** `restoreIfEmpty()` over
   `"{{{"` and over a well-formed-but-wrongly-typed doc → throws at most a
   caught exception, DB left empty, and a *subsequent* `snapshot()` still works.
7. **Adversarial — restore does not resurrect the cache:** seed `CachedMedia`,
   snapshot, wipe everything, restore → cache stays empty (it was never in the
   file) and no exception.

**Tests** `test/android/backup_rules_test.dart` — **`String` assertions, no XML
parser.** Do *not* `import 'package:xml'` on the strength of it being transitive
through `archive`: `archive` may drop or bump it in any release and break this
test's import (this is what `depend_on_referenced_packages` lints against). The
files are six lines each; substring + `RegExp.allMatches` over
`<include ... />` is enough to enumerate the `(domain, path)` pairs, and it adds
nothing to `pubspec.yaml`. (If a real parser ever earns its keep, `xml` goes in
`dev_dependencies` — test-only, so "no new shipped deps" still holds.)
**Assert positively — never by absence.** Both rule files fail *open*: the leaking file is the one that
mentions neither `database` nor `sharedpref`, so "does not contain
`domain=\"database\"`" passes on precisely the file we are trying to catch.

8. `backup_rules.xml`: root is `<full-backup-content>`; its **only** child is
   `<include domain="file" path="backup"/>`. Zero other `include`/`exclude`
   elements anywhere in the document.
9. `data_extraction_rules.xml`: root is `<data-extraction-rules>`; it has **both**
   a `<cloud-backup>` and a `<device-transfer>` child (a missing one is a fully
   enabled one); **each** contains exactly one `<include>`, with
   `domain="file" path="backup"`, and nothing else. No `<include>`/`<exclude>` at
   the root (invalid schema ⇒ rules ignored ⇒ default backup).
10. **Adversarial, driven by the invariant rather than by string absence:**
    collect every `include` element in both documents and assert the set of
    `(domain, path)` pairs is exactly `{("file", "backup")}`. Adding a
    `domain="database"` include, adding a third backup mode section, or dropping
    `<device-transfer>` each fails a *different* one of tests 8–10.
11. `AndroidManifest.xml` references both rule files by name and still has
    `allowBackup="true"`.
12. `AutoBackupService.backupDirName` equals the `path` attribute parsed out of
    **both** XML files. Not "the literal `'backup'` appears in each" — the
    assertion must read the Dart const the provider actually uses (§5.3), or it
    catches XML drift while the provider silently moves to `backups/`.

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
3. **Frozen key set — per item.** Every emitted item key ∈ an **explicitly
   enumerated** allowlist (not a count) of the **18** exported user columns —
   `LibraryItems`' 22 columns minus the 4 derived ones of AD-2 — plus `watches`:
   `{mediaType, recordedSource, tmdbId, tvdbId, imdbId, title, year, posterPath,
   genresCsv, runtimeMinutes, trackStatus, showStatus, episodeCountTotal, rating,
   ratedAt, addedAt, updatedAt, relinkFailed, watches}`. Every `watches` key ∈
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

Every entry here fails **open** — the broken state looks exactly like the working
one from inside `just check`. That is why each row names a test or a device check.

| Risk | Mitigation |
|------|-----------|
| Malformed `dataExtractionRules` (root-level `<include>`) ⇒ rules **ignored** ⇒ `databases/` + `shared_prefs/` (**API key**) to Google | §5.3 tests 9–10 assert the `<cloud-backup>`/`<device-transfer>` nesting positively; `dumpsys backup` on device |
| `<device-transfer>` omitted ⇒ that mode backs up **everything** | Test 9 asserts both sections exist. Absence-of-string assertions cannot catch this — hence test 10's positive `(domain, path)` set |
| Write path (`filesDir/…`) and allowlist path (`filesDir/backup/`) drift ⇒ **nothing** is ever backed up, silently | Test 12 pins them to one `const`; the emulator round-trip is the only true check |
| `getApplicationSupportDirectory()` is not the `file` backup domain | Verified: `path_provider_android` returns `_applicationContext.filesDir`. Re-confirmed on-emulator before `bmgr backupnow` |
| A corrupt backup boot-loops the app | AD-6: `try { } on Object { }` around the awaited restore; §5.3 test 6 |
| `restore()` wipes a live library because "empty" was mis-detected | The guard reads `LibraryItems` via `hasAnyItems()`, never a pref; §5.3 test 2. The version gate rejects **before** the wipe (§5.1 test 6) |
| `updatedAt` (NOT NULL, no default) missing from a hand-edited file ⇒ companion cannot be built | AD-5 required-set + `updatedAt ??= addedAt`; §5.1 test 4 |
| Round-trip test passes by comparing `toJson()` to `toJson()` | Test 1 compares **column by column** against re-read DB rows |
| Two `onPause` snapshots race on one temp name ⇒ half-written bytes published | Single-flight future in `AutoBackupService`; §5.3 test 5b |
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
*(Resolved in pass 2: no `xml` package — `String` assertions, §5.3.)*

## 9. Review log

**Pass 1 → NEEDS CHANGES** (6 required). All six addressed: root-level
`<include>` in `dataExtractionRules` is invalid and a missing `<device-transfer>`
fails open (§AD-7, §5.3, tests 8–12); `updatedAt` is NOT NULL with no default
(§AD-5, §5.1 test 4); the frozen key set is 18 columns, not 17 (§5.4 test 3);
`hasAnyItems()` replaces `getAll().isNotEmpty` on the boot path (§5.1);
absent/invalid `version` rejects without wiping (§4, §5.1 test 6); the `backup/`
subdir is explicit in the provider (§5.3). Its three suggestions were taken too:
snapshot single-flight, `rating == 0` ⇒ unrated, UTC everywhere.

**Pass 2 → APPROVE**, with three non-blocking notes, all folded in before
implementation started: the single-flight field must be nulled in
`whenComplete` (leaving it set = permanent silent backup failure, invisible to
test 5b — §5.3); `backupDirName` is a real shared const so test 12 catches
provider drift and not just XML drift (§5.3); and `backup_rules_test.dart` uses
`String` assertions rather than importing `xml` transitively through `archive`
(§5.3). Pass 2 independently recounted the 18-column allowlist against
`tables.dart` and confirmed it exact.

**Settled — do not re-litigate:** restore-as-replace as the reading of ADR-6;
AD-2's recompute-don't-export of derived columns; the Letterboxd 0–10 ⇄ 0.5–5.0
rescale as the exact inverse of the importer; `onPause` (not `onDetach`) as the
snapshot hook; `getApplicationSupportDirectory()` == Android `filesDir` ==
backup domain `file`.
