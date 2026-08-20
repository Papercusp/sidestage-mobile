#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Deterministic local-mac test entrypoint used through named host avis-imac.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-unit}"
case "$MODE" in build-only|unit|ui) ;; *) echo "Usage: $0 [build-only|unit|ui]" >&2; exit 2 ;; esac
cd "$REPO_ROOT"
tools/build-scripts/check-ios-build-host-health.sh
tools/build-scripts/build-ios.sh
xcodegen generate --spec ios/project.yml

UDID="${SS_IOS_SIM_UDID:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone.*\((Booted|Shutdown)\)/ { print $2; exit }')}"
[ -n "$UDID" ] || { echo "ERROR: simulator is unavailable" >&2; exit 2; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
DESTINATION="platform=iOS Simulator,id=$UDID"
DERIVED="$REPO_ROOT/ios/build/template-checks/derived-data"
BUILD_RESULT="$REPO_ROOT/ios/build/template-checks/build.xcresult"
rm -rf "$BUILD_RESULT"
xcodebuild build-for-testing -project ios/SideStage.xcodeproj -scheme SideStage \
    -destination "$DESTINATION" -derivedDataPath "$DERIVED" -resultBundlePath "$BUILD_RESULT"
[ "$MODE" = build-only ] && exit 0

BUNDLE=SideStageTests
[ "$MODE" = ui ] && BUNDLE=SideStageUITests
RESULT="$REPO_ROOT/ios/build/template-checks/$MODE.xcresult"
SUMMARY="$REPO_ROOT/ios/build/template-checks/$MODE-summary.json"
rm -rf "$RESULT"
xcodebuild test-without-building -project ios/SideStage.xcodeproj -scheme SideStage \
    -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
    -only-testing:"$BUNDLE" -resultBundlePath "$RESULT"
xcrun xcresulttool get test-results tests --path "$RESULT" --format json > "$SUMMARY"
testsCount="$(grep -o '"testIdentifier"' "$SUMMARY" | wc -l | tr -d ' ')"
[ "$testsCount" -gt 0 ] || { echo "ERROR: $BUNDLE executed zero tests" >&2; exit 1; }
echo "Executed $testsCount tests in $BUNDLE"
