#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Archive/export contract for the template consumer; no distribution action.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${1:-archive-preflight}"
VERSION="${SIDESTAGE_IOS_RELEASE_VERSION:-1.0.0}"
BUILD_NUMBER="${SIDESTAGE_IOS_BUILD_NUMBER:-1}"
ARCHIVE="$REPO_ROOT/ios/build/SideStage.xcarchive"
EXPORT_DIR="$REPO_ROOT/ios/build/export"
PROVENANCE="$REPO_ROOT/ios/build/ios-release-provenance.json"
EXPORT_METHOD="app-store-connect"

require_signing() {
  : "${SIDESTAGE_IOS_RELEASE_TEAM_ID:?signing team is required}"
  : "${SIDESTAGE_IOS_RELEASE_CODE_SIGN_IDENTITY:?signing identity is required}"
  : "${SIDESTAGE_IOS_RELEASE_PROVISIONING_PROFILE:?provisioning profile is required}"
}
static_preflight() {
  /usr/libexec/PlistBuddy -c 'Print :method' "$REPO_ROOT/ios/ExportOptions.plist" | grep -qx "$EXPORT_METHOD"
  /usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$REPO_ROOT/ios/SideStage/Resources/PrivacyInfo.xcprivacy" | grep -qx false
  git -C "$REPO_ROOT" status --porcelain --untracked-files=no >/dev/null
}
archive_preflight() {
  static_preflight
  "$REPO_ROOT/tools/build-scripts/build-ios.sh"
  xcodegen generate --spec "$REPO_ROOT/ios/project.yml"
  rm -rf "$ARCHIVE"
  xcodebuild archive -project "$REPO_ROOT/ios/SideStage.xcodeproj" -scheme SideStage \
      -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  mkdir -p "$(dirname "$PROVENANCE")"
  archive_sha256="$(shasum -a 256 "$ARCHIVE/Info.plist" | awk '{print $1}')"
  tmp="$PROVENANCE.tmp.$$"
  printf '{"schemaVersion":"papercusp-ios-release-v1","version":"%s","build":"%s","archiveInfoSha256":"%s","exportMethod":"%s"}\n' \
      "$VERSION" "$BUILD_NUMBER" "$archive_sha256" "$EXPORT_METHOD" > "$tmp"
  mv "$tmp" "$PROVENANCE"
  echo "OK: unsigned archive/export preflight $ARCHIVE"
}
signed_export() {
  require_signing
  xcodebuild archive -project "$REPO_ROOT/ios/SideStage.xcodeproj" -scheme SideStage \
      -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
      DEVELOPMENT_TEAM="$SIDESTAGE_IOS_RELEASE_TEAM_ID" CODE_SIGN_IDENTITY="$SIDESTAGE_IOS_RELEASE_CODE_SIGN_IDENTITY" \
      PROVISIONING_PROFILE_SPECIFIER="$SIDESTAGE_IOS_RELEASE_PROVISIONING_PROFILE" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  rm -rf "$EXPORT_DIR"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$REPO_ROOT/ios/ExportOptions.plist"
}
case "$ACTION" in
  static) static_preflight ;;
  require-signing) require_signing ;;
  archive-preflight) archive_preflight ;;
  signed-export) signed_export ;;
  *) echo "Usage: $0 [static|require-signing|archive-preflight|signed-export]" >&2; exit 2 ;;
esac
