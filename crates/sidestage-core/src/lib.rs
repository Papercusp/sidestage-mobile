// SPDX-License-Identifier: MIT

//! Shared, UI-agnostic logic for the SideStage mobile apps.
//!
//! The Android Compose and iPhone SwiftUI shells both bind to this crate
//! through `sidestage-bindings`. Product, event, realtime, cart, and checkout
//! behavior belongs here so the native shells cannot drift.

mod cart;
mod checkout;
mod client;
mod models;
mod orders;
mod realtime;
mod whep;

pub use cart::*;
pub use checkout::*;
pub use client::{
    ApiClient, ApiError, ReadFreshness, ReadSource, ResiliencePolicy, ResilientRead, RetryPolicy,
};
pub use models::*;
pub use orders::*;
pub use realtime::*;
pub use whep::*;

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
