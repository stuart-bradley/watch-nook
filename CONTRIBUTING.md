# Contributing to Watchnook

Thanks for your interest! Watchnook is a local-first Android app built with Flutter. This guide gets
you from clone to a green build.

## Prerequisites

- **[Flutter 3.44.0](https://docs.flutter.dev/get-started/install)** (pinned — CI uses it) + the Android SDK.
- **[`just`](https://github.com/casey/just)** (task runner).
- A **free [TMDB API key](https://www.themoviedb.org/settings/api)** for anything that fetches metadata.

## Setup

```bash
git clone https://github.com/stuart-bradley/watch-nook && cd watch-nook
flutter pub get
cp secrets.json.example secrets.json     # then add your TMDB key (flat shape)
```

`secrets.json` is git-ignored and never committed. It must be **flat** (top-level keys) — a nested
object silently resolves to an empty key at build time:

```json
{ "activeSource": "tmdb", "tmdbApiKey": "<your TMDB v3 key>", "tmdbReadToken": "", "tvdbApiKey": "" }
```

## Dev workflow

```bash
just check     # codegen + analyze + format-check + tests — this is exactly what CI runs
dart format .  # auto-fix formatting, then re-run just check
flutter run --dart-define-from-file=secrets.json   # run on a device/emulator
```

- **State is Riverpod** (`@riverpod` + generator); navigation is **go_router**; the DB is **Drift**
  (DAO access only). Run `dart run build_runner build` after changing providers or Drift tables.
- **Never commit generated files** (`*.g.dart` — git-ignored).
- Read **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** first — especially the **invariants** (two data
  domains, watched-idempotent toggle, aired-order episodes, import ≠ restore, stats snapshotting,
  non-blocking config). They're the rules that break things across files if ignored.

## Testing

- **Unit:** importers (real fixtures + malformed inputs), resolver/MergeApplier, watched-semantics,
  export/import round-trip, the `MetadataSource` contract suite (both impls) via `MockClient`.
- **Widget:** override providers via `ProviderScope` (never the real DB). A DB-backed
  `StreamProvider` screen **must** be overridden with a synchronous `Stream.value(...)` — a live Drift
  `.watch()` stream hangs `pumpAndSettle()` for its full 10-minute timeout under fake-async.
- **E2E:** Patrol tests in `integration_test/`.
- Write **adversarial** tests (what does a regression look like?), not confirmatory ones.
- **Beyond green `just check`:** for changes touching surfaces tests can't reach (metadata fetch, image
  loading, import of a real file, backup/restore, navigation), run the real artifact on a device/emulator.

## Commits & PRs

- Commit format: `type(scope): description` (`feat`, `fix`, `test`, `refactor`, `chore`, `docs`);
  reference an issue where relevant.
- Open PRs against `main`; **CI must be green** before merge.
- Don't add a backend, accounts, ads, or social features — that's a deliberate non-goal. The only
  network dependency is the metadata API.

## Attribution & licensing

Metadata comes from TMDB; the mandatory attribution (logo + notice) must remain on the detail and
settings screens. Watchnook ships free under [MIT](LICENSE); note the TMDB dev key is non-commercial
(see `docs/ARCHITECTURE.md`).
