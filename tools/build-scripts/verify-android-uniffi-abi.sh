#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify that generated Kotlin and every Android library describe the same
# UniFFI API. This catches stale or partially copied .so files before Gradle.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <sidestage.kt> <libsidestage.so>..." >&2
    exit 2
fi

KT_BINDINGS="$1"
shift
READELF_BIN="${READELF:-readelf}"

if [ ! -s "$KT_BINDINGS" ]; then
    echo "ERROR: generated Kotlin bindings missing or empty: $KT_BINDINGS" >&2
    exit 1
fi
if ! command -v "$READELF_BIN" >/dev/null 2>&1; then
    echo "ERROR: readelf is required to verify Android UniFFI ABI exports" >&2
    exit 1
fi

mapfile -t EXPECTED < <(
    sed -nE 's/^[[:space:]]*fun (uniffi_sidestage_checksum_[A-Za-z0-9_]+)\(.*/\1/p' "$KT_BINDINGS" \
        | sort -u
)
if [ "${#EXPECTED[@]}" -eq 0 ]; then
    echo "ERROR: no UniFFI checksum symbols found in $KT_BINDINGS" >&2
    exit 1
fi

FAILED=0
for so in "$@"; do
    if [ ! -s "$so" ]; then
        echo "ERROR: Android ABI library missing or empty: $so" >&2
        FAILED=1
        continue
    fi

    mapfile -t EXPORTED < <(
        "$READELF_BIN" -Ws "$so" \
            | awk '$8 ~ /^uniffi_sidestage_checksum_/ { print $8 }' \
            | sort -u
    )
    mapfile -t MISSING < <(
        comm -23 \
            <(printf '%s\n' "${EXPECTED[@]}") \
            <(printf '%s\n' "${EXPORTED[@]}")
    )
    if [ "${#MISSING[@]}" -gt 0 ]; then
        echo "ERROR: $so is missing UniFFI checksum exports required by $KT_BINDINGS:" >&2
        printf '  %s\n' "${MISSING[@]}" >&2
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi

echo "==> Verified ${#EXPECTED[@]} UniFFI checksum symbols across $# Android ABI libraries"
