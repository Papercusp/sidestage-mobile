// SPDX-License-Identifier: MIT

import Foundation

/// Presentation and input rules for the buyer's cart → checkout flow.
///
/// Deliberately free of any `SideStageCore` import, exactly like
/// `LiveEventPresentation`: everything here is formatting and form validation
/// over plain values, so it unit-tests without a live core and can never
/// quietly become a second copy of a *server* rule.
///
/// **The rule to hold on to in this file is about totals.** An order's
/// `subtotalCents` / `shippingCents` / `totalCents` are computed and then
/// revalidated server-side before payment; the single sum written here is
/// `previewTotalCents`, which exists only to fill the shipping step *before an
/// order exists*, and is superseded the moment one does. Nothing in this file
/// may be used to state what a buyer was actually charged.
///
/// Every rule below mirrors `apps/web/src/BuyerCheckout.tsx` so a buyer cannot
/// get an address accepted on one surface and rejected on another.
enum CheckoutPresentation {
    // MARK: - Steps

    /// The checkout ladder, in order. Mirrors the web `BuyerCheckoutStep`.
    enum Step: String, CaseIterable, Hashable {
        case cart
        case address
        case shipping
        case payment
        case success

        /// Screen titles, verbatim from the web `stepTitle`.
        var title: String {
            switch self {
            case .cart: "Your cart"
            case .address: "Where should it go?"
            case .shipping: "Choose shipping"
            case .payment: "Square sandbox"
            case .success: "Order confirmed"
            }
        }

        /// The step a "back" control returns to, or `nil` where the web offers
        /// no way back. `success` is terminal on purpose: the order is paid, so
        /// re-entering payment would invite a second charge.
        var previous: Step? {
            switch self {
            case .cart: nil
            case .address: .cart
            case .shipping: .address
            case .payment: .shipping
            case .success: nil
            }
        }
    }

    // MARK: - Address form

    /// What the buyer has typed. Held as a separate mutable draft rather than a
    /// half-built `ShippingAddress` so the form can hold invalid intermediate
    /// text without the FFI type ever existing in an invalid state.
    struct AddressDraft: Equatable {
        var email: String = ""
        var name: String = ""
        var line1: String = ""
        var line2: String = ""
        var city: String = ""
        var state: String = ""
        var postalCode: String = ""
        var country: String = "US"
        var phone: String = ""

        init() {}
    }

    /// A field the buyer still has to fill in. Ordered as the form is, so
    /// "focus the first problem" is `missing.first`.
    enum AddressField: String, CaseIterable, Hashable {
        case email
        case name
        case line1
        case city
        case state
        case postalCode

        var label: String {
            switch self {
            case .email: "Email"
            case .name: "Full name"
            case .line1: "Address"
            case .city: "City"
            case .state: "State"
            case .postalCode: "ZIP code"
            }
        }
    }

    /// The single error the web surface shows when the address form is short.
    ///
    /// Kept verbatim rather than reworded for mobile: it is the same failure on
    /// both surfaces, and two different sentences for one condition is how
    /// support answers start to diverge. Field-level highlighting is layered on
    /// top through `missingAddressFields` — additive, so the sentence a buyer
    /// reads stays identical.
    static let incompleteAddressMessage =
        "Email, name, and a complete shipping address are required."

    /// Required-field check, mirroring the web guard: email, name, line1, city,
    /// state and postal code must be non-blank once trimmed. `line2`, `phone`
    /// and `country` are not required — country falls back to `US` below, which
    /// is what the web form does with an emptied input.
    static func missingAddressFields(in draft: AddressDraft) -> [AddressField] {
        AddressField.allCases.filter { field in
            switch field {
            case .email: isBlank(draft.email)
            case .name: isBlank(draft.name)
            case .line1: isBlank(draft.line1)
            case .city: isBlank(draft.city)
            case .state: isBlank(draft.state)
            case .postalCode: isBlank(draft.postalCode)
            }
        }
    }

    /// Whether the address step can advance. Deliberately does not consider the
    /// cart: an empty cart is caught a step earlier, and folding the two would
    /// make an empty cart read as a bad address.
    static func isAddressComplete(_ draft: AddressDraft) -> Bool {
        missingAddressFields(in: draft).isEmpty
    }

    /// The values to send, with the web's normalisation applied: everything is
    /// trimmed, blank optionals collapse to `nil` rather than empty strings, and
    /// an emptied country falls back to `US`.
    ///
    /// Returns plain values instead of the FFI `ShippingAddress` so this file
    /// stays core-free; the view model assembles the boundary type.
    struct NormalizedAddress: Equatable {
        let email: String
        let name: String
        let line1: String
        let line2: String?
        let city: String
        let state: String
        let postalCode: String
        let country: String
        let phone: String?
    }

    /// `nil` when a required field is blank — so a caller cannot accidentally
    /// build a half-empty address by ignoring a validation flag.
    static func normalize(_ draft: AddressDraft) -> NormalizedAddress? {
        guard isAddressComplete(draft) else { return nil }
        let country = trimmed(draft.country)
        return NormalizedAddress(
            email: trimmed(draft.email),
            name: trimmed(draft.name),
            line1: trimmed(draft.line1),
            line2: nilIfBlank(draft.line2),
            city: trimmed(draft.city),
            state: trimmed(draft.state),
            postalCode: trimmed(draft.postalCode),
            country: country.isEmpty ? "US" : country,
            phone: nilIfBlank(draft.phone)
        )
    }

    // MARK: - Money

