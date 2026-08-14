#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the shared UniFFI library for all Android ABIs, then assemble either a
# developer debug APK (default) or the public-release APK+AAB provenance pair.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_MODE="${1:-debug}"
case "$BUILD_MODE" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

RELEASE_VERSION="${PAPERCUP_RELEASE_VERSION:-}"
RELEASE_APK="$REPO_ROOT/android/app/build/outputs/apk/release/app-release.apk"
RELEASE_AAB="$REPO_ROOT/android/app/build/outputs/bundle/release/app-release.aab"
RELEASE_PROVENANCE="$REPO_ROOT/android/app/build/outputs/papercusp-release-provenance.json"
if [ "$BUILD_MODE" = "release" ]; then
    [ -n "$RELEASE_VERSION" ] || {
        echo "ERROR: PAPERCUP_RELEASE_VERSION is required for a release build" >&2
        exit 2
    }
    rm -f "$RELEASE_APK" "$RELEASE_AAB" "$RELEASE_PROVENANCE"
fi

: "${ANDROID_NDK_HOME:=$HOME/Android/Sdk/ndk/27.0.12077973}"
export ANDROID_NDK_HOME

if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: ANDROID_NDK_HOME not found at $ANDROID_NDK_HOME" >&2
    exit 1
fi
if ! command -v cargo-ndk >/dev/null 2>&1 && ! cargo ndk --version >/dev/null 2>&1; then
    echo "ERROR: cargo-ndk is required (cargo install cargo-ndk)" >&2
    exit 1
fi

ANDROID_ABIS=(arm64-v8a armeabi-v7a x86 x86_64)
JNI_LIBS=()
for abi in "${ANDROID_ABIS[@]}"; do
    lib="android/app/src/main/jniLibs/$abi/libsidestage.so"
    mkdir -p "$(dirname "$lib")"
    # Generated outputs must never fall back to a previous invocation when a
    # cross-build fails or cargo decides there is nothing new to copy.
    rm -f "$lib"
    JNI_LIBS+=("$lib")
done

echo "==> Cross-compiling sidestage-bindings for Android"
cargo ndk \
    -t arm64-v8a \
    -t armeabi-v7a \
    -t x86 \
    -t x86_64 \
    -o android/app/src/main/jniLibs \
    build -p sidestage-bindings --release

find android/app/src/main/jniLibs -name 'libsidestage.so' -printf '    %p (%s bytes)\n'

KT_BINDINGS="android/app/src/main/kotlin/uniffi/sidestage/sidestage.kt"
tools/build-scripts/verify-android-uniffi-abi.sh "$KT_BINDINGS" "${JNI_LIBS[@]}"

verify_packaged_abis() {
    local archive="$1" prefix="$2" expected actual
    expected="$(printf '%s\n' "${ANDROID_ABIS[@]}" | sort)"
    actual="$(unzip -Z1 "$archive" \
        | sed -n "s#^${prefix}\\([^/]*\\)/.*\\.so\$#\\1#p" \
        | sort -u)"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: unexpected native ABI set in $archive" >&2
        echo "Expected:" >&2
        printf '    %s\n' "${ANDROID_ABIS[@]}" >&2
        echo "Found:" >&2
        printf '%s\n' "$actual" | sed 's/^/    /' >&2
        exit 1
    fi
    echo "==> Verified packaged ABIs in $(basename "$archive"): ${ANDROID_ABIS[*]}"
}

verify_16kb_alignment() {
    local apk="$1"
    local native_root="$REPO_ROOT/android/app/build/intermediates/merged_native_libs/release/mergeReleaseNativeLibs/out/lib"
    local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
    local objdump zipalign power so checked=0
    objdump="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" \
        -path '*/bin/llvm-objdump' -type f -print -quit)"
    zipalign="$(find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 \
        -name zipalign -type f -print | sort -V | tail -n 1)"
    if [ -z "$objdump" ] || [ -z "$zipalign" ]; then
        echo "ERROR: 16 KB verification requires llvm-objdump and zipalign" >&2
        exit 1
    fi
    for so in "$native_root/arm64-v8a"/*.so "$native_root/x86_64"/*.so; do
        if [ ! -f "$so" ]; then
            echo "ERROR: missing 64-bit native libraries under $native_root" >&2
            exit 1
        fi
        while read -r power; do
            if [ "$power" -lt 14 ]; then
                echo "ERROR: $(basename "$so") has a LOAD segment aligned to 2**$power, not 2**14" >&2
                exit 1
            fi
        done < <("$objdump" -p "$so" | awk '/LOAD/ { sub(/^.*2\*\*/, ""); print }')
        checked=$((checked + 1))
    done
    "$zipalign" -c -P 16 -v 4 "$apk" >/dev/null
    echo "==> Verified 16 KB alignment for $checked 64-bit shared libraries and $(basename "$apk")"
}

if [ -x android/gradlew ]; then
    if [ "$BUILD_MODE" = "release" ]; then
        echo "==> Assembling Android release APK + AAB"
        android/gradlew -p android \
            -PpapercupReleaseVersion="$RELEASE_VERSION" \
            :app:assembleRelease :app:bundleRelease
        verify_packaged_abis "$RELEASE_APK" 'lib/'
        verify_packaged_abis "$RELEASE_AAB" 'base/lib/'
        verify_16kb_alignment "$RELEASE_APK"
        "$REPO_ROOT/tools/build-scripts/android-release-provenance.sh" write \
            "$RELEASE_VERSION" "$RELEASE_APK" "$RELEASE_AAB"
        echo "==> Release APK: $RELEASE_APK"
        echo "==> Release AAB: $RELEASE_AAB"
        echo "==> Provenance: $RELEASE_PROVENANCE"
    else
        echo "==> Assembling Android debug APK"
        android/gradlew -p android :app:assembleDebug
        verify_packaged_abis \
            "$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk" \
            'lib/'
        echo "==> Debug APK: $REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
    fi
else
    echo "==> Android Gradle wrapper not present yet; native libraries are ready."
fi
