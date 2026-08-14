#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KTLINT_VERSION="${SIDESTAGE_KTLINT_VERSION:-1.8.0}"
KTLINT_SHA256="${SIDESTAGE_KTLINT_SHA256:-a3fd620207d5c40da6ca789b95e7f823c54e854b7fade7f613e91096a3706d75}"
KTLINT_URL="${SIDESTAGE_KTLINT_URL:-https://github.com/ktlint/ktlint/releases/download/${KTLINT_VERSION}/ktlint}"
CACHE_ROOT="${SIDESTAGE_KTLINT_CACHE_DIR:-${REPO_ROOT}/target/tools/ktlint}"
INSTALL_DIR="${CACHE_ROOT}/${KTLINT_VERSION}"
KTLINT_BIN="${INSTALL_DIR}/ktlint"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        echo "ERROR: sha256sum or shasum is required to verify ktlint." >&2
        return 1
    fi
}

has_expected_checksum() {
    [ -f "$1" ] && [ "$(sha256_file "$1")" = "$KTLINT_SHA256" ]
}

command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl is required to bootstrap ktlint ${KTLINT_VERSION}." >&2
    exit 1
}
command -v java >/dev/null 2>&1 || {
    echo "ERROR: Java is required to run ktlint ${KTLINT_VERSION}." >&2
    exit 1
}

if ! has_expected_checksum "$KTLINT_BIN"; then
    mkdir -p "$INSTALL_DIR"
    DOWNLOAD="${INSTALL_DIR}/.ktlint.download.$$"
    trap 'rm -f "$DOWNLOAD"' EXIT

    echo "==> Downloading pinned ktlint ${KTLINT_VERSION}" >&2
    curl --fail --location --silent --show-error --retry 3 \
        --output "$DOWNLOAD" "$KTLINT_URL"

    ACTUAL_SHA256="$(sha256_file "$DOWNLOAD")"
    if [ "$ACTUAL_SHA256" != "$KTLINT_SHA256" ]; then
        echo "ERROR: ktlint ${KTLINT_VERSION} checksum mismatch." >&2
        echo "Expected: ${KTLINT_SHA256}" >&2
        echo "Actual:   ${ACTUAL_SHA256}" >&2
        exit 1
    fi

    chmod +x "$DOWNLOAD"
    mv -f "$DOWNLOAD" "$KTLINT_BIN"
    trap - EXIT
fi

chmod +x "$KTLINT_BIN"
echo "==> ktlint ready: $("$KTLINT_BIN" --version)" >&2
printf '%s\n' "$KTLINT_BIN"
