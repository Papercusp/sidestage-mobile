// SPDX-License-Identifier: MIT
//! Pins the Swift status vocabularies to the strings the UniFFI layer can emit.
//!
//! The core models payment and order status as Rust enums, but the FFI boundary
//! flattens them to plain strings through an exhaustive `match`. Swift then
//! compares those strings by hand, with no compiler anywhere in that loop — and
//! that gap is not hypothetical: `isPaymentComplete` shipped matching
//! `"completed"`, a status no layer below it can produce (it is Square's raw
//! upstream token, which the API consumes and translates to `"paid"` before
//! answering a client). The success step was unreachable, so a buyer whose card
//! had been charged was shown "Square did not complete the payment". The Swift
//! unit suite was green throughout, because it asserted the same wrong
//! vocabulary the code used.
//!
//! This guard closes the hole from the side that knows the truth: the set Swift
//! DECLARES it can be handed must be exactly the set the match arms EMIT, and
//! the status Swift treats as success must be a member of it. A variant renamed,
//! added, or dropped on the Rust side fails here rather than in a buyer's hands.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn bindings_source() -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/lib.rs");
    fs::read_to_string(&path).unwrap_or_else(|err| panic!("read {}: {err}", path.display()))
}

fn checkout_presentation_source() -> String {
    let path = repo_root().join("ios/SideStage/Sources/Checkout/CheckoutPresentation.swift");
    fs::read_to_string(&path).unwrap_or_else(|err| panic!("read {}: {err}", path.display()))
}

/// The strings a `match` over `enum_name`'s variants maps to, in `source`.
fn emitted_by_match(source: &str, enum_name: &str) -> BTreeSet<String> {
    let needle = format!("core::{enum_name}::");
    source
        .lines()
        .filter(|line| line.contains(&needle))
        .filter_map(|line| line.split_once("=>"))
        .filter_map(|(_, rhs)| first_string_literal(rhs))
        .collect()
}

/// The literals in a Swift `static let <name>: Set<String> = [ ... ]`.
///
/// `None` distinguishes "the declaration is not there" from "it is there and
/// empty" — the two must not collapse, or a renamed constant would read as an
/// empty set and pass against another empty set.
fn swift_string_set(source: &str, name: &str) -> Option<BTreeSet<String>> {
    let anchor = format!("static let {name}: Set<String> = [");
    let rest = &source[source.find(&anchor)? + anchor.len()..];
    let body = &rest[..rest.find(']')?];
    Some(body.split(',').filter_map(first_string_literal).collect())
}

/// The literal in a Swift `static let <name> = "..."`.
fn swift_string_constant(source: &str, name: &str) -> Option<String> {
    let anchor = format!("static let {name} = ");
    let rest = &source[source.find(&anchor)? + anchor.len()..];
    first_string_literal(rest.lines().next()?)
}

fn first_string_literal(text: &str) -> Option<String> {
    let start = text.find('"')? + 1;
    let end = text[start..].find('"')? + start;
    Some(text[start..end].to_string())
}

/// Assert a pin over sets that are actually populated.
///
/// The non-empty assertions are the point. Two empty sets compare equal, so a
/// guard that silently stopped finding its subjects — a moved file, a renamed
/// constant, a reformatted match — would pass while checking nothing. That is
/// the way a check of this shape fails toward green, and it is the failure mode
/// most likely to go unnoticed, because a passing guard is not investigated.
fn assert_pinned(kind: &str, emitted: &BTreeSet<String>, declared: &BTreeSet<String>) {
    assert!(
        !emitted.is_empty(),
        "found no {kind} match arms in sidestage-bindings/src/lib.rs — this guard \
         stopped reading its subject and would have passed against anything"
    );
    assert!(
        !declared.is_empty(),
        "found no declared {kind} vocabulary in CheckoutPresentation.swift — this \
         guard stopped reading its subject and would have passed against anything"
    );
    assert_eq!(
        emitted, declared,
        "the {kind} vocabulary Swift declares does not match what the bindings emit. \
         Swift compares these as bare strings, so a mismatch is not a type error \
         anywhere — it silently makes a branch unreachable. Update \
         CheckoutPresentation.swift to the bindings' match arms."
    );
}

/// Assert `value` is a status `enum_name` can actually emit.
fn assert_emittable(constant: &str, value: &str, enum_name: &str, emitted: &BTreeSet<String>) {
    assert!(
        !emitted.is_empty(),
        "found no {enum_name} match arms — this guard stopped reading its subject"
    );
    assert!(
        emitted.contains(value),
        "CheckoutPresentation.{constant} is {value:?}, which {enum_name} can never \
         emit (it emits {emitted:?}). That branch is unreachable in production."
    );
}

#[test]
fn swift_payment_status_vocabulary_matches_the_bindings() {
    let emitted = emitted_by_match(&bindings_source(), "PaymentResultStatus");
    let declared = swift_string_set(&checkout_presentation_source(), "paymentStatusVocabulary")
        .expect("CheckoutPresentation.paymentStatusVocabulary is missing or reshaped");
    assert_pinned("payment status", &emitted, &declared);
}

