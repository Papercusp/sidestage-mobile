#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build and RUN the Swift host smoke against the real UniFFI static library.
#
# This is the executable half of plan P-002 ("host smoke proves the Swift
# boundary"). `make bindings-smoke` proves the boundary from Rust; this proves
# it from Swift, which is the direction the iOS app actually calls in.
#
# It deliberately builds for the HOST (macOS) rather than an iOS target: an iOS
# static library cannot be executed on the build machine, so an iOS-only smoke
# could never be more than a link check. Same library, same generated bindings,
# same FFI — the only difference is the slice, which is what makes running it
# possible at all.
#
# macOS only. On Linux it exits 2 (setup failure) rather than reporting a
# boundary failure it never actually tested.
#
# EXIT: 0 = boundary works · 1 = a real boundary failure · 2 = setup failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [ "$(uname)" != "Darwin" ]; then
    echo "SETUP FAILED: host-smoke-swift.sh requires macOS (needs a Swift toolchain + the host static lib)." >&2
    exit 2
fi

command -v cargo >/dev/null 2>&1 || { echo "SETUP FAILED: cargo not on PATH." >&2; exit 2; }
xcrun --find swiftc >/dev/null 2>&1 || { echo "SETUP FAILED: no swiftc via xcrun." >&2; exit 2; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> building sidestage-bindings for the host"
cargo build --release -p sidestage-bindings

echo "==> generating Swift bindings"
cargo run --quiet --bin uniffi-bindgen -- generate \
    crates/sidestage-bindings/src/sidestage.udl \
    --language swift \
    --out-dir "$STAGE"

# uniffi names the modulemap after the module; swiftc discovers it by path only
# when it is called module.modulemap. Identical handling to
# tools/verify-ios-typecheck.sh — keep the two in step.
mv -f "$STAGE/sidestageFFI.modulemap" "$STAGE/module.modulemap"

echo "==> compiling the Swift smoke against libsidestage.a"
# -swift-version 5 / -enable-bare-slash-regex mirror what Xcode invokes for this
# project (see the flag-fidelity note in tools/verify-ios-typecheck.sh).
# The frameworks are what the Rust TLS/HTTP stack (rustls, reqwest) pulls in on
# macOS; a static Rust lib does not carry its own system-library dependencies.
xcrun swiftc \
    -swift-version 5 \
    -enable-bare-slash-regex \
    -I "$STAGE" \
    -L "$REPO_ROOT/target/release" \
    -lsidestage \
    -framework CoreFoundation \
    -framework Security \
    -framework SystemConfiguration \
    -liconv \
    "$STAGE/sidestage.swift" \
    tools/build-scripts/host-smoke/SwiftBoundarySmoke.swift \
    -o "$STAGE/swift-boundary-smoke"

echo "==> running"
"$STAGE/swift-boundary-smoke"
