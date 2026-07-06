# Watchnook

A **local-first, backend-free** Android TV & movie tracker — track what you're watching and what's next, mark episodes/movies watched (with bulk actions), see upcoming episodes, and import from the services you already use. No accounts, no social, privacy-forward. Built to replace **TV Time** (shutting down 2026-07-15).

- **Platform:** Flutter (Android-first) · `applicationId com.stuartbradley.watchnook`
- **Data:** on-device only (Drift/SQLite). Metadata from a swappable source (TMDB or TheTVDB v4).
- **Backup:** Android Auto Backup (JSON snapshot) + manual JSON/CSV export/import.

## Docs

- [`docs/PRD.md`](docs/PRD.md) — product, architecture, requirements, user stories, data model, milestones.
- [`docs/GITHUB_ISSUES.md`](docs/GITHUB_ISSUES.md) — milestone/issue breakdown (mirrors the GitHub milestones/issues).
- [`docs/DESIGN_BRIEF.md`](docs/DESIGN_BRIEF.md) — UX/design brief (for Claude Design).
- [`docs/MANUAL_SETUP.md`](docs/MANUAL_SETUP.md) — **do this before starting an autopilot run.**

## Development

Work is tracked via **GitHub Milestones + Issues** (M0–M5), worked lowest-number-first. This repo is set up for an **autopilot** overnight development run — see [`docs/MANUAL_SETUP.md`](docs/MANUAL_SETUP.md) and `.autopilot.json`.
