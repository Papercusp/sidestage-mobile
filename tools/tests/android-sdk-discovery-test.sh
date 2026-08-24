#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify Android builds discover a standard SDK without exported SDK variables.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="$ROOT/tools/build-scripts/build-android.sh"
TMP_HOME="$(mktemp -d)"
DEFAULT_SDK="$TMP_HOME/Android/Sdk"
EXPLICIT_SDK="$TMP_HOME/explicit-sdk"
mkdir -p "$DEFAULT_SDK" "$EXPLICIT_SDK"

resolved_default="$(
    env -u ANDROID_HOME -u ANDROID_SDK_ROOT HOME="$TMP_HOME" \
        bash -c 'source "$1"; resolve_android_sdk; printf "%s" "$ANDROID_SDK_ROOT"' \
        bash "$RESOLVER"
)"
[[ "$resolved_default" == "$DEFAULT_SDK" ]] || {
    echo "ERROR: wrapper selected $resolved_default instead of standard SDK $DEFAULT_SDK" >&2
    exit 1
}

resolved_explicit="$(
    env ANDROID_SDK_ROOT="$EXPLICIT_SDK" ANDROID_HOME="$DEFAULT_SDK" HOME="$TMP_HOME" \
        bash -c 'source "$1"; resolve_android_sdk; printf "%s" "$ANDROID_SDK_ROOT"' \
        bash "$RESOLVER"
)"
[[ "$resolved_explicit" == "$EXPLICIT_SDK" ]] || {
    echo "ERROR: wrapper did not prefer ANDROID_SDK_ROOT=$EXPLICIT_SDK" >&2
    exit 1
}

grep -Fq 'System.setProperty("android.home"' "$ROOT/android/settings.gradle.kts"

(
    cd "$ROOT/android"
    env -u ANDROID_HOME -u ANDROID_SDK_ROOT ./gradlew testDebugUnitTest --no-daemon --quiet
)

echo "✓ Android SDK discovery works for the wrapper and direct Gradle unit tests"
