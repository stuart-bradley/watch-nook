#!/usr/bin/env bash
# Materialise the release signing config from CI secrets: decode the keystore
# and write android/key.properties, which android/app/build.gradle.kts reads
# (falling back to debug signing when it is absent). A stable keystore across
# releases is what lets GitHub-Releases users update in place.
#
# Required env: KEYSTORE_BASE64, STORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD.
# Run from the repo root (via `just release-apk-ci`).
set -euo pipefail

: "${KEYSTORE_BASE64:?KEYSTORE_BASE64 is not set}"
: "${STORE_PASSWORD:?STORE_PASSWORD is not set}"
: "${KEY_ALIAS:?KEY_ALIAS is not set}"
: "${KEY_PASSWORD:?KEY_PASSWORD is not set}"

keystore="$(pwd)/android/app/release.jks"   # gitignored (**/*.jks)
printf '%s' "$KEYSTORE_BASE64" | base64 -d > "$keystore"

# android/key.properties is gitignored; storeFile is absolute so Gradle's
# file() resolves it regardless of the module it evaluates in.
cat > android/key.properties <<EOF
storeFile=$keystore
storePassword=$STORE_PASSWORD
keyAlias=$KEY_ALIAS
keyPassword=$KEY_PASSWORD
EOF

echo "release signing configured (keystore + android/key.properties written)"
