#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build sidestage-bindings for iOS and package SideStageCore.xcframework.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

test -f Cargo.lock
test -f crates/sidestage-bindings/uniffi.toml

if [ "$(uname)" != "Darwin" ]; then
    echo "ERROR: build-ios.sh requires macOS." >&2
    exit 1
fi

for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    rustup target add "$target" >/dev/null
    cargo build --release --target "$target" -p sidestage-bindings
done

mkdir -p target/ios-sim-fat
lipo -create \
    target/aarch64-apple-ios-sim/release/libsidestage.a \
    target/x86_64-apple-ios/release/libsidestage.a \
    -output target/ios-sim-fat/libsidestage.a

cargo run --quiet --bin uniffi-bindgen -- generate \
    crates/sidestage-bindings/src/sidestage.udl \
    --config crates/sidestage-bindings/uniffi.toml \
    --language swift \
    --out-dir ios/SideStageCore
test -f ios/SideStageCore/sidestage.swift
test -f ios/SideStageCore/sidestageFFI.h

mkdir -p ios/SideStageCore/headers
mv -f ios/SideStageCore/sidestageFFI.h ios/SideStageCore/headers/
mv -f ios/SideStageCore/sidestageFFI.modulemap ios/SideStageCore/headers/module.modulemap
test -f ios/SideStageCore/headers/sidestageFFI.h

rm -rf ios/SideStageCore.xcframework
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libsidestage.a \
    -headers ios/SideStageCore/headers \
    -library target/ios-sim-fat/libsidestage.a \
    -headers ios/SideStageCore/headers \
    -output ios/SideStageCore.xcframework

echo "==> xcframework at $REPO_ROOT/ios/SideStageCore.xcframework"
