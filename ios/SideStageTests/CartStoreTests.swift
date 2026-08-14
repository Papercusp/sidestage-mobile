// SPDX-License-Identifier: MIT

import XCTest
@testable import SideStage
import SideStageCore

/// Tests for `CartStore`, the one cart the whole buyer tab shares.
///
/// Why this store and not a screen: the buyer adds from the live room, reviews
/// on the cart screen, and pays at checkout, and all three read the *same*
/// store. A bug here is not a cosmetic problem on one screen — it is a wrong
/// number under a payment.
///
/// The rules asserted below are the ones with money or trust attached:
/// the server owns every total, an out-of-range quantity is declined rather
/// than quietly changed to a different one, and a cart that has become an order
/// stops being a cart.
@MainActor
final class CartStoreTests: XCTestCase {
    private var client: FakeSideStageClient!
    private var store: CartStore!

    override func setUp() {
        super.setUp()
        client = FakeSideStageClient()
        store = CartStore(client: client)
    }

    override func tearDown() {
        store = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Empty state

    /// No cart yet is a real state, not a missing one: the badge shows zero and
    /// the screen shows an empty cart rather than a spinner or a crash.
    func testAnUnfilledStoreReportsEmptyRatherThanAbsent() {
        XCTAssertNil(store.cartID)
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.itemCount, 0)
        XCTAssertEqual(store.subtotalCents, 0)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isUpdating)
    }

    // MARK: - Adding

    /// The first add has no cart to add to, so it must send `nil` and let the
    /// server mint one; every later add must carry the id it was given back.
    /// Sending `nil` twice would strand the first cart and silently start a
    /// second one, which a buyer sees as their first item vanishing.
    func testFirstAddCreatesTheCartAndLaterAddsReuseItsID() async {
        client.addCartItemResult = .success(
            .fixture(id: "cart-99", items: [.fixture(quantity: 1)], subtotalCents: 4500)
        )

        let created = await store.add(
            productID: "product-1",
            title: "Vintage denim jacket",
            priceCents: 4500,
            fromEvent: "event-7"
        )

        XCTAssertTrue(created)
        XCTAssertEqual(client.addCartItemCalls.count, 1)
        XCTAssertNil(client.addCartItemCalls[0].cartId, "The first add must let the server mint the cart")
        XCTAssertEqual(store.cartID, "cart-99")

        _ = await store.add(
            productID: "product-2",
            title: "Corduroy cap",
            priceCents: 2000,
            fromEvent: "event-7"
        )

        XCTAssertEqual(client.addCartItemCalls.count, 2)
        XCTAssertEqual(client.addCartItemCalls[1].cartId, "cart-99", "A later add must reuse the server's cart id")
    }

    /// Checkout is reached from the tab bar, by which time the room that filled
    /// the cart is out of scope — so the store has to remember which event the
    /// cart came from or `createCheckoutSession` has no `eventId` to send.
    func testTheOriginatingEventIsRememberedForCheckout() async {
        client.addCartItemResult = .success(.fixture(subtotalCents: 4500))

        XCTAssertNil(store.eventID)
        _ = await store.add(productID: "p", title: "t", priceCents: 4500, fromEvent: "event-7")

        XCTAssertEqual(store.eventID, "event-7")
    }

    // MARK: - The server owns the totals

    /// The single most important property here. The fixture's subtotal is
    /// deliberately NOT the sum of its lines (2 x 4500 = 9000, server says
    /// 8000 — a promotion the client knows nothing about). The store must
    /// report the server's number; recomputing locally is how a buyer gets
    /// shown one price and charged another.
    func testSubtotalIsTheServersNumberEvenWhenItDisagreesWithTheLines() async {
        client.addCartItemResult = .success(
            .fixture(
                items: [.fixture(priceCents: 4500, quantity: 2)],
                subtotalCents: 8000
            )
        )

        _ = await store.add(productID: "p", title: "t", priceCents: 4500, fromEvent: "e")

        XCTAssertEqual(store.subtotalCents, 8000, "The subtotal must be adopted from the server, never recomputed")
    }

    /// A badge counts units, not lines: two of one product and one of another
    /// is three items, not two.
    func testItemCountSumsUnitsAcrossLines() async {
        client.addCartItemResult = .success(
            .fixture(
                items: [
                    .fixture(productId: "a", quantity: 2),
                    .fixture(productId: "b", quantity: 1),
                ],
                subtotalCents: 11000
            )
        )

        _ = await store.add(productID: "a", title: "t", priceCents: 4500, fromEvent: "e")

        XCTAssertEqual(store.itemCount, 3)
        XCTAssertFalse(store.isEmpty)
    }

    // MARK: - Quantity guards

    private func fillCart() async {
        client.addCartItemResult = .success(
            .fixture(id: "cart-1", items: [.fixture(productId: "a", quantity: 1)], subtotalCents: 4500)
        )
        _ = await store.add(productID: "a", title: "t", priceCents: 4500, fromEvent: "e")
        XCTAssertEqual(store.cartID, "cart-1")
    }

    /// Above the ceiling the change is declined outright — not clamped down to
    /// the maximum. Silently substituting a different number than the buyer
    /// asked for is worse than refusing, and it must not even reach the server.
    ///
    /// The ceiling is read from the store (which reads it from the shared core)
    /// rather than hardcoded here, so this test cannot drift from the web input's
    /// `max` the way a literal would.
    func testAQuantityAboveTheCeilingIsDeclinedLocallyAndNeverSent() async {
        await fillCart()
        let mutationsBefore = client.cartMutationCount

        let changed = await store.setQuantity(productID: "a", to: store.maximumQuantity + 1)

        XCTAssertFalse(changed)
        XCTAssertEqual(client.cartMutationCount, mutationsBefore, "An out-of-range quantity must not reach the server")
        XCTAssertTrue(client.setCartQuantityCalls.isEmpty)
    }

    /// Zero is not removal — the shared core is explicit about that — so it is
    /// declined here and removal goes through `remove`. Treating it as removal
    /// would delete a line the buyer was only editing.
    func testZeroIsDeclinedBecauseZeroIsNotRemoval() async {
        await fillCart()

        let changed = await store.setQuantity(productID: "a", to: 0)

        XCTAssertFalse(changed)
        XCTAssertTrue(client.setCartQuantityCalls.isEmpty, "Zero must not be forwarded as a quantity change")
    }

    /// With no cart there is nothing to change, and the server would have no id
    /// to apply it to.
    func testAQuantityChangeWithoutACartIsDeclined() async {
        let changed = await store.setQuantity(productID: "a", to: 2)

        XCTAssertFalse(changed)
        XCTAssertTrue(client.setCartQuantityCalls.isEmpty)
    }

    /// The in-range case, so the guards above are shown to be rejecting only
    /// what they should. Without this, a guard that rejected *everything* would
    /// pass every other quantity test in this file.
    func testAnInRangeQuantityIsForwardedWithTheCartAndProduct() async {
        await fillCart()
        client.setCartQuantityResult = .success(
            .fixture(id: "cart-1", items: [.fixture(productId: "a", quantity: 2)], subtotalCents: 9000)
        )

        let changed = await store.setQuantity(productID: "a", to: 2)

        XCTAssertTrue(changed)
        XCTAssertEqual(client.setCartQuantityCalls.count, 1)
        XCTAssertEqual(client.setCartQuantityCalls[0].cartId, "cart-1")
        XCTAssertEqual(client.setCartQuantityCalls[0].productId, "a")
        XCTAssertEqual(client.setCartQuantityCalls[0].quantity, 2)
        XCTAssertEqual(store.itemCount, 2)
        XCTAssertEqual(store.subtotalCents, 9000)
    }

    /// Removal needs a cart too, and must reach the server with both ids.
    func testRemoveForwardsTheCartAndProductAndAdoptsTheResult() async {
        await fillCart()
        client.removeCartItemResult = .success(.fixture(id: "cart-1", items: [], subtotalCents: 0))

        let removed = await store.remove(productID: "a")

        XCTAssertTrue(removed)
        XCTAssertEqual(client.removeCartItemCalls.count, 1)
        XCTAssertEqual(client.removeCartItemCalls[0].cartId, "cart-1")
        XCTAssertEqual(client.removeCartItemCalls[0].productId, "a")
        XCTAssertTrue(store.isEmpty)
    }

    // MARK: - Refresh

    /// A `nil` cart means the server no longer recognises it — expired, or
    /// already converted to an order. Keeping it would show a cart that cannot
    /// be paid for.
    func testRefreshTreatsANilAnswerAsTheCartBeingGone() async {
        await fillCart()
        client.cartResult = .success(nil)

        await store.refresh()

        XCTAssertEqual(client.cartCalls, ["cart-1"])
        XCTAssertNil(store.cartID)
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.subtotalCents, 0)
    }

    /// Nothing to refresh without a cart, so it must not call the server with a
    /// fabricated id.
    func testRefreshWithoutACartDoesNothing() async {
        await store.refresh()

        XCTAssertTrue(client.cartCalls.isEmpty)
    }

    // MARK: - After checkout

    /// The server has consumed this cart into an order. Holding the id would
    /// show a paid cart as still pending, and a stale event id would attach the
    /// next checkout to the wrong drop.
    func testClearAfterCheckoutDropsTheCartAndTheEvent() async {
        await fillCart()
        XCTAssertNotNil(store.cartID)

        store.clearAfterCheckout()

        XCTAssertNil(store.cartID)
        XCTAssertNil(store.eventID)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.isEmpty)
    }

    // MARK: - Failure handling

    /// A failed mutation must not take the existing cart down with it: the
    /// buyer's items are still there, they just could not make this change.
    func testAFailedMutationKeepsThePreviousCartAndSurfacesAMessage() async {
        await fillCart()
        client.setCartQuantityResult = .failure(ApiError.Http(status: 409, detail: "sold out"))

        let changed = await store.setQuantity(productID: "a", to: 2)

        XCTAssertFalse(changed)
        XCTAssertEqual(store.cartID, "cart-1", "A failed change must not discard the cart")
        XCTAssertEqual(store.itemCount, 1)
        XCTAssertEqual(store.errorMessage, "That item just sold out or hit its limit.")
        XCTAssertFalse(store.isUpdating, "isUpdating must be released even when the mutation throws")
    }

    /// The message is cleared at the start of the next attempt rather than on a
    /// timer, so it cannot disappear while the buyer is still reading it — and
    /// it must not outlive a subsequent success either.
    func testAnEarlierErrorIsClearedByTheNextSuccessfulAttempt() async {
        await fillCart()
        client.setCartQuantityResult = .failure(ApiError.Http(status: 409, detail: "sold out"))
        _ = await store.setQuantity(productID: "a", to: 2)
        XCTAssertNotNil(store.errorMessage)

        client.setCartQuantityResult = .success(
            .fixture(id: "cart-1", items: [.fixture(productId: "a", quantity: 2)], subtotalCents: 9000)
        )
        let changed = await store.setQuantity(productID: "a", to: 2)

        XCTAssertTrue(changed)
        XCTAssertNil(store.errorMessage)
    }

    /// A refresh that fails leaves the cart alone and explains itself.
    func testAFailedRefreshSurfacesAMessage() async {
        await fillCart()
        client.cartResult = .failure(ApiError.Transport(detail: "offline"))

        await store.refresh()

        XCTAssertEqual(store.errorMessage, "You're offline. Your cart was not updated.")
        XCTAssertEqual(store.cartID, "cart-1")
        XCTAssertFalse(store.isUpdating)
    }

    // MARK: - Error copy

    /// 409 is the one worth naming: in a live drop it almost always means the
    /// item sold out underneath the buyer, and "try again" would be a lie.
    func testSoldOutIsNamedRatherThanGenericised() {
        XCTAssertEqual(
            CartStore.message(for: ApiError.Http(status: 409, detail: "conflict")),
            "That item just sold out or hit its limit."
        )
    }

    func testAuthFailuresAskTheBuyerToSignInAgain() {
        XCTAssertEqual(
            CartStore.message(for: ApiError.Http(status: 401, detail: "unauthorized")),
            "Sign in again to change your cart."
        )
        XCTAssertEqual(
            CartStore.message(for: ApiError.Http(status: 403, detail: "forbidden")),
            "Sign in again to change your cart."
        )
    }

    /// Being offline is worth saying plainly, because the fix is the buyer's.
    func testTransportFailuresSayTheCartWasNotUpdated() {
        XCTAssertEqual(
            CartStore.message(for: ApiError.Transport(detail: "no route")),
            "You're offline. Your cart was not updated."
        )
    }

    /// Anything else, including a non-API error, falls back to something a
    /// buyer can act on rather than leaking a decoding detail.
    func testUnrecognisedFailuresFallBackToASafeMessage() {
        struct Unknown: Error {}

        XCTAssertEqual(
            CartStore.message(for: ApiError.Http(status: 500, detail: "boom")),
            "Could not update your cart. Try again."
        )
        XCTAssertEqual(
            CartStore.message(for: ApiError.Decode(detail: "bad json")),
            "Could not update your cart. Try again."
        )
        XCTAssertEqual(
            CartStore.message(for: Unknown()),
            "Could not update your cart. Try again."
        )
    }
}
