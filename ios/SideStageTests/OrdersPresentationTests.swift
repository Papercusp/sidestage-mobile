// SPDX-License-Identifier: MIT

import XCTest
@testable import SideStage

/// Tests for the Orders rules that are pure enough to assert without a core
/// client or a running API.
///
/// The bar these hold: every wording and formatting rule here is one the *web*
/// Orders tab also applies (`apps/web/src/OrdersTab.tsx`), so a divergence shows
/// up as a red test rather than as an order that reads one way on the phone and
/// another in the browser.
final class OrdersPresentationTests: XCTestCase {
    // MARK: - Status labels (parity with the web's orderStatusLabel)

    func testStatusLabelsMatchTheWebSurface() {
        XCTAssertEqual(OrdersPresentation.statusLabel("paid"), "Paid")
        XCTAssertEqual(OrdersPresentation.statusLabel("accepted"), "Offer accepted")
        XCTAssertEqual(OrdersPresentation.statusLabel("failed"), "Payment failed")
        XCTAssertEqual(OrdersPresentation.statusLabel("expired"), "Offer expired")
        XCTAssertEqual(OrdersPresentation.statusLabel("cancelled"), "Cancelled")
    }

    /// The web's default branch. An unrecognised status must NOT read as
    /// settled — "Pending" is the reading that does not claim money moved.
    func testUnknownStatusFallsBackToPending() {
        XCTAssertEqual(OrdersPresentation.statusLabel("pending"), "Pending")
        XCTAssertEqual(OrdersPresentation.statusLabel("some_future_state"), "Pending")
        XCTAssertEqual(OrdersPresentation.statusLabel(""), "Pending")
    }

