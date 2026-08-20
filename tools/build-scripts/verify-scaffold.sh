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
    android/settings.gradle.kts
    android/build.gradle.kts
    android/gradlew
    android/gradlew.bat
    android/gradle/wrapper/gradle-wrapper.jar
    android/gradle/wrapper/gradle-wrapper.properties
    android/app/build.gradle.kts
    android/app/src/main/AndroidManifest.xml
    android/app/src/main/kotlin/com/sidestage/mobile/MainActivity.kt
    android/app/src/main/kotlin/com/sidestage/mobile/navigation/NavigationContract.kt
    android/app/src/main/kotlin/com/sidestage/mobile/navigation/SideStageApp.kt
    android/app/src/main/kotlin/com/sidestage/mobile/theme/SideStageTokens.kt
    android/app/src/main/kotlin/com/sidestage/mobile/theme/SideStageTheme.kt
    android/app/src/test/kotlin/com/sidestage/mobile/navigation/NavigationContractTest.kt
    tools/build-scripts/generate-swift-design-tokens.mjs
    ios/SideStage/Sources/SideStageApp.swift
    ios/SideStage/Sources/Navigation/AppNavigation.swift
    ios/SideStage/Sources/Navigation/SideStageRootView.swift
    ios/SideStage/Sources/Buyer/BuyerNavigationView.swift
    ios/SideStage/Sources/Orders/OrdersNavigationView.swift
    ios/SideStage/Sources/Generated/SideStageTokens.swift
    ios/SideStageTests/NavigationScopeTests.swift
)
for path in "${required[@]}"; do
    test -s "$path" || { echo "ERROR: missing scaffold file: $path" >&2; exit 1; }
done

grep -q 'crates/sidestage-core' Cargo.toml
grep -q 'crates/sidestage-bindings' Cargo.toml
grep -q 'crates/sidestage-cli' Cargo.toml
grep -q 'name = "sidestage"' crates/sidestage-bindings/Cargo.toml
grep -q 'cdylib_name = "sidestage"' crates/sidestage-bindings/uniffi.toml
test -x android/gradlew || { echo "ERROR: android/gradlew is missing or not executable" >&2; exit 1; }
grep -q 'BUYER("Buyer")' android/app/src/main/kotlin/com/sidestage/mobile/navigation/NavigationContract.kt
grep -q 'ORDERS("Orders")' android/app/src/main/kotlin/com/sidestage/mobile/navigation/NavigationContract.kt
if grep -Eq '(SELLER|HISTORY|CONFIG|TEST)\(' android/app/src/main/kotlin/com/sidestage/mobile/navigation/NavigationContract.kt; then
    echo "ERROR: Android navigation includes a non-mobile tab" >&2
    exit 1
fi
grep -q 'case buyer' ios/SideStage/Sources/Navigation/AppNavigation.swift
grep -q 'case orders' ios/SideStage/Sources/Navigation/AppNavigation.swift
if grep -Eq 'case (seller|history|config|test)' ios/SideStage/Sources/Navigation/AppNavigation.swift; then
    echo "ERROR: iOS navigation includes a non-mobile tab" >&2
    exit 1
fi

echo "✓ SideStage mobile scaffold shape is complete"
