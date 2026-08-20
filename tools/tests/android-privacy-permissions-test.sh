#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify the merged release manifest keeps SideStage's exact permission and cleartext policy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_MANIFEST="$ROOT/android/app/src/main/AndroidManifest.xml"
MERGED_MANIFEST="$ROOT/android/app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml"

node - "$SOURCE_MANIFEST" <<'NODE'
const fs = require('node:fs');
const xml = fs.readFileSync(process.argv[2], 'utf8');
if (!xml.includes('android:usesCleartextTraffic="${usesCleartextTraffic}"')) {
  throw new Error('source manifest must use the build-type cleartext placeholder');
}
const permissions = [...xml.matchAll(/<uses-permission\b[^>]*android:name="([^"]+)"[^>]*>/g)].map((match) => match[1]);
if (JSON.stringify(permissions) !== JSON.stringify(['android.permission.INTERNET'])) {
  throw new Error(`source permissions must be exactly INTERNET, got: ${permissions.join(', ')}`);
}
NODE

(cd "$ROOT/android" && ./gradlew :app:processReleaseMainManifest --no-daemon --quiet)

node - "$MERGED_MANIFEST" <<'NODE'
const fs = require('node:fs');
const xml = fs.readFileSync(process.argv[2], 'utf8');
const permissions = [...xml.matchAll(/<uses-permission\b[^>]*android:name="([^"]+)"[^>]*>/g)].map((match) => match[1]).sort();
const allowed = [
  'android.permission.ACCESS_NETWORK_STATE',
  'android.permission.INTERNET',
  'com.sidestage.mobile.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
];
if (JSON.stringify(permissions) !== JSON.stringify(allowed)) {
  throw new Error(`merged release permissions differ from the dependency-aware allowlist, got: ${permissions.join(', ')}`);
}
if (!/android:usesCleartextTraffic="false"/.test(xml)) {
  throw new Error('merged release manifest must disable cleartext traffic');
}
NODE

echo "✓ SideStage release manifest allows only INTERNET and disables cleartext traffic"
