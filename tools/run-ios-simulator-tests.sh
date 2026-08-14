#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Run the iOS test suites (unit + UI) on a real iPhone simulator, from Linux.
#
# WHY THIS EXISTS
# ---------------
# tools/verify-ios-typecheck.sh answers "does the Swift compile?" — deliberately
# the cheap question, because a typecheck needs only an SDK. It cannot answer
# "does the app WORK", because that needs a linked binary, the Rust xcframework,
# and a booted simulator. This script answers that second question.
#
# It exists as a SCRIPT rather than a remembered sequence of ssh commands because
# the ad-hoc sequence has a specific, repeatable failure:
#
#   error: There is no XCFramework found at '…/ios/SideStageCore.xcframework'
#
# SideStageCore.xcframework is a BUILD PRODUCT, not a tracked file. Any sync that
# mirrors the source tree onto the VM removes it, so a run that assumes "the
# xcframework is already there because a previous run built it" fails at BUILD
# time — before a single test executes. That is not a flake to retry; it is a
# missing step. `make ios` below IS that step, and running it unconditionally is
# what makes this script idempotent: cargo and the sync both cache, so a repeat
# run pays seconds, and a fresh VM pays the full build instead of failing.
#
# WHAT "GREEN" REQUIRES — the anti-false-green rules
# --------------------------------------------------
# `** TEST SUCCEEDED **` ALONE IS NOT A PASS, and this is the trap worth naming:
# a test bundle that builds but executes ZERO tests still reports TEST SUCCEEDED.
# So does a run where a whole bundle was skipped. Both look identical to success
# in the last line of a 4,000-line log. This script therefore requires, per
# bundle: a non-zero executed count. A bundle listed in EXPECTED_BUNDLES that
# never reports an execution is a FAILURE here even if xcodebuild is happy —
# the same principle as require_files() in verify-ios-typecheck.sh.
#
# USAGE
#   tools/run-ios-simulator-tests.sh                  # sync, build, test
#   SS_MAC_HOST=… SS_MAC_PORT=… SS_MAC_KEY=…          # override the Mac VM
#   SS_ONLY_TESTING='SideStageUITests/BuyerLoopUITests'  # narrow the run
#   SS_SKIP_SYNC=1                                    # reuse the VM tree as-is
#
# EXIT: 0 = every expected bundle executed tests and passed
#       1 = a real test/build failure (or a bundle that executed nothing)
#       2 = setup failed (no VM, no toolchain, no simulator)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_HOST="${SS_MAC_HOST:-aviweiss@127.0.0.1}"
MAC_PORT="${SS_MAC_PORT:-2222}"
MAC_KEY="${SS_MAC_KEY:-$HOME/.ssh/papercup-vm-mac}"
REMOTE_DIR="${SS_REMOTE_DIR:-sidestage-mobile}"
LOG="${SS_LOG:-/tmp/sidestage-ios-sim-tests.log}"
EXPECTED_BUNDLES="${SS_EXPECTED_BUNDLES:-SideStageTests SideStageUITests}"

# A NON-INTERACTIVE ssh to macOS gets a minimal PATH: no /usr/local/bin, no
# /opt/homebrew/bin, no ~/.cargo/bin (path_helper and the login shell rc are not
# run). So `command -v xcodegen` answers "not installed" for a tool sitting in
# /usr/local/bin — a false negative that reads exactly like a missing dependency
# and sends you off to install what is already there. Every remote invocation
# below therefore sets the PATH explicitly, preflight included.
REMOTE_PATH='/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH'

ssh_mac() {
  ssh -i "$MAC_KEY" -p "$MAC_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 "$MAC_HOST" "export PATH=\"$REMOTE_PATH\"; $*"
}

echo "==> Preflight: Mac VM, Xcode, xcodegen, simulator runtime"
if ! ssh_mac 'xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1'; then
  echo "SETUP FAILED: no reachable Mac VM with an iPhoneSimulator SDK at $MAC_HOST:$MAC_PORT" >&2
  exit 2
