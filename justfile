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

# Unit + widget tests.
#
# TZ IS PINNED, and load-bearing. `daysUntil` (up_next) counts calendar days by
# normalising to UTC midnights; the tempting-but-wrong version normalises to
# LOCAL midnights, where a spring-forward day is 23 hours and `.inDays` silently
# floors a day away. Under UTC there is no DST, so the broken and correct
# implementations are IDENTICAL — and GitHub runners default to UTC, so without
# this pin that regression ships green. Europe/London gives the tests real teeth
# (verified: the buggy version returns 0 instead of 1 across 29->30 Mar 2026).
test:
    TZ=Europe/London flutter test --no-pub

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

# Warm the Gradle build for `just e2e`, BEFORE the emulator boots. REQUIRED:
# NOT CALLED IN CI ANY MORE — kept deliberately. The E2E workflow skips its
# warm-build step for patrol apps (`if: !inputs.install-patrol`), because the
# premise this recipe was added on turned out to be false.
#
# The claim was that `patrol test` would find Gradle up to date afterwards. It
# does not. well-quill run 31195967334: `patrol build android` succeeded in
# 5m21s, the emulator booted, and `patrol test` then logged
# "• Building apk with entrypoint test_bundle.dart..." and rebuilt from scratch,
# starving QEMU two minutes later and killing the runner. The 46.5 s "reuse"
# behind the original claim was measured LOCALLY, where both halves share one
# hot Gradle daemon — that does not hold across two CI steps.
#
# So why keep it? It is the rollback. If ci-shared's `v1` tag is ever rolled
# back to a commit whose warm-build step is unconditional, every E2E run here
# dies on "Justfile does not contain recipe 'e2e-build'". Two inert lines are
# cheaper than that failure mode. Remove only once `v1` has settled.
#
# NOT `build-debug`: patrol also needs the androidTest instrumentation APK,
# which `flutter build apk` never produces. Deliberately no
# --dart-define-from-file here even though build-debug has one: `just e2e` runs
# a keyless `patrol test`, and the two halves must pass identical Gradle inputs.

# Pre-build the app + androidTest APKs (unused by CI — see above)
e2e-build:
    patrol build android

# E2E tests (Patrol). Assumes a running emulator/device + a patrol_cli matching
# the patrol dep on PATH. patrol test auto-discovers integration_test/.
#
# BOUNDED, and the bound is load-bearing (#81). A *failing* patrol test never
# exits: the Dart side reports its TestFailure in ~9s and honours its own
# 3-minute Timeout on schedule, then the Gradle instrumentation hangs — 37m and
# 2h0m measured. CI's outer `timeout` caught that at ~33m; locally nothing did.
#
# The dump matters as much as the bound. patrol's stdout carries only "Gradle
# test execution failed with code 1" — the real TestFailure (expected, actual,
# file:line) is ONLY in logcat, and a post-hoc `logcat -d` can miss it once the
# ring buffer has rolled past a long hang. Dumping here, immediately, is what
# makes a failure diagnosable; the workflow's `Dump E2E diagnostics` step then
# carries it to the step log with no change to the vendored flutter-e2e.yml.
#
# Override the bound for a fast local loop: `just e2e 5m`. Extra args go through
# to patrol — and WITH MORE THAN ONE DEVICE ATTACHED you need
# `just e2e 20m --device emulator-5556`: patrol_cli prompts "Please select an
# option (1-2)" and, on non-TTY stdin, loops on that prompt forever. It ignores
# $ANDROID_SERIAL (which only steers the adb dump below). Unbounded that is
# another silent hang; bounded it still burns the whole timeout.
e2e timeout="20m" *args:
    #!/usr/bin/env bash
    # NOT `set -e`: `rc=$?` has to survive a non-zero exit.
    set -uo pipefail
    timeout -k 30s "{{timeout}}" patrol test {{args}}
    rc=$?
    [ "$rc" -eq 0 ] && exit 0
    hint=""
    [ "$rc" -eq 124 ] && hint="e2e: no result within {{timeout}} — a failing test hangs patrol's teardown (#81)"
    [ -z "$hint" ] || echo "$hint"
    # TWO anchors, and the second one is load-bearing. `-A` keeps only the
    # lines AFTER a match, and the app logs a swallowed error at the moment it
    # is caught — BEFORE the framework exception the failing expect raises
    # later. Anchoring on the framework header alone therefore discards exactly
    # the line that explains the failure (the #79 FormatException that read as
    # "you're offline"). `wn-error:` is the stable prefix every app-side error
    # log carries; keep them in step.
    #
    # No `-s`: adb honours $ANDROID_SERIAL, which is how a second attached
    # emulator gets targeted. The fallback covers an ambiguous-device error.
    dump=$(adb logcat -d 2>/dev/null \
      | grep -E -A 30 "EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK|wn-error:" \
      | tail -150)
    [ -n "$dump" ] || dump="e2e: no Flutter exception or wn-error: line in the logcat buffer"
    echo "--- Dart failure (from logcat) ---"
    echo "$dump"
    # Same text into the job summary, so a failed run is diagnosable from the
    # PR page without opening the step log. The hint goes in too: without it a
    # hang renders as a bare exit code plus "nothing found", which reads like a
    # missing log rather than the timeout it is. Written from here, NOT from
    # the workflow: flutter-e2e.yml is a ci-shared fork and a local edit there
    # is dropped by the next re-sync.
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { echo "### E2E failed (exit $rc)"
        [ -z "$hint" ] || echo "$hint"
        echo '```'; echo "$dump"; echo '```'; } \
        >> "$GITHUB_STEP_SUMMARY"
    fi
    exit "$rc"

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
# Needs the TMDB + keystore secrets in env. BUILD_NAME (the tag) sets
# versionName; BUILD_NUMBER (the run number) sets a monotonic versionCode.
# Writes secrets.json (gitignored) — do not run locally with a real secrets.json
# you want to keep.
release-apk-ci:
    #!/usr/bin/env bash
    set -euo pipefail
    # Fail loudly if the baked key is missing: a keyless release APK can't reach
    # TMDB (issue #52 class) yet would ship green. The read token is an optional
    # v4 fallback — empty is fine when the v3 apiKey is present.
    : "${TMDB_API_KEY:?TMDB_API_KEY is not set — the release APK would ship keyless}"
    printf '{"activeSource":"tmdb","tmdbApiKey":"%s","tmdbReadToken":"%s","tvdbApiKey":""}' \
      "$TMDB_API_KEY" "${TMDB_READ_TOKEN:-}" > secrets.json
    ./scripts/release-sign.sh
    args=(build apk --release --dart-define-from-file=secrets.json)
    [ -n "${BUILD_NAME:-}" ] && args+=(--build-name="${BUILD_NAME#v}")
    [ -n "${BUILD_NUMBER:-}" ] && args+=(--build-number="$BUILD_NUMBER")
    flutter "${args[@]}"

# Install dependencies + generate code
setup:
    flutter pub get
    just codegen

# Clean build artifacts
clean:
    flutter clean
