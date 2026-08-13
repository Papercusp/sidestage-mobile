# SPDX-License-Identifier: MIT

.PHONY: help build-rust test check fmt fmt-check clippy bindings-kotlin bindings-swift android ios scaffold-check clean

help:
	@echo "Targets:"
	@echo "  make build-rust     — build the shared Rust workspace"
	@echo "  make test           — run all Rust tests"
	@echo "  make check          — scaffold shape + fmt + clippy + tests"
	@echo "  make bindings-kotlin — generate UniFFI Kotlin into android/app/src/main/kotlin"
	@echo "  make bindings-swift — generate UniFFI Swift into ios/SideStageCore"
	@echo "  make android        — cargo-ndk build + Gradle debug assemble when available"
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

check: scaffold-check fmt-check clippy test

bindings-kotlin:
	cargo run --quiet --bin uniffi-bindgen -- generate \
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

ios:
	./tools/build-scripts/build-ios.sh

clean:
	cargo clean
	rm -rf android/app/src/main/jniLibs ios/SideStageCore.xcframework
