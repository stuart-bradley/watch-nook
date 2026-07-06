# Manual setup — do this BEFORE `/autopilot-start`

Autopilot builds Watchnook from the GitHub milestones/issues, but a few things need a human first. Work top-to-bottom. Items 1–2 are also tracked as `needs-human` GitHub issues (#6, #7).

## 1. ⚠️ Pull real service exports into `test/fixtures/` (TIME-CRITICAL)
The M3 import parsers are TDD'd against real files. Pull, then drop into `test/fixtures/` per its README:
- **TV Time — before 2026-07-15** (`https://gdpr.tvtime.com/gdpr/self-service`). Irreplaceable after shutdown.
- **IMDb** (Your Ratings / Watchlist → Export), **Letterboxd** (Settings → Import & Export), **Trakt** (Settings → Data → Export).
- Keep one deliberately **malformed** sample per source (truncated / wrong-typed field).

## 2. Metadata API keys
- **TMDB** (default backend): create an account → API → request a key (instant). 
- **TheTVDB v4** (optional, enables commercial/pay-once): `https://thetvdb.com/dashboard` → create a v4 key → choose **Negotiated Contract** (free under $50k/yr, attribution only). Approval is human-gated and can be slow/flaky (issue #376) — apply early; the app ships fine on TMDB alone.
- Put the keys in the RemoteConfig JSON (hosted, e.g. GitHub Pages/raw) **and** the baked-in default in the app. Never commit keys to the repo (`.gitignore` covers `secrets.json`/`*.env`).

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
