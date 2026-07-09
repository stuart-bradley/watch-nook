set shell := ["bash", "-eo", "pipefail", "-c"]

export PATH := home_directory() / "flutter/bin:" + env("PATH")

default: check

# Code generation (Drift + Riverpod)
codegen:
    dart run build_runner build

# Static analysis
analyze:
    flutter analyze --no-pub

# Format check (fails on unformatted code). Scoped to git-tracked files so it
# ignores the gitignored patrol bundle (integration_test/test_bundle.dart),
# which dart format would otherwise reformat after a local `patrol test`.
# Excludes docs/ to mirror analysis_options' `docs/**` exclude — the delivered
# design-system reference there is reference-only ("its own lint posture"); #4
# lifts the theme into lib/, and those copies ARE formatted/analyzed.
format-check:
    dart format --set-exit-if-changed $(git ls-files '*.dart' ':!docs/')

# Auto-fix formatting (tracked files only, docs excluded — see format-check).
format:
    dart format $(git ls-files '*.dart' ':!docs/')

# Unit + widget tests. No TZ pin — Watchnook has no timezone-sensitive engine
# (the wellquill occurrence engine's DST tests don't apply here).
test:
    flutter test --no-pub

# Full CI check (same as what runs on PRs)
check: codegen analyze format-check test

# Build debug APK. Injects secrets.json (flat dart-defines) WHEN PRESENT so the
# built artifact actually carries an API key — closes the on-device #52 gap where
# a keyless build silently can't reach TMDB. CI ships no secrets.json and builds
# keyless (the intended RemoteConfig.empty path).
build-debug:
    #!/usr/bin/env bash
    set -euo pipefail
    args=(build apk --debug --no-pub)
    [ -f secrets.json ] && args+=(--dart-define-from-file=secrets.json)
    flutter "${args[@]}"

# E2E tests (Patrol). Assumes a running emulator/device + a patrol_cli matching
# the patrol dep on PATH. patrol test auto-discovers integration_test/.
# (integration_test/ + patrol land in M3 — this recipe is inert until then.)
e2e:
    patrol test

# Lint shell scripts. Required: ci-shared's flutter-ci.yml runs `just
# lint-scripts` before `just check`, so the recipe MUST exist. No-op until
# scripts/ has content; shellcheck only runs when there is something to lint.
lint-scripts:
    if git ls-files 'scripts/*.sh' | grep -q .; then shellcheck $(git ls-files 'scripts/*.sh'); else echo "lint-scripts: no scripts to lint"; fi

# Decode the release keystore + write android/key.properties from CI secrets
# (KEYSTORE_BASE64 + STORE_PASSWORD + KEY_ALIAS + KEY_PASSWORD). Consumed by
# release-apk-ci; Gradle falls back to debug signing when it is absent.
release-sign:
    ./scripts/release-sign.sh

# CI-only: build the signed universal release APK with the baked TMDB key, for
# the GitHub-Releases pipeline (ci-shared flutter-release-apk.yml uploads it).
# Needs the TMDB + keystore secrets in env. BUILD_NAME (the release tag, e.g.
# v0.1.0) sets the APK versionName. Writes secrets.json (gitignored) — do not
# run locally with a real secrets.json you want to keep.
release-apk-ci:
    #!/usr/bin/env bash
    set -euo pipefail
    printf '{"activeSource":"tmdb","tmdbApiKey":"%s","tmdbReadToken":"%s","tvdbApiKey":""}' \
      "${TMDB_API_KEY:-}" "${TMDB_READ_TOKEN:-}" > secrets.json
    ./scripts/release-sign.sh
    args=(build apk --release --dart-define-from-file=secrets.json)
    [ -n "${BUILD_NAME:-}" ] && args+=(--build-name="${BUILD_NAME#v}")
    flutter "${args[@]}"

# Install dependencies + generate code
setup:
    flutter pub get
    just codegen

# Clean build artifacts
clean:
    flutter clean
