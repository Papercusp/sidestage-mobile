// SPDX-License-Identifier: MIT

import Foundation
@testable import SideStage
import SideStageCore

/// A programmable stand-in for the generated `SideStageClientProtocol`.
///
/// It exists because every screen in the app is built on that protocol, and
/// until now *nothing* that touched it had a test. The existing suites cover
/// only the pure pieces — enum ladders, address validation, navigation scope —
/// because there was no way to run a view model without a live API behind it.
/// This is that way.
///
/// Two rules shape it:
///
/// 1. **Every method is programmable, and none of them guess.** Anything a test
///    has not deliberately set up throws `unimplemented` rather than returning a
///    plausible empty value. A silent `[]` would let a test pass while asserting
///    nothing, which is the failure mode a double most often introduces.
/// 2. **Calls are recorded.** For the cart the *request* is the interesting
///    half — whether an add carried a cart id, whether an out-of-range quantity
///    was declined locally or forwarded to the server — so the recorded inputs
///    are as much the subject as the returned values.
///
/// It is deliberately not restricted to the cart: `orders`, `catalog`,
/// `checkout` and the live-event calls are all here so `OrdersViewModel`,
/// `LiveEventViewModel` and `CheckoutViewModel` can be tested without anyone
/// having to build a second double.
final class FakeSideStageClient: SideStageClientProtocol {
    /// Thrown by anything a test has not programmed. Named so a failure reads
    /// as "the test forgot to set this up" rather than as a transport problem.
    static func unimplemented(_ method: String) -> ApiError {
        .Transport(detail: "FakeSideStageClient.\(method) was not programmed by this test")
    }

    // MARK: - Programmable results

    var cartResult: Result<Cart?, Error>?
    var addCartItemResult: Result<Cart, Error>?
    var setCartQuantityResult: Result<Cart, Error>?
    var removeCartItemResult: Result<Cart, Error>?
    var eventsResult: Result<[EventSummary], Error>?
    var eventResult: Result<EventSummary, Error>?
    var catalogResult: Result<CatalogPage, Error>?
    var productTypesResult: Result<[String], Error>?
    var productResult: Result<CatalogVariant, Error>?
    var shippingRatesResult: Result<[ShippingRate], Error>?
    var createCheckoutSessionResult: Result<CheckoutSessionResponse, Error>?
    var confirmCheckoutResult: Result<CheckoutConfirmation, Error>?
    var ordersResult: Result<[CheckoutOrder], Error>?
    var orderHistoryResult: Result<[Order], Error>?
    var placeBidResult: Result<LiveAuction, Error>?

    // MARK: - Recorded calls

    private(set) var addCartItemCalls: [AddCartItemRequest] = []
    private(set) var setCartQuantityCalls: [(cartId: String, productId: String, quantity: UInt32)] = []
    private(set) var removeCartItemCalls: [(cartId: String, productId: String)] = []
    private(set) var cartCalls: [String] = []

    /// Total cart-mutating calls that actually reached the client. A guard that
    /// is supposed to decline locally must leave this unchanged.
    var cartMutationCount: Int {
        addCartItemCalls.count + setCartQuantityCalls.count + removeCartItemCalls.count
    }

    // MARK: - Session

    private var storedSession: ApiSession?

    func session() -> ApiSession? { storedSession }

    func setSession(session: ApiSession?) throws { storedSession = session }

    // MARK: - Cart

    func cart(cartId: String) async throws -> Cart? {
        cartCalls.append(cartId)
        guard let cartResult else { throw Self.unimplemented("cart") }
        return try cartResult.get()
    }

    func addCartItem(input: AddCartItemRequest) async throws -> Cart {
        addCartItemCalls.append(input)
        guard let addCartItemResult else { throw Self.unimplemented("addCartItem") }
        return try addCartItemResult.get()
    }

    func setCartQuantity(cartId: String, productId: String, quantity: UInt32) async throws -> Cart {
        setCartQuantityCalls.append((cartId: cartId, productId: productId, quantity: quantity))
        guard let setCartQuantityResult else { throw Self.unimplemented("setCartQuantity") }
        return try setCartQuantityResult.get()
    }

