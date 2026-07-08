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

## What's actually here

Fixtures are **committed** (CI loads them), so treat them as public.

| Path | Source | Real or synthesized |
|---|---|---|
| `tvtime/` (5 CSVs) | **TV Time** | **Real** GDPR export, curated subset (~23 shows, ~300 watched-episode rows, ~10 movies) |
| `imdb_ratings.csv`, `imdb_watchlist.csv` | IMDb | Synthesized from real `tt` ids / TMDB-findable titles |
| `letterboxd/{watched,ratings,diary,watchlist}.csv` | Letterboxd | Synthesized (movies only; title+year) |
| `trakt/trakt-export.json` | Trakt | Synthesized `sync/watched`-shape with full `ids` blocks |
| `malformed/` (4 files) | one per source | Structurally-valid-but-**wrong** (see below) |

**TV Time — PII handling.** Only the 5 import-relevant tables are included; every other GDPR
table (email, IP, tokens, connections, notifications, device/ad ids, the multi-MB tracking dumps)
is **excluded**. The real `user_id` was scrubbed to `10000000` throughout. Regenerate (and see
exactly which rows were kept) with `tvtime/trim_from_gdpr_export.py <path-to-export.zip>`.

**Cross-source overlap (for `MergeApplier` dedup-by-id-block tests).** Deliberately wired:
- **The Office (US)** — TV Time (tvdb `73244`) + IMDb (`tt0386676`) + Trakt (full ids) → one item.
- **The Social Network (2010)** — TV Time (movie, UUID → title+year fuzzy) + IMDb (`tt1285016`) + Letterboxd (title+year).
- **Parasite / The Matrix** — IMDb + Letterboxd + Trakt.

**Real edge cases preserved** in the TV Time data (not synthetic): quoted-comma names
(`"Love, Death & Robots"`), unicode (`Shōgun`), aired-order anime-adjacent (`ONE PIECE (2023)`,
tvdb `392276`), year-disambiguated titles (`Battlestar Galactica (2003)`), duplicate movie rows
(same title, different `release_date`) and bogus `0001-01-01` release dates.

**`malformed/` — each is loadable as text but violates its schema in one intended way**
(the parser must degrade, not throw an `as`-cast `TypeError`):
- `tvtime_followed_tv_show.csv` — non-numeric `tv_show_id` (`N/A`) + a truncated final row.
- `imdb_ratings.csv` — non-numeric `Your Rating` (`good`) + a row missing `Const`.
- `letterboxd_ratings.csv` — non-numeric `Rating` (`great`) + a truncated final row.
- `trakt-export.json` — **valid JSON**, but a show with `year: "unknown"` (string) and a missing `ids` block.

**Note on synthesized ids:** IMDb `tt`, TMDB and TVDB ids are the authoritative join keys and are
real. Letterboxd `Letterboxd URI` values use the film-slug form (`.../film/<slug>/`); real exports
use `boxd.it` short links, but the importer matches on title+year anyway.

