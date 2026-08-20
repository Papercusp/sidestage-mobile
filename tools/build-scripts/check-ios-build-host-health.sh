#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Local checks executed through the named remote host avis-imac.
set -euo pipefail

[ "$(uname -s)" = Darwin ] || { echo "ERROR: macOS is required (delegate to named host avis-imac)" >&2; exit 2; }
command -v xcodebuild >/dev/null || { echo "ERROR: Xcode is required" >&2; exit 2; }
command -v xcodegen >/dev/null || { echo "ERROR: xcodegen is required" >&2; exit 2; }
command -v swiftformat >/dev/null || { echo "ERROR: swiftformat is required" >&2; exit 2; }
xcrun simctl list devices available | grep -q 'iPhone' || { echo "ERROR: simulator is unavailable" >&2; exit 2; }
echo "OK: avis-imac iPhone build host is ready"
