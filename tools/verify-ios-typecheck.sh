#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Typecheck the iOS app against a REAL iOS SDK, from a Linux host.
#
# WHY THIS EXISTS
# ---------------
# This repo's iOS work is written on Linux, where no Swift toolchain builds an
# iOS target — so plan decision D-006 stops iOS items at "source-complete", and
# every Swift file lands unverified. That is not the same as unverifiable: the
# workspace has a macOS VM with Xcode, and a *typecheck* needs only the SDK, not
# the Rust xcframework a full build would require.
#
# So this script closes the gap the cheap way. It does NOT link, run, or build an
# app bundle; it answers exactly one question — does the Swift compile? — which is
# the question a Linux-hosted author cannot otherwise answer at all.
#
# WHAT IT CHECKS
#   1. the generated UniFFI Swift (SideStageCore) builds as a module
#   2. every file under ios/SideStage/Sources typechecks against it
#   3. every file under ios/SideStageTests typechecks against the app module
#   4. every file under ios/SideStageUITests typechecks against XCTest
#
# WHY LEG 4 EXISTS
#   `ios/project.yml` declares a SideStageUITests target whose `sources` entry is
#   NOT marked `optional: true`, so XcodeGen hard-fails project generation when
#   that directory is missing ("Target \"SideStageUITests\" has a missing source
#   directory", exit 1) — before any build starts. The directory existing is
#   therefore a build precondition, and typechecking what is in it keeps the
#   target honest instead of letting it rot as an unbuilt stub.
#
# FLAG FIDELITY — the part that makes the result trustworthy
# ----------------------------------------------------------
# The flags below mirror what Xcode actually invokes for this project, which is
# NOT what a naive `swiftc` call does. Both of these were established by reading
# Xcode's own Swift.xcspec and then confirming against a real xcodebuild command
# line, after each first appeared to be a repo bug and turned out not to be:
#
#   * -swift-version 5   Xcode NORMALIZES project.yml's SWIFT_VERSION "5.9" to
#                        `-swift-version 5`. Passing "5.9" straight to swiftc is
#                        rejected ("valid arguments are 4, 4.2, 5, 6") — that is
#                        a fact about swiftc, not a defect in project.yml.
#   * -enable-bare-slash-regex
#                        SWIFT_ENABLE_BARE_SLASH_REGEX defaults to YES in Xcode
#                        (Swift.xcspec) for effective Swift versions 4/4.2/5, so
#                        the `/\d+/` literals in LiveEventPresentation.swift are
#                        legal in the real build. Omit this flag and you get 14
#                        phantom errors in a file that is perfectly fine.
#
# Drop either flag and this script reports failures the real build does not have.
#
# USAGE
#   tools/verify-ios-typecheck.sh                 # generate bindings + verify
#   SS_MAC_HOST=… SS_MAC_PORT=… SS_MAC_KEY=…      # override the Mac VM target
#
# EXIT: 0 = everything typechecks · 1 = a real compile error · 2 = setup failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_HOST="${SS_MAC_HOST:-aviweiss@127.0.0.1}"
MAC_PORT="${SS_MAC_PORT:-2222}"
MAC_KEY="${SS_MAC_KEY:-$HOME/.ssh/papercup-vm-mac}"
IOS_TARGET="${SS_IOS_TARGET:-arm64-apple-ios17.0-simulator}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ssh_mac() {
  ssh -i "$MAC_KEY" -p "$MAC_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 "$MAC_HOST" "$@"
}

echo "==> Checking the Mac VM is reachable with a toolchain"
if ! ssh_mac 'xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1'; then
  echo "SETUP FAILED: no reachable Mac VM with an iPhoneSimulator SDK at $MAC_HOST:$MAC_PORT" >&2
  echo "(This script is the only way to compile-verify iOS work from Linux; without" >&2
  echo " it, iOS changes stay source-complete only — see D-006.)" >&2
  exit 2
fi

echo "==> Generating the UniFFI Swift bindings"
cd "$REPO_ROOT"
cargo run -q --bin uniffi-bindgen -- \
  generate crates/sidestage-bindings/src/sidestage.udl \
  --language swift --out-dir "$STAGE" 2>&1 | grep -v 'swiftformat' || true

[ -f "$STAGE/sidestage.swift" ] || { echo "SETUP FAILED: bindings not generated" >&2; exit 2; }

echo "==> Staging the sources"
mkdir -p "$STAGE/app"
cp -r ios/SideStage/Sources "$STAGE/app/Sources"
cp -r ios/SideStageTests "$STAGE/app/SideStageTests"
# A missing SideStageUITests dir is a hard xcodegen failure (see LEG 4 above), so
# refuse to report a green run without it rather than silently skipping the leg.
if [ ! -d ios/SideStageUITests ]; then
  echo "FAIL ios/SideStageUITests is missing — xcodegen generate will fail with" >&2
  echo "     'Target \"SideStageUITests\" has a missing source directory'." >&2
  echo "     Restore the directory, or mark the target's sources optional: true." >&2
  exit 1
fi
cp -r ios/SideStageUITests "$STAGE/app/SideStageUITests"
cp "$STAGE/sidestage.swift" "$STAGE/sidestageFFI.h" "$STAGE/app/"
# uniffi names the map after the module; swiftc wants it discoverable by path.
cp "$STAGE/sidestageFFI.modulemap" "$STAGE/app/module.modulemap"

