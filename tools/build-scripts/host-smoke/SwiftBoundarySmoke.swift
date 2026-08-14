// SPDX-License-Identifier: MIT
//
// Swift host smoke for the UniFFI boundary (plan P-002).
//
// WHY THIS EXISTS
// ---------------
// `make bindings-smoke` already proves the boundary from the RUST side, and
// tools/verify-ios-typecheck.sh proves the generated Swift COMPILES. Neither
// proves the thing P-002 actually asks for: that a Swift caller can cross into
// Rust at runtime and get correct values back. A typecheck cannot catch a
// broken modulemap, a missing symbol at link time, an ABI mismatch, or a
// lifting bug in the generated converters — every one of those compiles fine
// and fails only when the call is made.
//
// So this executes. It links the real static library, calls across the FFI, and
// checks the values against the Rust implementation.
//
// WHY THESE ASSERTIONS ARE NOT TAUTOLOGIES
// ----------------------------------------
// The expected values below are derived from the Rust source, not from
// re-running the Swift side and recording whatever it printed:
//
//   crates/sidestage-core/src/realtime.rs:161
//     minimum_next_bid_cents(x) = x.saturating_add(1)
//   crates/sidestage-core/src/realtime.rs:167
//     suggested_bid_cents(x)    = x + max(100, ceil(x*5 / 10_000) * 100)
//                                 i.e. 5% of the price rounded UP to a whole
//                                 dollar, with a $1.00 floor
//   crates/sidestage-core/src/cart.rs:14
//     MAX_CART_QUANTITY         = 99
//
// A boundary that silently truncated i64→i32, mis-signed, or off-by-one'd the
// integer lift would move these numbers, so they are load-bearing.
//
// WHY @main AND NOT TOP-LEVEL CODE
//   Swift permits top-level statements only in a file literally named
//   main.swift. This file keeps a descriptive name, so it needs an explicit
//   entry point; writing the statements at top level here fails to compile with
//   "expressions are not allowed at the top level".
//
// EXIT: 0 = the Swift→Rust boundary works · 1 = a real boundary failure.

import Foundation

@main
struct SwiftBoundarySmoke {
    static var failures: [String] = []

    static func check(_ label: String, _ actual: Any, _ expected: Any) {
        let a = String(describing: actual)
        let e = String(describing: expected)
        if a == e {
            print("  ok   \(label): \(a)")
        } else {
            print("  FAIL \(label): got \(a), want \(e)")
            failures.append(label)
        }
    }

    static func main() {
        print("Swift → Rust UniFFI boundary smoke")

        // 1. String lifting across the boundary (RustBuffer → Swift String).
        let v = version()
        if v.isEmpty {
            print("  FAIL version(): returned an empty string")
            failures.append("version() non-empty")
        } else {
            print("  ok   version(): \(v)")
        }

        // 2. u32 return.
        check("maxCartQuantity()", maxCartQuantity(), UInt32(99))

        // 3. i64 in, i64 out — exclusive lower bound is current + 1.
        check("minimumNextBidCents(0)", minimumNextBidCents(currentPriceCents: 0), Int64(1))
        check("minimumNextBidCents(10000)", minimumNextBidCents(currentPriceCents: 10_000), Int64(10_001))

        // 4. The bid ladder: 5% rounded up to a whole dollar, floored at $1.00.
        //    $100.00 → 5% is exactly $5.00 → $105.00
        check("suggestedBidCents(10000)", suggestedBidCents(currentPriceCents: 10_000), Int64(10_500))
        //    $0.00 → 5% is $0, so the $1.00 floor applies → $1.00
        check("suggestedBidCents(0)", suggestedBidCents(currentPriceCents: 0), Int64(100))
        //    $0.01 → 5% is a fraction of a cent, rounds UP to $1.00 → $1.01
        check("suggestedBidCents(1)", suggestedBidCents(currentPriceCents: 1), Int64(101))
        //    $37.00 → 5% is $1.85, rounds UP to $2.00 → $39.00
        check("suggestedBidCents(3700)", suggestedBidCents(currentPriceCents: 3_700), Int64(3_900))

        // 5. The two rules must stay consistent with each other: a suggested bid
        //    is always acceptable to the server. This is the invariant a buyer
        //    surface depends on, and it spans both functions rather than
        //    restating either.
        for price in [Int64(0), 1, 99, 100, 3_700, 10_000, 999_999] {
            let suggested = suggestedBidCents(currentPriceCents: price)
            let minimum = minimumNextBidCents(currentPriceCents: price)
            if suggested < minimum {
                print("  FAIL suggested(\(price))=\(suggested) is below minimum \(minimum)")
                failures.append("suggested >= minimum at \(price)")
            }
        }
        print("  ok   suggested >= minimum across the price ladder")

        if failures.isEmpty {
            print("BOUNDARY OK — Swift called into Rust and every value matched the core.")
            exit(0)
        } else {
            print("BOUNDARY FAILED — \(failures.count) check(s): \(failures.joined(separator: ", "))")
            exit(1)
        }
    }
}