    func removeCartItem(cartId: String, productId: String) async throws -> Cart {
        removeCartItemCalls.append((cartId: cartId, productId: productId))
        guard let removeCartItemResult else { throw Self.unimplemented("removeCartItem") }
        return try removeCartItemResult.get()
    }

    // MARK: - Browse

    func events() async throws -> [EventSummary] {
        guard let eventsResult else { throw Self.unimplemented("events") }
        return try eventsResult.get()
    }

    func event(eventId: String) async throws -> EventSummary {
        guard let eventResult else { throw Self.unimplemented("event") }
        return try eventResult.get()
    }

    func catalog(search: CatalogSearch) async throws -> CatalogPage {
        guard let catalogResult else { throw Self.unimplemented("catalog") }
        return try catalogResult.get()
    }

    func productTypes() async throws -> [String] {
        guard let productTypesResult else { throw Self.unimplemented("productTypes") }
        return try productTypesResult.get()
    }

    func product(productId: String) async throws -> CatalogVariant {
        guard let productResult else { throw Self.unimplemented("product") }
        return try productResult.get()
    }

    // MARK: - Checkout

    func shippingRates(input: ShippingRatesRequest) async throws -> [ShippingRate] {
        guard let shippingRatesResult else { throw Self.unimplemented("shippingRates") }
        return try shippingRatesResult.get()
    }

    func createCheckoutSession(input: CreateCheckoutSessionRequest) async throws -> CheckoutSessionResponse {
        guard let createCheckoutSessionResult else { throw Self.unimplemented("createCheckoutSession") }
        return try createCheckoutSessionResult.get()
    }

    func confirmCheckout(input: ConfirmCheckoutRequest) async throws -> CheckoutConfirmation {
        guard let confirmCheckoutResult else { throw Self.unimplemented("confirmCheckout") }
        return try confirmCheckoutResult.get()
    }

    func orders() async throws -> [CheckoutOrder] {
        guard let ordersResult else { throw Self.unimplemented("orders") }
        return try ordersResult.get()
    }

    func orderHistory() async throws -> [Order] {
        guard let orderHistoryResult else { throw Self.unimplemented("orderHistory") }
        return try orderHistoryResult.get()
    }

    // MARK: - Live event

    /// Always throws. `LiveEventSync` is a generated UniFFI *object* backed by a
    /// Rust handle, so there is no honest way to fabricate one in a unit test —
    /// pretending otherwise would hand back a value whose behaviour has nothing
    /// to do with the real stream. Streaming belongs to the simulator e2e.
    func liveEventSync(eventId: String) throws -> LiveEventSync {
        throw ApiError.Transport(
            detail: "FakeSideStageClient cannot fabricate a LiveEventSync (Rust-backed object)"
        )
    }

    func placeBid(input: PlaceBidRequest) async throws -> LiveAuction {
        guard let placeBidResult else { throw Self.unimplemented("placeBid") }
        return try placeBidResult.get()
    }
}

// MARK: - Fixtures

extension Cart {
    /// A cart whose subtotal is supplied rather than derived.
    ///
    /// Keeping `subtotalCents` an explicit parameter is the point: the server
    /// owns the total, and a fixture that quietly computed it from the lines
    /// would make it impossible to write the one test that matters here — that
    /// the store shows the server's number even when it disagrees with the
    /// arithmetic a client might have done.
    static func fixture(
        id: String = "cart-1",
        items: [CartItem] = [],
        subtotalCents: Int64,
        updatedAt: String = "2026-08-14T00:00:00Z"
    ) -> Cart {
        Cart(
            id: id,
            currency: .usd,
            items: items,
            subtotalCents: subtotalCents,
            updatedAt: updatedAt
        )
    }
}

extension CartItem {
    static func fixture(
        productId: String = "product-1",
        title: String = "Vintage denim jacket",
        priceCents: Int64 = 4500,
        quantity: UInt32 = 1,
        imageUrl: String? = nil
    ) -> CartItem {
        CartItem(
            productId: productId,
            title: title,
            priceCents: priceCents,
            quantity: quantity,
            imageUrl: imageUrl
        )
    }
}
