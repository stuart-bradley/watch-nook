#!/usr/bin/env bash
#
# Fail if an Android resource that ONLY Dart names is missing from the
# resource-shrinker keep list.
#
# Why this exists
# ---------------
# R8 resource shrinking runs on Flutter **release** builds and never on debug.
# It keeps a resource only if it can *see* a reference: from the manifest, an
# XML resource, or Java/Kotlin. A resource that Dart names in a string — a
# `flutter_local_notifications` small icon, say, resolved at runtime through
# `Resources.getIdentifier(name, "drawable", pkg)` — is invisible to it, so it
# is stripped from `resources.arsc` and the plugin then throws
# `PlatformException(invalid_icon)` on every call.
#
# The failure only exists in the shipped artifact: `just check`, `flutter run`,
# every emulator run and every widget test are green, because none of them
# builds a shrunk APK. That is what makes it so expensive — it has already bitten
# two of these apps (well-quill, then cog-scroll, where it survived three
# "verified on an emulator" fix attempts and killed the reminder feature in
# production).
#
# The fix is `res/raw/keep.xml`. This asserts nobody forgets it again.
set -euo pipefail

res=android/app/src/main/res
if [[ ! -d $res || ! -d lib ]]; then
  echo "No $res or no lib/ — not a Flutter Android app. Skipping."
  exit 0
fi

keep=$res/raw/keep.xml
fail=0
checked=0

# Every file-based drawable/mipmap the shrinker is able to strip.
while IFS= read -r name; do
  # Is it named by a Dart string literal? Match the *whole* literal — as
  # 'ic_foo' or '@drawable/ic_foo' — never a substring, or a resource called
  # `background` would match any Dart string containing that word.
  #
  # Both quote styles: `prefer_single_quotes` makes double quotes unlikely, but a
  # lint convention is not something a safety gate should depend on — a
  # double-quoted name would otherwise sail straight through unnoticed.
  grep -rqE "['\"](@(drawable|mipmap)/)?${name}['\"]" lib || continue

  checked=$((checked + 1))

  # Is it ALSO referenced somewhere the shrinker can see? Then it keeps the
  # resource on its own and no keep entry is needed (e.g. `@mipmap/ic_launcher`,
  # which the manifest's android:icon already anchors). keep.xml itself does not
  # count as a sighting — that is the thing we are testing for.
  if grep -rlE "\b${name}\b" android/app/src/main \
    --include='*.xml' --include='*.kt' --include='*.java' 2>/dev/null |
    grep -qv '/res/raw/keep\.xml$'; then
    echo "  ok  $name — also referenced from the manifest/XML/Kotlin, shrinker can see it"
    continue
  fi

  # Dart-only. It MUST be pinned, or the release build loses it.
  if grep -qE "\b${name}\b" "$keep" 2>/dev/null; then
    echo "  ok  $name — Dart-only, pinned in ${keep#android/app/src/main/}"
  else
    echo "::error file=$keep::Android resource '$name' is referenced only from Dart, so R8 resource shrinking will strip it from the release build (debug builds are NOT shrunk, so this passes every local check and then breaks in production). Pin it: add tools:keep=\"@drawable/$name\" to $keep"
    fail=1
  fi
done < <(
  find "$res" -type f \( -path '*/drawable*' -o -path '*/mipmap*' \) -printf '%f\n' |
    sed 's/\.[^.]*$//' | sort -u
)

if ((fail)); then
  exit 1
fi

echo "Dart-referenced Android resources: $checked checked, all safe from R8."
