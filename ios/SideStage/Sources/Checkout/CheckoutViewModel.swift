// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SideStageCore

/// Drives the buyer's checkout: address → live shipping rates → Square sandbox
/// session → confirmed order.
///
/// It mirrors `apps/web/src/BuyerCheckout.tsx` step for step, because the two
/// surfaces talk to the same endpoints and a buyer who gets a rate quoted on
/// one must get it on the other. What is *not* mirrored is the card widget:
/// the web loads Square's Web Payments SDK to turn a card into a `sourceId`,
/// and there is no equivalent dependency in this target (see `sandboxSourceID`).
///
/// Money discipline, same as everywhere else in this app: the order's
/// `subtotalCents` / `shippingCents` / `totalCents` come from the server and are
/// revalidated there before payment. The only local sum is the pre-order
/// preview on the shipping step, and it is dropped the moment an order exists.
@MainActor
@Observable
final class CheckoutViewModel {
    // MARK: - Inputs

    private let client: SideStageClientProtocol
    private let cartStore: CartStore
    private let eventID: String

    // MARK: - Observable state

    private(set) var step: CheckoutPresentation.Step = .cart

    /// What the buyer has typed into the address form.
    var draft = CheckoutPresentation.AddressDraft()

    private(set) var rates: [ShippingRate] = []
    var selectedRateID: String?

    /// The order + payment session, once checkout has started.
    private(set) var checkout: CheckoutSessionResponse?

    /// The paid order, once Square has completed. Separate from `checkout` so
    /// the receipt renders the *confirmed* order rather than the pre-payment
    /// one, whose status is still pending.
    private(set) var completedOrder: CheckoutOrder?

    private(set) var isBusy = false
    private(set) var errorMessage: String?

    /// Fields the buyer still has to fill, so the form can mark them. The
    /// sentence shown stays `incompleteAddressMessage`, identical to web.
    private(set) var missingFields: [CheckoutPresentation.AddressField] = []

    init(client: SideStageClientProtocol, cartStore: CartStore, eventID: String) {
        self.client = client
        self.cartStore = cartStore
        self.eventID = eventID
    }

    // MARK: - Derived state

    var selectedRate: ShippingRate? {
        rates.first { $0.id == selectedRateID }
    }

    /// The shipping step's running total — a PREVIEW only. Once `checkout`
    /// exists, `orderTotalCents` is the figure to show.
    var previewTotalCents: Int64 {
        CheckoutPresentation.previewTotalCents(
            subtotalCents: cartStore.subtotalCents,
            selectedRateCents: selectedRate?.totalCents
        )
    }

    /// The authoritative total, present only once the server has made an order.
    var orderTotalCents: Int64? {
        completedOrder?.totalCents ?? checkout?.order.totalCents
    }

    var canStartCheckout: Bool {
        selectedRate != nil && !isBusy
    }

    var canLeaveCartStep: Bool {
        !cartStore.isEmpty && !isBusy
    }

    /// Whether the payment step must explain missing credentials instead of
    /// collecting a card.
    var needsSquareConfiguration: Bool {
        guard let status = checkout?.session.status else { return false }
        return CheckoutPresentation.needsSquareConfiguration(sessionStatus: status)
    }

    // MARK: - Navigation

    func goTo(_ step: CheckoutPresentation.Step) {
        errorMessage = nil
        self.step = step
    }

    func goBack() {
        guard let previous = step.previous else { return }
        goTo(previous)
    }

    // MARK: - Step 1 → 2: shipping rates

