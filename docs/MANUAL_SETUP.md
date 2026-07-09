# Manual setup — do this BEFORE `/autopilot-start`

Autopilot builds Watchnook from the GitHub milestones/issues, but a few things need a human first. Work top-to-bottom. Items 1–2 are also tracked as `needs-human` GitHub issues (**#7 fixtures — ✅ done**, #6 API keys).

## 1. ✅ DONE — Real service exports in `test/fixtures/` (closed #7 via PR #39, 2026-07-08)
The M3 import parsers TDD against these files, now committed under `test/fixtures/` (see its README):
- **TV Time** — a **real** GDPR export, curated to ~23 shows / ~300 watched-episode rows / ~10 movies, **PII-stripped** (only the 5 import tables; `user_id` scrubbed). Regenerate from a fresh export with `test/fixtures/tvtime/trim_from_gdpr_export.py`.
- **IMDb / Letterboxd / Trakt** — synthesized from real, cross-referenced ids (imdb `tt` / tmdb / tvdb), with cross-source overlap anchors for MergeApplier dedup tests.
- One deliberately **malformed** sample per source under `test/fixtures/malformed/` (structurally-valid-but-wrong, for the `as`-cast `TypeError` guard).

## 2. Metadata API keys
- **TMDB** (default backend): create an account → API → request a key (instant). 
- **TheTVDB v4** (optional, enables commercial/pay-once): `https://thetvdb.com/dashboard` → create a v4 key → choose **Negotiated Contract** (free under $50k/yr, attribution only). Approval is human-gated and can be slow/flaky (issue #376) — apply early; the app ships fine on TMDB alone.
- Put the keys in the RemoteConfig JSON (hosted, e.g. GitHub Pages/raw) **and** the baked-in default in the app. Never commit keys to the repo (`.gitignore` covers `secrets.json`/`*.env`).
- **`secrets.json` must be FLAT** (top-level string keys) — `--dart-define-from-file` only round-trips flat strings; a nested object arrives as a Dart `Map.toString()` (invalid JSON) and silently resolves to an empty key (issue #52). Shape:
  ```json
  { "activeSource": "tmdb", "tmdbApiKey": "…", "tmdbReadToken": "…", "tvdbApiKey": "" }
  ```
- **TheTVDB key is NOT public-safe like TMDB.** TMDB rate-limits per-IP, so its embedded key is harmless (public by design). TheTVDB attributes usage per-key/contract, so a baked-in TheTVDB key can be abused to drain *your* quota / muddy *your* free contract. Before enabling TheTVDB, choose a delivery model — TheTVDB's per-user **subscriber PIN** (no shared secret shipped) or hosted-RemoteConfig-only (rotatable) — and confirm their terms allow client embedding. Keep `tvdbApiKey` empty until then.

## 3. Plugins & tooling
- Ensure the **`autopilot`** and **`toolkit`** plugins are enabled in Claude Code.
- Run **`/autopilot-status`** in this repo — it should read `.autopilot.json` and derive **M0** as the active milestone with **#1** as the next issue.

## 4. Repo hygiene (already set by the setup, verify)
- Default branch **`main`**; labels **`autopilot`** and **`needs-human`** exist; `.autopilot.json` present at root; milestones M0–M5 + issues created.

## 5. Signing
- Autopilot builds use the **debug-keystore fallback** (no action needed). Release signing (a keystore + `key.properties`, and CI secrets `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`, `PLAY_STORE_JSON_KEY`) is the `needs-human` release issue (#38).

## 6. Launch & supervise
- From this repo: **`/autopilot-start`**.
- Each morning: read **`MORNING.md`** and review the open **`auto/m*` PRs**. **Autopilot never merges — you are the gate.**
- ⚠️ Autopilot is a **crawl-only v1** previously tested only on a sandbox; treat this first run as **supervised** — check the first milestone's PR closely before trusting later ones.

## 7. Before first Play upload (later)
- Confirm the name **Watchnook** is free in Play Console (search-index showed zero collisions, but Console is authoritative).
