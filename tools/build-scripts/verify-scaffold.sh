#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Cheap cross-platform acceptance check for the shared repository scaffold.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

required=(
    Cargo.toml
    crates/sidestage-core/Cargo.toml
    crates/sidestage-bindings/Cargo.toml
    crates/sidestage-bindings/src/sidestage.udl
    crates/sidestage-cli/Cargo.toml
    tools/build-scripts/build-android.sh
    tools/build-scripts/build-ios.sh
    design-tokens/mobile.primitives.tokens.json
    design-tokens/mobile.semantic.tokens.json
    design-tokens/mobile.component.tokens.json
)
for path in "${required[@]}"; do
    test -s "$path" || { echo "ERROR: missing scaffold file: $path" >&2; exit 1; }
done

grep -q 'crates/sidestage-core' Cargo.toml
grep -q 'crates/sidestage-bindings' Cargo.toml
grep -q 'crates/sidestage-cli' Cargo.toml
grep -q 'name = "sidestage"' crates/sidestage-bindings/Cargo.toml
grep -q 'cdylib_name = "sidestage"' crates/sidestage-bindings/uniffi.toml

echo "✓ SideStage mobile scaffold shape is complete"
