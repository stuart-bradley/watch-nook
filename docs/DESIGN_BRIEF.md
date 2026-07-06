# Watchnook — Design Brief

Watchnook is a **local-first, offline-first Android TV & movie tracker** (Flutter, Material 3). No accounts, no social, privacy-forward. It replaces TV Time for people who just want to track what they watch and what's next.

## Aesthetic
Match the existing portfolio (Wellquill / Tasks-on-time / CogScroll): **dark-leaning** Material 3 with optional Material You dynamic colour; flat **hairline "rail" cards** (elevation 0, thin outline); **full-width buttons** (`FilledButton`/`OutlinedButton`, 52px height) for primary CTAs, `TextButton` for inline actions; generous spacing; **poster-forward**; UK English, sentence case, no emoji. Colour is never the sole signal — pair with icon + label.

## Screens
1. **Library** — filterable grid of tracked titles by status (Watchlist / Watching / Completed / On-hold / Dropped) and type (TV / Movie). Each card: poster + title + progress ("S2E4 · 3 left"). Fast filtering; renders offline.
2. **Up Next / Calendar** — this week's airing episodes for tracked shows + upcoming release dates for tracked movies. Grouped by day.
3. **Search & add** — results with poster, year, type; quick "add" + status picker.
4. **Title detail** — backdrop, overview, rating; seasons → episodes list with **per-episode watched toggles** and **bulk "mark season / show watched"**; next-air date; **source attribution footer** (TMDB logo + notice, or TheTVDB link).
5. **Import** — pick a TV Time / Letterboxd / IMDb / Trakt export; progress bar; a **confirmation list for fuzzy matches** (poster + candidate title/year to accept/replace/skip).
6. **Stats** — episodes watched, hours watched, breakdown by genre and decade, current streak.
7. **Settings** — export / backup, theme (dark/dynamic), about + attribution.

## Priorities
Emphasise **fast bulk-marking** (the TV Time refugee's #1 need) and **offline use**. Empty states should invite an import.

## Deliverable
Provide Flutter widget code per screen (Material 3, no external state-management libs in the mockups — plain `StatefulWidget`/`setState` is fine for the mock; production wires Riverpod). Include a small token set (spacing, radii, the rail-card style, full-width button theme) so it drops into `lib/core/theme/`.

---
*How to use: paste this brief into Claude (Claude Design / an Artifact) to generate the screens, iterate visually, then feed the resulting design system + widget code into issue #36 ("Apply Claude-designed theme/design system").*
