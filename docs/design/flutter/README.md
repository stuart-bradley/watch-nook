# Watchnook — theme & screens (Honey · gold)

Locked direction: **A5 Honey · gold** · **Newsreader (serif headings) + Manrope (body)** · settings in the top bar · Honey app-icon tint.

## Structure

```
lib/
  core/
    theme/
      watchnook_tokens.dart   # spacing, radii, rail-card + poster decorations
      watchnook_theme.dart    # ColorScheme (dark + light), TextTheme, button/chip/nav themes
    widgets/
      poster_placeholder.dart # offline poster stand-in + TypeBadge
  features/
    library/library_screen.dart      # filter rail + poster grid → detail
    up_next/up_next_screen.dart       # this week, grouped by day
    search/search_screen.dart         # results + inline status picker
    detail/title_detail_screen.dart   # per-episode toggles + bulk mark
    import/import_screen.dart         # source pick, progress, fuzzy match
    stats/stats_screen.dart           # totals, streak, genre/decade bars
    settings/settings_screen.dart     # appearance, backup, attribution
  main.dart                   # MaterialApp + NavigationBar shell + routes
```

All seven screens are implemented. Navigation: Library card → `/detail`,
Settings → `/import`. Bulk-marking lives on Title detail (`Mark season` /
`Mark show` tonal buttons + tap-to-toggle episode rows).

## Dependency

```yaml
dependencies:
  google_fonts: ^6.2.1
```

Prefer bundling the fonts? Add Newsreader + Manrope to `pubspec.yaml` assets and replace the `GoogleFonts.*TextTheme` calls in `watchnook_theme.dart` with `TextStyle(fontFamily: ...)`.

## Token recap

- **Spacing** xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32
- **Radii** poster/thumb 12/8 · card 16 · pill · CTA corner 12
- **Rail card** `WatchnookTokens.railCard(context)` — elevation 0, 1px `outlineVariant`
- **Full-width CTA** 52px `FilledButton` (primary) / `OutlinedButton` (secondary), `TextButton` inline
- **Poster** 2:3

## Notes

- Dark-leaning by default; a full light `ColorScheme` ships too. Swap `themeMode`, or wire `dynamic_color` for Material You.
- Colour is never the sole signal — type is always shown with a label/icon.
- Filtering / toggles use `setState` in the mock; swap for Riverpod in production.
- Poster images are placeholders (offline-first) — wire TMDB/`CachedNetworkImage` where `PosterPlaceholder` is used.
