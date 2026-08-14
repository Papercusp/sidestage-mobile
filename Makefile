# SPDX-License-Identifier: MIT

.PHONY: help build-rust test check fmt fmt-check clippy bindings-smoke bindings-swift-smoke bindings-kotlin bindings-swift android android-release test-android-release-provenance ios scaffold-check clean

help:
	@echo "Targets:"
	@echo "  make build-rust     — build the shared Rust workspace"
	@echo "  make test           — run all Rust tests"
	@echo "  make check          — scaffold shape + fmt + clippy + tests"
	@echo "  make bindings-smoke — run the host-side UniFFI boundary smoke (from Rust)"
	@echo "  make bindings-swift-smoke — run the SWIFT host boundary smoke (macOS only)"
	@echo "  make bindings-kotlin — generate UniFFI Kotlin into android/app/src/main/kotlin"
	@echo "  make bindings-swift — generate UniFFI Swift into ios/SideStageCore"
	@echo "  make android        — cargo-ndk build + Gradle debug assemble when available"
	@echo "  make android-release — build a provenance-bound APK+AAB (set PAPERCUP_RELEASE_VERSION)"
	@echo "  make test-android-release-provenance — test release source/version/hash binding"
	@echo "  make ios            — build SideStageCore.xcframework (macOS only)"

build-rust:
	cargo build --workspace

test:
	cargo test --workspace --all-targets

fmt:
	cargo fmt --all

fmt-check:
	cargo fmt --all -- --check

clippy:
	cargo clippy --workspace --all-targets -- -D warnings

scaffold-check:
	./tools/build-scripts/verify-scaffold.sh

check: scaffold-check fmt-check clippy test bindings-smoke test-android-release-provenance

bindings-smoke:
	cargo run --quiet -p sidestage-bindings --bin sidestage-bindings-smoke

# The Swift half of the boundary proof. bindings-smoke calls the FFI from Rust;
# this one calls it from Swift, which is the direction the iOS app uses. macOS
# only — it exits 2 on Linux rather than pretending it verified anything.
bindings-swift-smoke:
	./tools/build-scripts/host-smoke-swift.sh

bindings-kotlin:
	@KTLINT="$$(tools/build-scripts/ensure-ktlint.sh)"; \
	PATH="$$(dirname "$$KTLINT"):$$PATH" cargo run --quiet --bin uniffi-bindgen -- generate \
		crates/sidestage-bindings/src/sidestage.udl \
		--language kotlin \
		--out-dir android/app/src/main/kotlin

bindings-swift:
	cargo run --quiet --bin uniffi-bindgen -- generate \
		crates/sidestage-bindings/src/sidestage.udl \
		--language swift \
		--out-dir ios/SideStageCore

android: bindings-kotlin
	./tools/build-scripts/build-android.sh

android-release: bindings-kotlin
	./tools/build-scripts/build-android.sh release

test-android-release-provenance:
	./tools/tests/android-release-provenance-test.sh

ios:
	./tools/build-scripts/build-ios.sh

clean:
	cargo clean
	rm -rf android/app/src/main/jniLibs ios/SideStageCore.xcframework