fi
if ! ssh_mac 'command -v xcodegen >/dev/null 2>&1'; then
  echo "SETUP FAILED: xcodegen is not installed on the Mac VM." >&2
  echo "  No .xcodeproj is tracked in this repo, so the project must be GENERATED." >&2
  echo "  Install: brew install xcodegen  (or a release tarball into /usr/local/bin)" >&2
  exit 2
fi

if [ "${SS_SKIP_SYNC:-0}" != "1" ]; then
  echo "==> Syncing the source tree to $MAC_HOST:~/$REMOTE_DIR"
  # --delete keeps the VM honest about REMOVED sources, but three paths must
  # survive it or every run pays a full cold rebuild (and one of them is the
  # xcframework whose disappearance is the whole reason this script exists):
  #   target/       cargo's build cache — 3 iOS arch builds
  #   ios/SideStageCore.xcframework   rebuilt below, but never sourced from here
  #   ios/SideStage.xcodeproj         generated below
  rsync -az --delete \
    --exclude '.git' \
    --exclude 'target' \
    --exclude 'ios/SideStageCore.xcframework' \
    --exclude 'ios/SideStage.xcodeproj' \
    --exclude 'android/build' \
    --exclude 'android/.gradle' \
    -e "ssh -i $MAC_KEY -p $MAC_PORT -o BatchMode=yes -o StrictHostKeyChecking=no" \
    "$REPO_ROOT/" "$MAC_HOST:$REMOTE_DIR/" || { echo "SETUP FAILED: rsync" >&2; exit 2; }
fi

# The remote half runs under bash EXPLICITLY: macOS logs in under zsh, which does
# not word-split unquoted expansions, so a flag list in a variable arrives as one
# argument and every command fails identically (same trap as verify-ios-typecheck).
REMOTE_SCRIPT=$(cat <<REMOTE
#!/bin/bash
set -uo pipefail
cd "\$HOME/$REMOTE_DIR" || exit 2
export PATH="/usr/local/bin:/opt/homebrew/bin:\$HOME/.cargo/bin:\$PATH"

echo "==> make ios (xcframework — a BUILD PRODUCT, never synced; see script header)"
./tools/build-scripts/build-ios.sh
echo "BUILD_IOS_EXIT=\$?"
if [ ! -d ios/SideStageCore.xcframework ]; then
  echo "SETUP FAILED: build-ios.sh did not produce ios/SideStageCore.xcframework"
  exit 2
fi

echo "==> xcodegen generate"
xcodegen generate --spec ios/project.yml
echo "XCODEGEN_EXIT=\$?"

echo "==> selecting a simulator"
# Prefer an already-Booted iPhone (boot is the slow part); otherwise take the
# first available iPhone and boot it. A UDID hardcoded from a previous session
# is exactly the kind of stale reference that makes a rerun fail for a reason
# unrelated to the code under test.
UDID="\$(xcrun simctl list devices available | grep -E 'iPhone.*\(Booted\)' | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
if [ -z "\$UDID" ]; then
  UDID="\$(xcrun simctl list devices available | grep -E '^[[:space:]]*iPhone' | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
  [ -n "\$UDID" ] || { echo "SETUP FAILED: no available iPhone simulator"; exit 2; }
  xcrun simctl boot "\$UDID" 2>/dev/null
fi
echo "SIMULATOR_UDID=\$UDID"
xcrun simctl bootstatus "\$UDID" -b >/dev/null 2>&1

echo "==> xcodebuild test"
ONLY=""
if [ -n "${SS_ONLY_TESTING:-}" ]; then ONLY="-only-testing:${SS_ONLY_TESTING:-}"; fi
cd ios
xcodebuild test \\
  -project SideStage.xcodeproj \\
  -scheme SideStage \\
  -destination "platform=iOS Simulator,id=\$UDID" \\
  \$ONLY
echo "XCODEBUILD_EXIT=\$?"
REMOTE
)