#[test]
fn swift_order_status_vocabulary_matches_the_bindings() {
    let emitted = emitted_by_match(&bindings_source(), "CheckoutOrderStatus");
    let declared = swift_string_set(&checkout_presentation_source(), "orderStatusVocabulary")
        .expect("CheckoutPresentation.orderStatusVocabulary is missing or reshaped");
    assert_pinned("order status", &emitted, &declared);
}

/// The test that would have caught the original defect outright.
///
/// A success check against a status the bindings cannot emit is always a dead
/// branch, whatever the unit tests around it happen to assert.
#[test]
fn the_statuses_swift_treats_as_success_are_ones_the_bindings_can_emit() {
    let swift = checkout_presentation_source();
    let bindings = bindings_source();

    for (constant, enum_name) in [
        ("paidPaymentStatus", "PaymentResultStatus"),
        ("paidOrderStatus", "CheckoutOrderStatus"),
    ] {
        let value = swift_string_constant(&swift, constant)
            .unwrap_or_else(|| panic!("CheckoutPresentation.{constant} is missing or reshaped"));
        assert_emittable(constant, &value, enum_name, &emitted_by_match(&bindings, enum_name));
    }
}

/// Proof that the assertions above can FAIL, kept permanently in the file.
///
/// A guard that has never failed is a guard nobody has tested, and the usual way
/// to test one — mutate the real file, run, restore — is unsafe in this tree: a
/// scheduled sweep commits the whole working tree, so it can capture the mutant
/// during the window the probe legitimately holds it, with nothing having gone
/// wrong. These controls mutate nothing: they drive the same assertion functions
/// with fixture values whose verdict is known, so the falsifiability evidence is
/// re-earned on every run instead of resting on a one-off manual experiment.
#[test]
fn the_pins_reject_what_they_are_supposed_to_reject() {
    let real: BTreeSet<String> = ["paid", "failed", "needs-configuration"]
        .map(String::from)
        .into();

    let rejects = |case: &str, body: fn()| {
        assert!(
            std::panic::catch_unwind(body).is_err(),
            "the guard accepted {case} — it is weaker than it looks"
        );
    };

    // The original defect itself: the success constant Swift shipped was a
    // status no match arm emits. This is the exact comparison that was missing.
    rejects("Square's raw `completed` as the success status", || {
        assert_emittable(
            "paidPaymentStatus",
            "completed",
            "PaymentResultStatus",
            &["paid", "failed", "needs-configuration"].map(String::from).into(),
        )
    });

    rejects("a vocabulary that drifted from the match arms", || {
        assert_pinned(
            "payment status",
            &["paid", "failed", "needs-configuration"].map(String::from).into(),
            &["paid", "failed"].map(String::from).into(),
        )
    });

    // The fail-toward-green cases: two empty sets compare equal, so a guard that
    // silently stopped finding its subject would pass while checking nothing.
    rejects("an unread bindings source", || {
        assert_pinned("payment status", &BTreeSet::new(), &BTreeSet::new())
    });
    rejects("an unread Swift source", || {
        assert_pinned(
            "payment status",
            &["paid", "failed", "needs-configuration"].map(String::from).into(),
            &BTreeSet::new(),
        )
    });

    // And the positive control: with everything correct, it must NOT panic —
    // or the rejections above would be meaningless.
    assert_pinned("payment status", &real, &real.clone());
    assert_emittable("paidPaymentStatus", "paid", "PaymentResultStatus", &real);
}

/// Falsifiability controls for the extractors above.
///
/// A pin is only worth its runtime if the parsing under it genuinely reads
/// content. These run the same functions against fixtures whose answers are
/// known, including the negative cases, so a parser that silently returns
/// nothing is caught here rather than quietly voiding every assertion above.
#[test]
fn the_extractors_read_what_they_claim_to_read() {
    let rust_fixture = r#"
        let status = match result.status {
            core::PaymentResultStatus::Paid => "paid",
            core::PaymentResultStatus::Failed => "failed",
        };
        let other = match order.status {
            core::CheckoutOrderStatus::Pending => "pending",
        };
    "#;
    let payment = emitted_by_match(rust_fixture, "PaymentResultStatus");
    assert_eq!(payment, ["failed", "paid"].map(String::from).into());
    assert_eq!(
        emitted_by_match(rust_fixture, "CheckoutOrderStatus"),
        ["pending"].map(String::from).into()
    );
    // A named enum that is not in the source must yield nothing, not everything.
    assert!(emitted_by_match(rust_fixture, "NoSuchStatus").is_empty());

    let swift_fixture = "    static let vocab: Set<String> = [\"paid\", \"needs-configuration\"]\n\
                             static let one = \"paid\"\n";
    assert_eq!(
        swift_string_set(swift_fixture, "vocab").expect("fixture set parses"),
        ["needs-configuration", "paid"].map(String::from).into()
    );
    assert!(
        swift_string_set(swift_fixture, "absent").is_none(),
        "a missing declaration must be None, never an empty set"
    );
    assert_eq!(swift_string_constant(swift_fixture, "one").as_deref(), Some("paid"));
    assert!(swift_string_constant(swift_fixture, "absent").is_none());
}
