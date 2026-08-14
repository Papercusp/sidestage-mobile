// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SideStageCore

/// The buyer's cart, owned in one place for the whole tab.
///
/// It exists because a cart is not a screen's private state: a buyer adds from
/// the live room, reviews on the cart screen, and pays on checkout, and all
/// three have to agree on *which* cart. `LiveEventViewModel` used to hold the
/// cart id itself with a note that it belonged in a shared store once the cart
/// screen became real — this is that store, and the live room now defers to it.
///
/// What it deliberately does not do is arithmetic. The subtotal and every line
/// total are the server's, read off `Cart`; the per-product ceiling comes from
/// the shared core through `maxCartQuantity()`. Nothing here recomputes a price
/// a buyer might be charged.
@MainActor
@Observable
final class CartStore {
    private let client: SideStageClientProtocol

    /// The whole cart as the server last returned it. Every mutation replaces
    /// it wholesale with the server's answer rather than patching locally, so
    /// the screen can never show a total the server did not compute.
    private(set) var cart: Cart?

    /// True while a mutation is in flight, so controls can disable rather than
    /// queue a second conflicting write.
    private(set) var isUpdating = false

    /// A failure the buyer needs to see. Cleared at the start of the next
    /// attempt rather than on a timer, so it cannot vanish mid-read.
    private(set) var errorMessage: String?

    /// The per-product ceiling, read from the shared core rather than hardcoded
    /// so a stepper here and the web input's `max` cannot drift apart.
    let maximumQuantity: UInt32

    /// The event this cart was filled from.
    ///
    /// Checkout needs it: `createCheckoutSession` takes an `eventId`, and the
    /// cart screen is reached from the tab bar rather than from a room, so by
    /// then the originating event is out of scope. Recorded on add — the last
    /// add wins, which matches a cart that belongs to one drop at a time.
    private(set) var eventID: String?

    init(client: SideStageClientProtocol) {
        self.client = client
        maximumQuantity = maxCartQuantity()
    }

    // MARK: - Derived state

    var cartID: String? { cart?.id }

    var items: [CartItem] { cart?.items ?? [] }

    var isEmpty: Bool { items.isEmpty }

    /// Total units across every line — what a badge shows.
    var itemCount: Int {
        items.reduce(0) { $0 + Int($1.quantity) }
    }

    /// The server's subtotal. Zero when there is no cart yet, which is a real
    /// state rather than a missing one.
    var subtotalCents: Int64 { cart?.subtotalCents ?? 0 }

    // MARK: - Mutations

    /// Adds a quantity of a product, creating the cart on first add.
    ///
    /// Returns whether it succeeded so a caller that wants to navigate on
    /// success (buy-now) does not navigate on failure.
    @discardableResult
    func add(
        productID: String,
        title: String,
        priceCents: Int64,
        quantity: UInt32 = 1,
        imageURL: String? = nil,
        fromEvent eventID: String
    ) async -> Bool {
        self.eventID = eventID
        return await mutate {
            try await self.client.addCartItem(
                input: AddCartItemRequest(
                    cartId: self.cartID,
                    productId: productID,
                    title: title,
                    priceCents: priceCents,
                    quantity: quantity,
                    imageUrl: imageURL
                )
            )
        }
    }

    /// Changes a line's quantity.
    ///
    /// Out-of-range values are a no-op rather than a clamp, mirroring the web
    /// cart's guard: silently substituting a different number than the buyer
    /// asked for is worse than declining the change. Zero is not removal — the
    /// core is explicit about that — so removal goes through `remove`.
    @discardableResult
    func setQuantity(productID: String, to quantity: UInt32) async -> Bool {
        guard let cartID else { return false }
        guard quantity >= 1, quantity <= maximumQuantity else { return false }
        return await mutate {
            try await self.client.setCartQuantity(
                cartId: cartID,
                productId: productID,
                quantity: quantity
            )
        }
    }

    @discardableResult
    func remove(productID: String) async -> Bool {
        guard let cartID else { return false }
        return await mutate {
            try await self.client.removeCartItem(cartId: cartID, productId: productID)
        }
    }

    /// Re-reads the cart from the server.
    ///
    /// A `nil` answer means the cart is gone (expired or already converted to
    /// an order), which is why it clears local state instead of keeping a cart
    /// the server no longer recognises.
    func refresh() async {
        guard let cartID else { return }
        errorMessage = nil
        isUpdating = true
        defer { isUpdating = false }
        do {
            cart = try await client.cart(cartId: cartID)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Drops the cart after it has become an order.
    ///
    /// Called on a completed checkout: the server has consumed this cart, so
    /// holding on to the id would show a paid cart as still pending.
    func clearAfterCheckout() {
        cart = nil
        eventID = nil
        errorMessage = nil
    }

    // MARK: - Internals

    /// One place where a cart mutation is run, its result adopted, and its
    /// failure turned into a message — so the four mutations cannot drift in
    /// how they handle any of the three.
    private func mutate(_ operation: @escaping () async throws -> Cart) async -> Bool {
        errorMessage = nil
        isUpdating = true
        defer { isUpdating = false }
        do {
            cart = try await operation()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    /// Turns a transport-level failure into something a buyer can act on.
    ///
    /// 409 is the one worth naming: the API returns it when the requested
    /// quantity no longer fits what is available, which in a live drop usually
    /// means the item sold out underneath the buyer.
    nonisolated static func message(for error: Error) -> String {
        guard let apiError = error as? ApiError else {
            return "Could not update your cart. Try again."
        }
        switch apiError {
        case let .Http(status, _) where status == 409:
            return "That item just sold out or hit its limit."
        case let .Http(status, _) where status == 401 || status == 403:
            return "Sign in again to change your cart."
        case .Transport:
            return "You're offline. Your cart was not updated."
        default:
            return "Could not update your cart. Try again."
        }
    }
}
