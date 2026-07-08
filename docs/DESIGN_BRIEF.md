# Watchnook — Design Brief

Watchnook is a **local-first, offline-first Android TV & movie tracker** (Flutter, Material 3). No accounts, no social, privacy-forward. It replaces TV Time for people who just want to track what they watch and what's next.

## ✅ Delivered — locked design system
The Claude Design output is committed at **`docs/design/flutter/`** (see its `README.md`); this is the source for issue **#36** (full application) and the `ThemeData` for issue **#4** (theme builder). Locked decisions:
- **Palette:** "A5 Honey · gold" — warm, dark-leaning Material 3, gold primary `#E9BF64`. Full **dark + light** `ColorScheme` shipped.
- **Type:** **Newsreader** (serif) for display / headline / title-large · **Manrope** (body), via `google_fonts` (`^6.2.1`).
- **Chrome:** settings live in the **top bar**; `NavigationBar` shell; Honey app-icon tint.
- **Tokens:** spacing 4/8/12/16/24/32 · radii poster 12 / thumb 8 / card 16 / pill · rail card (elevation 0, 1px `outlineVariant`) · full-width 52px CTA · poster 2:3.
- **Lift into `lib/core/`:** `theme/watchnook_tokens.dart`, `theme/watchnook_theme.dart`, `widgets/poster_placeholder.dart` (ready to drop in once the app is scaffolded).
- **Screens (`features/*`) are `setState` mockups with placeholder data** — visual/UX reference for the feature issues; **reimplement with Riverpod + go_router + real data** per project conventions (do not lift as-is).
- **Port note:** the kit uses `Color.withOpacity()` (deprecated ≥ Flutter 3.27) → replace with `.withValues(alpha:)` when applied so `flutter analyze` stays clean.

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
*This brief was fed to Claude Design; the resulting design system + widget code is delivered in `docs/design/flutter/` (see the "Delivered" section above) and feeds issue #36 ("Apply Claude-designed theme/design system") and #4 (theme builder).*