    /// Validates the address and asks the API for live rates.
    ///
    /// A successful call with *zero* rates is not an error: it means no carrier
    /// would quote this address. The step still advances so the buyer sees that
    /// stated plainly, which is what the web does.
    func findShippingRates() async {
        missingFields = CheckoutPresentation.missingAddressFields(in: draft)
        guard let address = CheckoutPresentation.normalize(draft) else {
            errorMessage = CheckoutPresentation.incompleteAddressMessage
            return
        }
        guard let cartID = cartStore.cartID, !cartStore.isEmpty else {
            errorMessage = "Your cart is empty."
            return
        }

        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let quoted = try await client.shippingRates(
                input: ShippingRatesRequest(cartId: cartID, address: Self.boundary(address))
            )
            rates = quoted
            // Re-selecting by id rather than keeping the old object: a re-quote
            // can return a different price for the same service, and carrying
            // the stale rate forward would show a total the server will reject.
            if let selectedRateID, quoted.contains(where: { $0.id == selectedRateID }) == false {
                self.selectedRateID = nil
            }
            selectedRateID = selectedRateID ?? quoted.first?.id
            step = .shipping
        } catch {
            errorMessage = Self.message(for: error, fallback: "Could not load shipping rates.")
        }
    }

    // MARK: - Step 2 → 3: Square session

    /// Creates the order and its Square sandbox payment session.
    func startCheckout() async {
        guard let address = CheckoutPresentation.normalize(draft),
              let cartID = cartStore.cartID,
              let rate = selectedRate
        else {
            errorMessage = CheckoutPresentation.incompleteAddressMessage
            return
        }

        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await client.createCheckoutSession(
                input: CreateCheckoutSessionRequest(
                    cartId: cartID,
                    eventId: eventID,
                    email: address.email,
                    name: address.name,
                    shippingAddress: Self.boundary(address),
                    shippingRateId: rate.id
                )
            )
            checkout = response
            step = .payment
        } catch {
            errorMessage = Self.message(for: error, fallback: "Could not start checkout.")
        }
    }

    // MARK: - Step 3 → 4: payment

    /// Square's documented sandbox card nonce.
    ///
    /// **Why a fixed nonce and not a card form.** The web surface tokenizes a
    /// real card with Square's *Web* Payments SDK; the iOS equivalent is
    /// Square's In-App Payments SDK, which this target does not depend on and
    /// which cannot be added or built from the Linux host this app is currently
    /// developed on. The API forwards whatever `sourceId` it is given straight
    /// to `connect.squareupsandbox.com`, and this is the value Square publishes
    /// for sandbox testing — the same one `checkout.service.test.ts` uses.
    ///
    /// So the sandbox loop is genuinely exercised end to end, and the screen
    /// says plainly that it is a sandbox payment rather than dressing it up as
    /// card entry. Real card capture is tracked separately; when the In-App
    /// Payments SDK lands, only `confirmPayment` changes.
    ///
    /// `nonisolated` because it is used as a default argument below, and a
    /// default argument is evaluated in the *caller's* context — reaching a
    /// main-actor-isolated constant from there is a warning today and an error
    /// in the Swift 6 language mode. The value is an immutable `String`, so
    /// there is nothing for the isolation to protect.
    nonisolated static let sandboxSourceID = "cnon:card-nonce-ok"

    /// Confirms payment and, on success, refreshes the cart and shows the
    /// receipt. A non-`completed` status keeps the buyer on the payment step:
    /// showing a receipt for a charge that did not go through is the one
    /// failure mode worth being strict about.
    func confirmPayment(sourceID: String = CheckoutViewModel.sandboxSourceID) async {
        guard let orderID = checkout?.order.id else { return }

        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let confirmation = try await client.confirmCheckout(
                input: ConfirmCheckoutRequest(orderId: orderID, sourceId: sourceID)
            )
            guard CheckoutPresentation.isPaymentComplete(status: confirmation.payment.status) else {
                errorMessage = confirmation.payment.errorMessage
                    ?? CheckoutPresentation.paymentDidNotCompleteMessage
                return
            }
            completedOrder = confirmation.order
            // The server has consumed this cart into an order; keeping the id
            // would leave a paid cart looking pending on the buyer tab.
            cartStore.clearAfterCheckout()
            step = .success
        } catch {
            errorMessage = Self.message(
                for: error,
                fallback: CheckoutPresentation.paymentDidNotCompleteMessage
            )
        }
    }

    // MARK: - Internals

    /// Builds the FFI type at the boundary, so `CheckoutPresentation` can stay
    /// free of any core import and remain testable without one.
    private static func boundary(
        _ address: CheckoutPresentation.NormalizedAddress
    ) -> ShippingAddress {
        ShippingAddress(
            name: address.name,
            line1: address.line1,
            line2: address.line2,
            city: address.city,
            state: address.state,
            postalCode: address.postalCode,
            country: address.country,
            phone: address.phone
        )
    }

    /// Shared failure mapping for every checkout call.
    nonisolated static func message(for error: Error, fallback: String) -> String {
        guard let apiError = error as? ApiError else { return fallback }
        switch apiError {
        case let .Http(status, _) where status == 409:
            return "Something in your cart changed. Review it and try again."
        case let .Http(status, _) where status == 401 || status == 403:
            return "Sign in again to complete checkout."
        case .InvalidSession:
            return "Sign in again to complete checkout."
        case .Transport:
            return "You're offline. Nothing was charged."
        default:
            return fallback
        }
    }
}
