// SPDX-License-Identifier: MIT

import XCTest
@testable import SideStage

/// Tests for the checkout rules that are pure enough to assert without a core
/// client or a running API.
///
/// The bar these hold: every rule here is one the *web* checkout also enforces,
/// so a divergence shows up as a red test rather than as a buyer whose address
/// is accepted on one surface and refused on the other.
final class CheckoutPresentationTests: XCTestCase {
    // MARK: - Steps

    func testStepTitlesMatchTheWebSurface() {
        XCTAssertEqual(CheckoutPresentation.Step.cart.title, "Your cart")
        XCTAssertEqual(CheckoutPresentation.Step.address.title, "Where should it go?")
        XCTAssertEqual(CheckoutPresentation.Step.shipping.title, "Choose shipping")
        XCTAssertEqual(CheckoutPresentation.Step.payment.title, "Square sandbox")
        XCTAssertEqual(CheckoutPresentation.Step.success.title, "Order confirmed")
    }

    func testBackNavigationWalksTheLadderInReverse() {
        XCTAssertEqual(CheckoutPresentation.Step.payment.previous, .shipping)
        XCTAssertEqual(CheckoutPresentation.Step.shipping.previous, .address)
        XCTAssertEqual(CheckoutPresentation.Step.address.previous, .cart)
    }

    /// A paid order must not be re-enterable: going "back" into payment invites
    /// a second charge, so success is deliberately terminal.
    func testSuccessAndCartHaveNoPreviousStep() {
        XCTAssertNil(CheckoutPresentation.Step.success.previous)
        XCTAssertNil(CheckoutPresentation.Step.cart.previous)
    }

    // MARK: - Address validation

    private func completeDraft() -> CheckoutPresentation.AddressDraft {
        var draft = CheckoutPresentation.AddressDraft()
        draft.email = "buyer@example.com"
        draft.name = "Ada Lovelace"
        draft.line1 = "1 Analytical Way"
        draft.city = "Brooklyn"
        draft.state = "NY"
        draft.postalCode = "11201"
        return draft
    }

    func testACompleteDraftValidates() {
        XCTAssertTrue(CheckoutPresentation.isAddressComplete(completeDraft()))
        XCTAssertEqual(CheckoutPresentation.missingAddressFields(in: completeDraft()), [])
    }

    func testAnEmptyDraftReportsEveryRequiredField() {
        XCTAssertEqual(
            CheckoutPresentation.missingAddressFields(in: .init()),
            [.email, .name, .line1, .city, .state, .postalCode]
        )
    }

    /// Whitespace is not a value. The web trims before its required-check, and
    /// a spaces-only ZIP sailing through here would fail server-side instead.
    func testWhitespaceOnlyFieldsCountAsMissing() {
        var draft = completeDraft()
        draft.postalCode = "   "
        draft.city = "\n\t"

        let missing = CheckoutPresentation.missingAddressFields(in: draft)
        XCTAssertTrue(missing.contains(.postalCode))
        XCTAssertTrue(missing.contains(.city))
        XCTAssertFalse(CheckoutPresentation.isAddressComplete(draft))
    }

    /// line2 and phone are genuinely optional — an apartment-less address is
    /// the common case, not an incomplete one.
    func testLine2AndPhoneAreNotRequired() {
        var draft = completeDraft()
        draft.line2 = ""
        draft.phone = ""

        XCTAssertTrue(CheckoutPresentation.isAddressComplete(draft))
    }

    func testNormalizeTrimsEveryFieldAndDropsBlankOptionals() {
        var draft = completeDraft()
        draft.email = "  buyer@example.com  "
        draft.name = " Ada Lovelace "
        draft.line2 = "   "
        draft.phone = "  "

        let address = CheckoutPresentation.normalize(draft)

        XCTAssertEqual(address?.email, "buyer@example.com")
        XCTAssertEqual(address?.name, "Ada Lovelace")
        XCTAssertNil(address?.line2, "A blank apartment line must be nil, not an empty string")
        XCTAssertNil(address?.phone)
    }