    /// Formats cents for every checkout surface.
    ///
    /// Delegates to `LiveEventPresentation` rather than re-deriving the rule:
    /// one money formatter for the app means a price cannot render one way in a
    /// live room and another in the cart.
    static func formatPrice(cents: Int64) -> String {
        LiveEventPresentation.formatPrice(cents: cents)
    }

    /// The shipping step's running total, mirroring the web
    /// `(cart?.subtotalCents ?? 0) + (selectedRate?.totalCents ?? 0)`.
    ///
    /// ⚠️ A PREVIEW, not an amount charged. It exists because the shipping step
    /// renders before any order exists. Once `createCheckoutSession` returns,
    /// the order's own `totalCents` is the only figure that may be shown —
    /// the server revalidates the cart and can legitimately disagree with this.
    static func previewTotalCents(subtotalCents: Int64, selectedRateCents: Int64?) -> Int64 {
        subtotalCents + (selectedRateCents ?? 0)
    }

    // MARK: - Shipping rates

    /// Secondary line for a rate row, mirroring the web's
    /// `deliveryDays === null ? 'Delivery estimate unavailable' : '<n> day delivery'`.
    ///
    /// The singular/plural split is the one intentional divergence: the web
    /// prints "1 day delivery", which reads as a typo rather than as data.
    static func deliveryEstimate(days: UInt32?) -> String {
        guard let days else { return "Delivery estimate unavailable" }
        return days == 1 ? "1 day delivery" : "\(days) day delivery"
    }

    /// Primary line for a rate row: carrier and service, as the web joins them.
    static func rateTitle(carrier: String, service: String) -> String {
        let parts = [trimmed(carrier), trimmed(service)].filter { !$0.isEmpty }
        return parts.isEmpty ? "Shipping" : parts.joined(separator: " ")
    }

    /// What to show when the address produced no rates at all — a real outcome
    /// for an address the carriers will not quote, not an error state.
    static let noRatesMessage = "No live shipping rates are available for this address."

    // MARK: - Payment

    /// Whether the payment step can collect a card, or must explain that the
    /// server has no Square credentials. Mirrors the web's
    /// `session.status === 'needs-configuration'` branch.
    static func needsSquareConfiguration(sessionStatus: String) -> Bool {
        sessionStatus == "needs-configuration"
    }

    static let squareNeedsConfigurationTitle = "Square sandbox needs configuration."
    static let squareNeedsConfigurationDetail =
        "Set the server-side Square sandbox credentials to enable tokenized card checkout."

    /// The message shown when the payment came back as anything but paid
    /// and Square did not say why. Verbatim from the web fallback.
    static let paymentDidNotCompleteMessage = "Square did not complete the payment."

    /// Every payment status this app can ever be handed — the whole reachable
    /// vocabulary, not a sample of it.
    ///
    /// The FFI layer flattens the core's `PaymentResultStatus` enum to a string
    /// through an *exhaustive* match (`crates/sidestage-bindings/src/lib.rs`,
    /// `impl From<core::PaymentResult> for PaymentResult`), so a status outside
    /// this set cannot reach Swift. `status_vocabulary_guard.rs` pins this set
    /// to those match arms, which is what makes that claim checkable rather
    /// than merely asserted here.
    static let paymentStatusVocabulary: Set<String> = ["paid", "failed", "needs-configuration"]

    /// The one member of `paymentStatusVocabulary` that means money moved.
    static let paidPaymentStatus = "paid"

    /// A payment is a success only when the API says `paid`.
    ///
    /// It is `paid`, **not** `completed`. `completed` is Square's raw upstream
    /// status, which the API consumes itself and then translates before it ever
    /// answers a client: `apps/api/src/checkout/checkout.service.ts` tests
    /// Square's `COMPLETED` and returns its own `'paid'`. Matching `completed`
    /// here made `step = .success` unreachable, so a buyer whose card had been
    /// charged was shown "Square did not complete the payment" instead of a
    /// receipt. Anything that is not `paid` keeps the buyer on the payment step.
    static func isPaymentComplete(status: String) -> Bool {
        status == paidPaymentStatus
    }

    /// Every order status the FFI can emit, pinned the same way as
    /// `paymentStatusVocabulary` (`core::CheckoutOrderStatus`).
    static let orderStatusVocabulary: Set<String> = ["pending", "paid", "failed"]

    /// The one member of `orderStatusVocabulary` that means the order settled.
    static let paidOrderStatus = "paid"

    /// Whether a confirmation as a whole earns a receipt.
    ///
    /// Both halves must agree, matching the web reference
    /// (`apps/web/src/BuyerCheckout.tsx`:
    /// `result.payment.status !== 'paid' || result.order.status !== 'paid'`).
    /// A paid payment against an order the server did not mark paid is exactly
    /// the divergence a receipt must not paper over.
    static func isCheckoutConfirmed(paymentStatus: String, orderStatus: String) -> Bool {
        isPaymentComplete(status: paymentStatus) && orderStatus == paidOrderStatus
    }

    // MARK: - Receipt

    /// Confirmation line, mirroring the web success panel.
    static func receiptMessage(orderID: String) -> String {
        "Order \(orderID) is paid and ready for fulfillment."
    }

    // MARK: - Helpers

    private static func isBlank(_ value: String) -> Bool {
        trimmed(value).isEmpty
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nilIfBlank(_ value: String) -> String? {
        let cleaned = trimmed(value)
        return cleaned.isEmpty ? nil : cleaned
    }
}
