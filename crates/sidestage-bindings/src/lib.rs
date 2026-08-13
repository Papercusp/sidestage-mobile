// SPDX-License-Identifier: MIT

//! Thin UniFFI boundary for the shared SideStage mobile core.

// UniFFI 0.28 generates a blank line after a doc comment in its scaffolding.
// Keep clippy strict for our code while allowing that generated fragment.
#![allow(clippy::empty_line_after_doc_comments)]

uniffi::include_scaffolding!("sidestage");

fn version() -> String {
    sidestage_core::version()
}