# The remote half runs under bash explicitly: macOS logs in under zsh, which does
# NOT word-split unquoted parameter expansions, so a `$FLAGS` variable holding a
# flag list arrives as one giant argument and every compile fails identically.
cat > "$STAGE/app/run-typecheck.sh" <<'REMOTE'
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TGT="${IOS_TARGET:-arm64-apple-ios17.0-simulator}"
mkdir -p out
FLAGS=(-swift-version 5 -enable-bare-slash-regex -target "$TGT" -sdk "$SDK"
       -Xcc -fmodule-map-file="$PWD/module.modulemap" -I "$PWD")
status=0

report() { # name, output
  local name="$1" out="$2"
  local errors
  errors="$(printf '%s\n' "$out" | grep -c 'error:' || true)"
  printf '%s\n' "$out" | grep -E 'error:|warning:' | sed "s|$PWD/||" | sort -u | head -40
  if [ "$errors" -gt 0 ]; then
    echo "FAIL $name ($errors errors)"
    status=1
  else
    echo "OK   $name"
  fi
}

# A compile of ZERO files also produces zero errors, so an empty source list
# would report a confident OK while checking nothing. That is the one failure a
# verification harness must never have.
require_files() { # name, count
  if [ "$2" -eq 0 ]; then
    echo "FAIL $1 — found NO source files; this is a harness fault, not a clean run"
    status=1
    return 1
  fi
  return 0
}

# `mapfile` is bash 4; macOS ships bash 3.2, where it silently does not exist
# and leaves the array unset. Read the list the portable way instead.
APP_SOURCES=()
while IFS= read -r f; do APP_SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)
TEST_SOURCES=()
while IFS= read -r f; do TEST_SOURCES+=("$f"); done < <(find SideStageTests -name '*.swift' | sort)
UITEST_SOURCES=()
while IFS= read -r f; do UITEST_SOURCES+=("$f"); done < <(find SideStageUITests -name '*.swift' | sort)

out="$(xcrun swiftc -emit-module -module-name SideStageCore "${FLAGS[@]}" \
        -emit-module-path out/SideStageCore.swiftmodule sidestage.swift 2>&1)"
report "SideStageCore (generated bindings)" "$out"

if require_files "SideStage app sources" "${#APP_SOURCES[@]}"; then
  out="$(xcrun swiftc -typecheck -module-name SideStage "${FLAGS[@]}" -I out \
          "${APP_SOURCES[@]}" 2>&1)"
  report "SideStage app sources (${#APP_SOURCES[@]} files)" "$out"

  out="$(xcrun swiftc -emit-module -module-name SideStage -enable-testing "${FLAGS[@]}" \
          -I out -emit-module-path out/SideStage.swiftmodule "${APP_SOURCES[@]}" 2>&1)"
  report "SideStage app module (for @testable)" "$out"
fi

if require_files "SideStageTests" "${#TEST_SOURCES[@]}"; then
  # XCTest needs BOTH paths: the framework itself lives under the platform's
  # Developer/Library/Frameworks, but its .swiftmodule sits in Developer/usr/lib.
  # Supply only the -F and every XCTAssert resolves as "cannot find in scope" —
  # which reads exactly like broken test code rather than a missing search path.
  PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
  out="$(xcrun swiftc -typecheck -module-name SideStageTests "${FLAGS[@]}" -I out \
          -F "$PLATFORM/Developer/Library/Frameworks" \
          -I "$PLATFORM/Developer/usr/lib" \
          "${TEST_SOURCES[@]}" 2>&1)"
  report "SideStageTests (${#TEST_SOURCES[@]} files)" "$out"
fi

if require_files "SideStageUITests" "${#UITEST_SOURCES[@]}"; then
  # UI tests drive the app out-of-process via XCUIApplication, so unlike the unit
  # tests they neither import the app module nor need -enable-testing — only
  # XCTest itself (same two search paths as above: -F for the framework, -I for
  # its .swiftmodule).
  PLATFORM="${PLATFORM:-$(xcrun --sdk iphonesimulator --show-sdk-platform-path)}"
  out="$(xcrun swiftc -typecheck -module-name SideStageUITests "${FLAGS[@]}" \
          -F "$PLATFORM/Developer/Library/Frameworks" \
          -I "$PLATFORM/Developer/usr/lib" \
          "${UITEST_SOURCES[@]}" 2>&1)"
  report "SideStageUITests (${#UITEST_SOURCES[@]} files)" "$out"
fi

exit $status
REMOTE
chmod +x "$STAGE/app/run-typecheck.sh"

echo "==> Shipping to the Mac VM"
tar czf "$STAGE/bundle.tgz" -C "$STAGE" app
scp -i "$MAC_KEY" -P "$MAC_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
  -q "$STAGE/bundle.tgz" "$MAC_HOST:/tmp/ss-typecheck.tgz"

echo "==> Typechecking against $(ssh_mac 'xcrun --sdk iphonesimulator --show-sdk-version')"
ssh_mac "rm -rf /tmp/ss-typecheck && mkdir -p /tmp/ss-typecheck \
  && tar xzf /tmp/ss-typecheck.tgz -C /tmp/ss-typecheck \
  && IOS_TARGET='$IOS_TARGET' bash /tmp/ss-typecheck/app/run-typecheck.sh"
