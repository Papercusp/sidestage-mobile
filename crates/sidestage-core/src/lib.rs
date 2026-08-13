// SPDX-License-Identifier: MIT

//! Shared, UI-agnostic logic for the SideStage mobile apps.
//!
//! The Android Compose and iPhone SwiftUI shells both bind to this crate
//! through `sidestage-bindings`. Product, event, realtime, cart, and checkout
//! behavior belongs here so the native shells cannot drift.

/// Return the core crate version baked into the native library.
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_present() {
        let value = version();
        assert!(!value.is_empty());
        assert!(value.contains('.'));
    }
}
