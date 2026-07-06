# Test fixtures — real service exports

The import parsers (Milestone M3) are developed **TDD-first against real exports**. Drop anonymised-if-you-like but **structurally real** exports here before starting M3:

| File / dir | Source | How to get it |
|---|---|---|
| `tvtime/` (the unzipped GDPR export, or the `.zip`) | **TV Time** | `https://gdpr.tvtime.com/gdpr/self-service` — **⚠️ pull before 2026-07-15**, it's gone after shutdown |
| `imdb_ratings.csv`, `imdb_watchlist.csv` | IMDb | imdb.com → Your Ratings / Watchlist → Export (desktop web) |
| `letterboxd/` (the export `.zip` contents) | Letterboxd | letterboxd.com → Settings → Import & Export → Export your data |
| `trakt/` (the export JSON) | Trakt | trakt.tv → Settings → Data → Export |

Notes:
- **TV Time**: TV rows carry TheTVDB ids (clean match); **movie rows are internal UUIDs** (title+year fuzzy match).
- **Trakt / Simkl**: JSON with full id blocks (tmdb/tvdb/imdb) — cleanest.
- **IMDb**: CSV with `tt` ids. **Letterboxd**: CSV with no ids (title+year, or resolve the Letterboxd URI).
- Keep at least one **deliberately malformed** sample per source (truncated / wrong-typed field) — the parsers must degrade gracefully, not throw (`as`-cast `TypeError` guard).

These fixtures are what the M3 parser unit tests load. Without them, M3 cannot be done properly — it is a `needs-human` prerequisite (see `docs/MANUAL_SETUP.md`).
