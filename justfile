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
# scripts/ exists (release-sign/deploy land with #38); shellcheck only runs
# when there is something to lint.
lint-scripts:
    if git ls-files 'scripts/*.sh' | grep -q .; then shellcheck $(git ls-files 'scripts/*.sh'); else echo "lint-scripts: no scripts yet (release scripts land with #38)"; fi

# Decode the release keystore + write android/key.properties (needs
# KEYSTORE_BASE64 + STORE_PASSWORD + KEY_ALIAS + KEY_PASSWORD env vars).
# scripts/release-sign.sh lands with #38 (release automation, needs-human).
release-sign:
    ./scripts/release-sign.sh

# Build the signed release AAB. (No notification-icon R8 assertion — Watchnook
# has no notification small icon; unlike the skeleton there is nothing for the
# resource shrinker to strip that a runtime string lookup depends on.)
release-build:
    flutter build appbundle --release

# Upload the AAB to Play (needs PLAY_STORE_JSON_KEY + track/status env vars).
# scripts/release-deploy.sh lands with #38 (release automation, needs-human).
release-deploy:
    ./scripts/release-deploy.sh

# Full local release pipeline: verify, then sign/build/deploy.
release: check release-sign release-build release-deploy

# CI release: sign/build/deploy only (`just check` runs in a separate,
# secret-free CI step so codegen/tests never see the signing secrets).
release-ci: release-sign release-build release-deploy

# Install dependencies + generate code
setup:
    flutter pub get
    just codegen

# Clean build artifacts
clean:
    flutter clean
