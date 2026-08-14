#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Write or verify the one publishable Android release candidate contract.
set -euo pipefail

REPO_ROOT="${PAPERCUP_MOBILE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MANIFEST_REL="android/app/build/outputs/papercusp-release-provenance.json"
APK_REL="android/app/build/outputs/apk/release/app-release.apk"
AAB_REL="android/app/build/outputs/bundle/release/app-release.aab"
MANIFEST="$REPO_ROOT/$MANIFEST_REL"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

source_commit() {
    git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null \
        || die "$REPO_ROOT is not a git checkout"
}

assert_clean_source() {
    local dirty
    dirty="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)"
    [[ -z "$dirty" ]] || {
        echo "ERROR: Android release provenance requires a clean source tree; these paths are not in HEAD:" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    }
}

resolve_apkanalyzer() {
    if [[ -n "${PAPERCUP_APKANALYZER:-}" ]]; then
        printf '%s\n' "$PAPERCUP_APKANALYZER"
        return 0
    fi
    local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
    local analyzer="$sdk_root/cmdline-tools/latest/bin/apkanalyzer"
    [[ -x "$analyzer" ]] || die "apkanalyzer not found at $analyzer"
    printf '%s\n' "$analyzer"
}

assert_canonical_artifact() {
    local supplied="$1" expected_rel="$2" supplied_real expected_real
    [[ -f "$supplied" ]] || die "required Android release artifact missing: $supplied"
    supplied_real="$(realpath "$supplied")"
    expected_real="$(realpath "$REPO_ROOT/$expected_rel")"
    [[ "$supplied_real" == "$expected_real" ]] \
        || die "non-canonical Android artifact path: got $supplied_real, expected $expected_real"
}

write_manifest() {
    local version="$1" apk="${2:-$REPO_ROOT/$APK_REL}" aab="${3:-$REPO_ROOT/$AAB_REL}"
    local commit analyzer apk_version built_at tmp
    [[ -n "$version" ]] || die "release version is required"
    assert_canonical_artifact "$apk" "$APK_REL"
    assert_canonical_artifact "$aab" "$AAB_REL"
    assert_clean_source
    commit="$(source_commit)"
    analyzer="$(resolve_apkanalyzer)"
    apk_version="$("$analyzer" manifest version-name "$apk")"
    [[ "$apk_version" == "$version" ]] \
        || die "APK versionName is $apk_version, but requested release version is $version"
    built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$MANIFEST")"
    tmp="${MANIFEST}.tmp.$$"
    RELEASE_VERSION="$version" SOURCE_COMMIT="$commit" BUILT_AT="$built_at" \
        APK_SIZE="$(stat -c%s "$apk")" APK_SHA256="$(sha256_file "$apk")" \
        AAB_SIZE="$(stat -c%s "$aab")" AAB_SHA256="$(sha256_file "$aab")" \
        node - "$tmp" <<'NODE'
const fs = require('node:fs');
const out = process.argv[2];
const artifact = (kind, relativePath, size, sha256) => ({
  kind,
  path: relativePath,
  size: Number(size),
  sha256,
});
const manifest = {
  schemaVersion: 1,
  releaseVersion: process.env.RELEASE_VERSION,
  sourceCommit: process.env.SOURCE_COMMIT,
  sourceDirty: false,
  builtAt: process.env.BUILT_AT,
  artifacts: {
    apk: artifact('apk', 'android/app/build/outputs/apk/release/app-release.apk', process.env.APK_SIZE, process.env.APK_SHA256),
    aab: artifact('aab', 'android/app/build/outputs/bundle/release/app-release.aab', process.env.AAB_SIZE, process.env.AAB_SHA256),
  },
};
fs.writeFileSync(out, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
NODE
    mv -f "$tmp" "$MANIFEST"
    verify_manifest "$version"
    echo "==> Android release provenance: $MANIFEST"
}

verify_manifest() {
    local version="$1" commit
    [[ -f "$MANIFEST" ]] || die "Android release provenance missing: $MANIFEST"
    assert_clean_source
    commit="$(source_commit)"
    EXPECTED_VERSION="$version" EXPECTED_COMMIT="$commit" \
        REPO_ROOT="$REPO_ROOT" MANIFEST="$MANIFEST" node <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const fail = (message) => { throw new Error(message); };
const hashFile = (file) => {
  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(file, 'r');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    for (;;) {
      const count = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (count === 0) break;
      hash.update(buffer.subarray(0, count));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
};

let manifest;
try { manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, 'utf8')); }
catch (error) { fail(`cannot parse provenance manifest: ${error.message}`); }
if (manifest.schemaVersion !== 1) fail(`unsupported schemaVersion ${manifest.schemaVersion}`);
if (manifest.releaseVersion !== process.env.EXPECTED_VERSION) fail('releaseVersion mismatch');
if (manifest.sourceCommit !== process.env.EXPECTED_COMMIT) fail('sourceCommit mismatch');
if (manifest.sourceDirty !== false) fail('sourceDirty must be false');
for (const [kind, rel] of [
  ['apk', 'android/app/build/outputs/apk/release/app-release.apk'],
  ['aab', 'android/app/build/outputs/bundle/release/app-release.aab'],
]) {
  const entry = manifest.artifacts?.[kind];
  if (!entry || entry.kind !== kind || entry.path !== rel) fail(`${kind} path/kind mismatch`);
  const file = path.join(process.env.REPO_ROOT, rel);
  const stat = fs.statSync(file);
  if (!stat.isFile() || stat.size !== entry.size) fail(`${kind} size mismatch`);
  if (!/^[0-9a-f]{64}$/.test(entry.sha256) || hashFile(file) !== entry.sha256) fail(`${kind} sha256 mismatch`);
}
NODE
}

case "${1:-}" in
    write)
        [[ $# -ge 2 && $# -le 4 ]] || die "usage: $0 write <version> [apk] [aab]"
        write_manifest "$2" "${3:-$REPO_ROOT/$APK_REL}" "${4:-$REPO_ROOT/$AAB_REL}"
        ;;
    verify)
        [[ $# -eq 2 ]] || die "usage: $0 verify <version>"
        verify_manifest "$2"
        echo "==> Verified Android release provenance for $2"
        ;;
    path)
        [[ $# -eq 1 ]] || die "usage: $0 path"
        printf '%s\n' "$MANIFEST"
        ;;
    *)
        die "usage: $0 {write <version> [apk] [aab]|verify <version>|path}"
        ;;
esac