    func testStatusLabelIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(OrdersPresentation.statusLabel("  PAID "), "Paid")
        XCTAssertEqual(OrdersPresentation.statusLabel("Failed"), "Payment failed")
    }

    /// Both spellings reach the API depending on who wrote the row; neither may
    /// silently degrade to "Pending".
    func testBothCancelledSpellingsAreRecognised() {
        XCTAssertEqual(OrdersPresentation.statusLabel("canceled"), "Cancelled")
        XCTAssertTrue(OrdersPresentation.isFailed("canceled"))
    }

    func testSettledAndFailedAreDisjointAndDoNotClaimUnknownStates() {
        XCTAssertTrue(OrdersPresentation.isSettled("paid"))
        XCTAssertTrue(OrdersPresentation.isSettled("accepted"))
        XCTAssertFalse(OrdersPresentation.isFailed("paid"))

        XCTAssertTrue(OrdersPresentation.isFailed("failed"))
        XCTAssertTrue(OrdersPresentation.isFailed("expired"))
        XCTAssertFalse(OrdersPresentation.isSettled("failed"))

        // An unknown status is neither — it must not be coloured as success.
        XCTAssertFalse(OrdersPresentation.isSettled("some_future_state"))
        XCTAssertFalse(OrdersPresentation.isFailed("some_future_state"))
    }

    // MARK: - Money

    func testMoneyUsesTheAppWideFormatter() {
        XCTAssertEqual(
            OrdersPresentation.formatPrice(cents: 4_800),
            LiveEventPresentation.formatPrice(cents: 4_800)
        )
        XCTAssertEqual(OrdersPresentation.formatPrice(cents: 4_800), "$48.00")
        XCTAssertEqual(OrdersPresentation.formatPrice(cents: 0), "$0.00")
    }

    func testItemLineJoinsQuantityAndUnitPriceAsTheWebDoes() {
        XCTAssertEqual(
            OrdersPresentation.itemLine(quantity: 2, unitPriceCents: 2_400),
            "2 × $24.00"
        )
        XCTAssertEqual(
            OrdersPresentation.itemLine(quantity: 1, unitPriceCents: 99),
            "1 × $0.99"
        )
    }

    /// The web renders the shipping note only when shipping was charged.
    func testShippingNoteAppearsOnlyWhenShippingWasCharged() {
        XCTAssertEqual(
            OrdersPresentation.shippingNote(shippingCents: 800),
            "Includes $8.00 shipping"
        )
        XCTAssertNil(OrdersPresentation.shippingNote(shippingCents: 0))
        XCTAssertNil(OrdersPresentation.shippingNote(shippingCents: -1))
    }

    // MARK: - Dates

    /// The API emits timestamps both with and without fractional seconds; both
    /// have to parse or half the buyer's orders read "Date unavailable".
    func testParsesBothIso8601ShapesTheApiEmits() {
        XCTAssertNotNil(OrdersPresentation.parseDate("2026-08-14T13:37:30.561Z"))
        XCTAssertNotNil(OrdersPresentation.parseDate("2026-08-14T13:37:30Z"))
        XCTAssertEqual(
            OrdersPresentation.parseDate("2026-08-14T13:37:30.000Z"),
            OrdersPresentation.parseDate("2026-08-14T13:37:30Z")
        )
    }

    func testUnparseableTimestampsSaySoRatherThanRenderingGarbage() {
        XCTAssertNil(OrdersPresentation.parseDate(""))
        XCTAssertNil(OrdersPresentation.parseDate("not a date"))
        XCTAssertEqual(OrdersPresentation.formatDate("not a date"), "Date unavailable")
        XCTAssertEqual(OrdersPresentation.formatDate(""), "Date unavailable")
    }

    /// Pinned to a fixed locale + zone so the assertion is about the format
    /// rule, not about where the test machine happens to be.
    func testFormatsDateAsMediumDateAndShortTime() {
        let formatted = OrdersPresentation.formatDate(
            "2026-08-14T13:37:30Z",
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC") ?? .current
        )
        XCTAssertTrue(formatted.contains("Aug"), formatted)
        XCTAssertTrue(formatted.contains("14"), formatted)
        XCTAssertTrue(formatted.contains("2026"), formatted)
        XCTAssertTrue(formatted.contains("1:37"), formatted)
    }

    // MARK: - Ordering

    func testNewestOrdersSortFirst() {
        XCTAssertTrue(
            OrdersPresentation.isOrderedBefore(
                lhsCreatedAt: "2026-08-14T13:37:30Z",
                lhsID: "b",
                rhsCreatedAt: "2026-08-13T09:00:00Z",
                rhsID: "a"
            )
        )
        XCTAssertFalse(
            OrdersPresentation.isOrderedBefore(
                lhsCreatedAt: "2026-08-13T09:00:00Z",
                lhsID: "a",
                rhsCreatedAt: "2026-08-14T13:37:30Z",
                rhsID: "b"
            )
        )
    }

    /// An order whose timestamp will not parse is still the buyer's order:
    /// it sorts last, and is never dropped.
    func testUndatedOrdersSortLastRatherThanDisappearing() {
        XCTAssertTrue(
            OrdersPresentation.isOrderedBefore(
                lhsCreatedAt: "2026-08-13T09:00:00Z",
                lhsID: "dated",
                rhsCreatedAt: "",
                rhsID: "undated"
            )
        )
        XCTAssertFalse(
            OrdersPresentation.isOrderedBefore(
                lhsCreatedAt: "",
                lhsID: "undated",
                rhsCreatedAt: "2026-08-13T09:00:00Z",
                rhsID: "dated"
            )
        )
    }

    /// A total order: two orders sharing a timestamp must not swap places
    /// between renders.
    func testIdenticalTimestampsBreakTiesDeterministicallyById() {
        let stamp = "2026-08-14T13:37:30Z"
        XCTAssertTrue(
            OrdersPresentation.isOrderedBefore(
                lhsCreatedAt: stamp, lhsID: "aaa",
                rhsCreatedAt: stamp, rhsID: "bbb"
            )
        )
        XCTAssertFalse(
            OrdersPresentation.isOrderedBefore(
                lhsCreatedAt: stamp, lhsID: "bbb",
                rhsCreatedAt: stamp, rhsID: "aaa"
            )
        )
        // ...and the same holds when neither parses, so an all-undated list is
        // still stable.
        XCTAssertTrue(
            OrdersPresentation.isOrderedBefore(
                lhsCreatedAt: "", lhsID: "aaa",
                rhsCreatedAt: "", rhsID: "bbb"
            )
        )
    }

    // MARK: - Wording

    func testItemCountLabelIsSingularForOne() {
        XCTAssertEqual(OrdersPresentation.itemCountLabel(1), "1 item")
        XCTAssertEqual(OrdersPresentation.itemCountLabel(0), "0 items")
        XCTAssertEqual(OrdersPresentation.itemCountLabel(3), "3 items")
    }

    func testFailureMessageDegradesWithoutADetail() {
        XCTAssertEqual(
            OrdersPresentation.failureMessage(detail: nil),
            "Your orders could not be loaded."
        )
        XCTAssertEqual(
            OrdersPresentation.failureMessage(detail: "   "),
            "Your orders could not be loaded."
        )
        XCTAssertEqual(
            OrdersPresentation.failureMessage(detail: "HTTP 500"),
            "Your orders could not be loaded: HTTP 500"
        )
    }

    func testOrderReferenceNamesTheOrder() {
        XCTAssertEqual(OrdersPresentation.orderReference(id: "order-1"), "Order order-1")
    }
}