echo "==> Running on the Mac VM (log: $MAC_HOST:$LOG)"
ssh_mac "cat > /tmp/ss-run-ios-sim.sh" <<< "$REMOTE_SCRIPT"
ssh_mac "chmod +x /tmp/ss-run-ios-sim.sh && /tmp/ss-run-ios-sim.sh > '$LOG' 2>&1; echo REMOTE_WRAPPER_EXIT=\$?"

# Pull the log locally. The VERDICT IS COMPUTED FROM THE LOG, never from the ssh
# wrapper's exit code: the wrapper reports on the ssh transport and on the LAST
# command in the remote script (an `echo`), which succeeds regardless of whether
# xcodebuild passed. Reading the wrapper as the verdict is how a failing run gets
# reported as green.
LOCAL_LOG="$(mktemp)"
scp -q -i "$MAC_KEY" -P "$MAC_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
  "$MAC_HOST:$LOG" "$LOCAL_LOG" || { echo "SETUP FAILED: could not retrieve $LOG" >&2; exit 2; }

echo
echo "================ VERDICT ================"

if grep -q 'SETUP FAILED' "$LOCAL_LOG"; then
  grep 'SETUP FAILED' "$LOCAL_LOG" >&2
  exit 2
fi

status=0

# --- gate 1: xcodebuild's own verdict -----------------------------------------
if grep -q '\*\* TEST SUCCEEDED \*\*' "$LOCAL_LOG"; then
  echo "OK   xcodebuild reported TEST SUCCEEDED"
else
  echo "FAIL xcodebuild did not report TEST SUCCEEDED"
  grep -E '^(error|.*error:)|\*\* TEST FAILED \*\*|Testing failed:' "$LOCAL_LOG" \
    | sort -u | head -25
  status=1
fi

# --- gate 2: every expected bundle actually EXECUTED tests ---------------------
# A bundle that builds but runs nothing still yields TEST SUCCEEDED. Attribute
# each "Executed N tests" line to the bundle whose suite line most recently
# opened, then require N>0 for each bundle we expect to have run.
counts="$(awk '
  match($0, /Test Suite .[A-Za-z0-9_]+\.xctest./) {
    s = substr($0, RSTART, RLENGTH); gsub(/Test Suite .|\.xctest./, "", s); bundle = s
  }
  match($0, /Executed [0-9]+ test/) {
    n = $0; sub(/.*Executed /, "", n); sub(/ test.*/, "", n)
    if (bundle != "") { total[bundle] += n; seen[bundle] = 1 }
  }
  END { for (b in seen) printf "%s %d\n", b, total[b] }
' "$LOCAL_LOG")"

for bundle in $EXPECTED_BUNDLES; do
  n="$(printf '%s\n' "$counts" | awk -v b="$bundle" '$1 == b { print $2; exit }')"
  if [ -z "$n" ]; then
    echo "FAIL $bundle — NEVER EXECUTED. It did not run at all; a suite that does not"
    echo "     run cannot pass, however green xcodebuild's last line looks."
    status=1
  elif [ "$n" -eq 0 ]; then
    echo "FAIL $bundle — executed 0 tests (built, then ran nothing)"
    status=1
  else
    echo "OK   $bundle executed $n tests"
  fi
done

# --- report ------------------------------------------------------------------
grep -E 'Executed [0-9]+ tests' "$LOCAL_LOG" | sed 's/^[[:space:]]*/     /' | sort -u | head -10
if [ "$status" -ne 0 ]; then
  echo
  echo "--- failures ---"
  grep -E 'XCTAssert|failed -|error:' "$LOCAL_LOG" | sed 's|.*/sidestage-mobile/||' \
    | sort -u | head -30
  echo
  echo "full log: $MAC_HOST:$LOG  (local copy: $LOCAL_LOG)"
else
  rm -f "$LOCAL_LOG"
fi
exit $status
