# SideStage Mobile

Native buyer apps for SideStage, built on one shared Rust core:

- `crates/sidestage-core` — all API, realtime, catalog, cart, and checkout logic.
- `crates/sidestage-bindings` — UniFFI `cdylib`/`staticlib` boundary for Kotlin and Swift.
- `crates/sidestage-cli` — host-side smoke tool for the core.
- `android` — Jetpack Compose shell (authored by the Android plan).
- `ios` — SwiftUI shell (authored by the iPhone plan).
- `tools/build-scripts` — `cargo-ndk` and xcframework build entrypoints.
- `design-tokens` — DTCG sources seeded from the SideStage web app.

This follows the same Option C architecture as
`Papercusp/papercup-rust-mobile`. The Rust crates are the single source of
mobile behavior for both platforms; native shells must not fork business logic.
Devices talk only to the SideStage API. Typesense and Square credentials stay
server-side.

## Host verification

```bash
make scaffold-check
make build-rust
make test
cargo run --bin sidestage
```

Expected CLI output begins with `sidestage-core 0.1.0`.

## Native builds

```bash
make bindings-kotlin  # works on any Rust host
make android          # Linux/macOS with Android SDK + NDK + cargo-ndk
make ios              # macOS/Xcode only; emits ios/SideStageCore.xcframework
```

The shell projects land in subsequent plan items; the root scripts deliberately
skip shell assembly when a project wrapper is not present yet.
