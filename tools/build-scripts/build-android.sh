#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the shared UniFFI library for all Android ABIs, then assemble the
# native shell when its Gradle wrapper is present.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

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

rm -rf android/app/src/main/jniLibs
mkdir -p android/app/src/main/jniLibs

echo "==> Cross-compiling sidestage-bindings for Android"
cargo ndk \
    -t arm64-v8a \
    -t armeabi-v7a \
    -t x86 \
    -t x86_64 \
    -o android/app/src/main/jniLibs \
    build -p sidestage-bindings --release

find android/app/src/main/jniLibs -name 'libsidestage.so' -printf '    %p (%s bytes)\n'

if [ -x android/gradlew ]; then
    echo "==> Assembling Android debug APK"
    android/gradlew -p android :app:assembleDebug
else
    echo "==> Android Gradle wrapper not present yet; native libraries are ready."
fi
