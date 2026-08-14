#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/tools/build-scripts/android-release-provenance.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
git -C "$TMP" config user.name test
git -C "$TMP" config user.email test@example.invalid
printf '/android/app/build/\n/bin/\n' >"$TMP/.gitignore"
printf 'source\n' >"$TMP/source.txt"
git -C "$TMP" add .gitignore source.txt
git -C "$TMP" commit -qm initial

APK="$TMP/android/app/build/outputs/apk/release/app-release.apk"
AAB="$TMP/android/app/build/outputs/bundle/release/app-release.aab"
mkdir -p "$(dirname "$APK")" "$(dirname "$AAB")" "$TMP/bin"
dd if=/dev/zero of="$APK" bs=1024 count=2 status=none
printf 'apk' | dd of="$APK" conv=notrunc status=none
dd if=/dev/zero of="$AAB" bs=1024 count=3 status=none
printf 'aab' | dd of="$AAB" conv=notrunc status=none

cat >"$TMP/bin/apkanalyzer" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_APK_VERSION:-0.1.0}"
SH
chmod +x "$TMP/bin/apkanalyzer"

run_helper() {
    PAPERCUP_MOBILE_ROOT="$TMP" PAPERCUP_APKANALYZER="$TMP/bin/apkanalyzer" "$HELPER" "$@"
}

run_helper write 0.1.0 "$APK" "$AAB" >/dev/null
run_helper verify 0.1.0 >/dev/null

MANIFEST="$TMP/android/app/build/outputs/papercusp-release-provenance.json"
node - "$MANIFEST" "$APK" "$AAB" "$(git -C "$TMP" rev-parse HEAD)" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const [manifestFile, apk, aab, commit] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
const hash = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
if (manifest.schemaVersion !== 1 || manifest.releaseVersion !== '0.1.0') process.exit(1);
if (manifest.sourceCommit !== commit || manifest.sourceDirty !== false) process.exit(1);
if (manifest.artifacts.apk.sha256 !== hash(apk) || manifest.artifacts.aab.sha256 !== hash(aab)) process.exit(1);
NODE

printf 'tamper' >>"$APK"
if run_helper verify 0.1.0 >/dev/null 2>&1; then
    echo "FAIL: tampered APK passed provenance verification" >&2
    exit 1
fi
truncate -s 2048 "$APK"
printf 'apk' | dd of="$APK" conv=notrunc status=none

if FAKE_APK_VERSION=9.9.9 run_helper write 0.1.0 "$APK" "$AAB" >/dev/null 2>&1; then
    echo "FAIL: APK version mismatch produced provenance" >&2
    exit 1
fi

printf 'dirty\n' >>"$TMP/source.txt"
if run_helper write 0.1.0 "$APK" "$AAB" >/dev/null 2>&1; then
    echo "FAIL: dirty source produced provenance" >&2
    exit 1
fi

echo "✓ Android release provenance producer rejects version, source, and hash drift"