    /// Mirrors the web's `draft.country || 'US'`: emptying the country input
    /// falls back rather than sending an empty country to the carriers.
    func testBlankCountryFallsBackToUS() {
        var draft = completeDraft()
        draft.country = "  "

        XCTAssertEqual(CheckoutPresentation.normalize(draft)?.country, "US")
    }

    func testAnExplicitCountryIsPreserved() {
        var draft = completeDraft()
        draft.country = "CA"

        XCTAssertEqual(CheckoutPresentation.normalize(draft)?.country, "CA")
    }

    /// The guard that makes the type useful: an incomplete draft cannot produce
    /// an address at all, so no caller can build a half-empty one by ignoring a
    /// validation flag.
    func testNormalizeRefusesAnIncompleteDraft() {
        var draft = completeDraft()
        draft.line1 = ""

        XCTAssertNil(CheckoutPresentation.normalize(draft))
    }

    // MARK: - Money

    /// The preview total is the ONLY sum this app computes, and it exists only
    /// before an order does.
    func testPreviewTotalAddsShippingToSubtotal() {
        XCTAssertEqual(
            CheckoutPresentation.previewTotalCents(subtotalCents: 4_800, selectedRateCents: 799),
            5_599
        )
    }

    func testPreviewTotalIsJustTheSubtotalBeforeARateIsChosen() {
        XCTAssertEqual(
            CheckoutPresentation.previewTotalCents(subtotalCents: 4_800, selectedRateCents: nil),
            4_800
        )
    }

    // MARK: - Shipping rates

    func testDeliveryEstimateReadsAsACountOfDays() {
        XCTAssertEqual(CheckoutPresentation.deliveryEstimate(days: 3), "3 day delivery")
    }

    func testSingleDayDeliveryIsNotPluralized() {
        XCTAssertEqual(CheckoutPresentation.deliveryEstimate(days: 1), "1 day delivery")
    }

    /// A missing estimate is a real answer from the carrier, not an error.
    func testAMissingDeliveryEstimateSaysSo() {
        XCTAssertEqual(
            CheckoutPresentation.deliveryEstimate(days: nil),
            "Delivery estimate unavailable"
        )
    }

    func testRateTitleJoinsCarrierAndService() {
        XCTAssertEqual(CheckoutPresentation.rateTitle(carrier: "USPS", service: "Priority"), "USPS Priority")
    }

    func testRateTitleTolerantOfAMissingHalf() {
        XCTAssertEqual(CheckoutPresentation.rateTitle(carrier: "USPS", service: "  "), "USPS")
        XCTAssertEqual(CheckoutPresentation.rateTitle(carrier: " ", service: " "), "Shipping")
    }

    // MARK: - Payment

    func testOnlyACompletedPaymentShowsAReceipt() {
        XCTAssertTrue(CheckoutPresentation.isPaymentComplete(status: "completed"))
    }

    /// The strict half, and the one worth guarding: anything that is not
    /// `completed` must keep the buyer on the payment step. A receipt for a
    /// charge that did not happen is the worst outcome this flow can produce.
    func testNonCompletedPaymentStatusesAreNotSuccess() {
        for status in ["failed", "pending", "needs-configuration", "COMPLETED", ""] {
            XCTAssertFalse(
                CheckoutPresentation.isPaymentComplete(status: status),
                "\(status) must not be treated as a completed payment"
            )
        }
    }

    func testNeedsConfigurationIsDetectedFromTheSessionStatus() {
        XCTAssertTrue(CheckoutPresentation.needsSquareConfiguration(sessionStatus: "needs-configuration"))
        XCTAssertFalse(CheckoutPresentation.needsSquareConfiguration(sessionStatus: "ready"))
    }

    // MARK: - Receipt

    func testReceiptNamesTheOrder() {
        XCTAssertEqual(
            CheckoutPresentation.receiptMessage(orderID: "order-17"),
            "Order order-17 is paid and ready for fulfillment."
        )
    }
}
