// SPDX-License-Identifier: MIT

import XCTest

/// The buyer loop, driven end to end through the real app: browse → live room →
/// bid → cart → checkout → Orders.
///
/// The app is the unmodified shipping binary. Nothing here reaches inside it;
/// the only seam is the one it already has for pointing at a different API
/// (`SIDESTAGE_API_BASE_URL`, read from the environment before Info.plist and
/// the built-in default), which `launchEnvironment` sets to a stub server
/// running in this process. See `StubAPIServer` for what that stub is faithful
/// to and what it deliberately does not claim.
///
/// Two of these tests exist because of a defect this work found: the app never
/// installed an `ApiSession`, so order history failed with `InvalidSession` and
/// the bid control was permanently `.signedOut` — in a build whose entire unit
/// suite was green. They are narrow on purpose, so a regression names itself
/// instead of showing up as a long walk that stopped somewhere in the middle.
final class BuyerLoopUITests: XCTestCase {
    private var server: StubAPIServer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        server = try StubAPIServer()
        try server.start()

        app = XCUIApplication()
        app.launchEnvironment["SIDESTAGE_API_BASE_URL"] = server.baseURL
        app.launchEnvironment["SIDESTAGE_BUYER_ID"] = StubAPIServer.Fixture.buyerID
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        app = nil
    }

    // MARK: - The full loop

    func testBuyerBrowsesBidsBuysAndSeesTheOrder() throws {
        app.launch()

        // Browse: the event feed is the app's first screen and the first proof
        // the client reached the stub at all.
        XCTAssertTrue(
            element("buyer.feed").waitForExistence(timeout: 60),
            "The buyer feed never appeared — the app did not reach the stub API. "
                + "Requests served: \(server.servedRequests)"
        )

        let eventRow = app.staticTexts[StubAPIServer.Fixture.eventTitle]
        XCTAssertTrue(
            eventRow.waitForExistence(timeout: 30),
            "The live event never listed. Requests served: \(server.servedRequests)"
        )
        eventRow.tap()

        // Watch: the live room loads its auction through the sync batch.
        let auction = element("buyer.event.auction")
        XCTAssertTrue(
            auction.waitForExistence(timeout: 30),
            "The auction never rendered in the live room. "
                + "Requests served: \(server.servedRequests)"
        )

        // Bid: above the stub's 2400¢ starting price, so the amount clears the
        // minimum-next-bid rule rather than being declined locally.
        try placeBid(dollars: "30")

        XCTAssertTrue(
            waitForValue(of: "buyer.event.currentPrice", containing: "30"),
            "The auction price did not reflect the placed bid"
        )

        // Cart: add the on-deck product, then open the cart from the live room.
        element("buyer.event.addToCart").tap()

        let cartButton = element("buyer.event.cart")
        XCTAssertTrue(cartButton.waitForExistence(timeout: 15))
        cartButton.tap()

        let cart = element("buyer.cart")
        XCTAssertTrue(
            cart.waitForExistence(timeout: 30),
            "The cart never opened. Requests served: \(server.servedRequests)"
        )
        XCTAssertTrue(
            app.staticTexts[StubAPIServer.Fixture.productTitle].waitForExistence(timeout: 15),
            "The added product is not in the cart"
        )

        // Checkout.
        element("buyer.cart.checkout").tap()
        XCTAssertTrue(
            element("buyer.checkout").waitForExistence(timeout: 30),
            "Checkout never opened"
        )

        try fillAddress()

        element("buyer.checkout.findRates").tap()

        let rate = element("buyer.checkout.rate.\(StubAPIServer.Fixture.rateID)")
        XCTAssertTrue(
            rate.waitForExistence(timeout: 30),
            "No shipping rate was offered. Requests served: \(server.servedRequests)"
        )
        rate.tap()

        element("buyer.checkout.continue").tap()

        let pay = element("buyer.checkout.pay")
        XCTAssertTrue(
            pay.waitForExistence(timeout: 30),
            "The payment step never appeared. If buyer.checkout.needsConfiguration is "
                + "showing instead, the payment session came back needs-configuration."
        )
        pay.tap()

        XCTAssertTrue(
            element("buyer.checkout.success").waitForExistence(timeout: 30),
            "Checkout did not confirm. Requests served: \(server.servedRequests)"
        )

        // Orders: the purchase must be visible in the other tab. The stub serves
        // no orders until checkout confirms, so this passing means the purchase
        // created it — not that a fixture was always sitting there.
        app.tabBars.firstMatch.buttons["Orders"].tap()

        let orderRow = element("orders.row.\(StubAPIServer.Fixture.orderID)")
        XCTAssertTrue(
            orderRow.waitForExistence(timeout: 30),
            "The completed order did not appear in Orders. "
                + "Requests served: \(server.servedRequests)"
        )
        orderRow.tap()

        XCTAssertTrue(
            element("orders.detail.\(StubAPIServer.Fixture.orderID)")
                .waitForExistence(timeout: 30),
            "The order detail never opened"
        )
        XCTAssertTrue(
            app.staticTexts[StubAPIServer.Fixture.productTitle].waitForExistence(timeout: 15),
            "The order detail does not show the purchased product"
        )
    }

    // MARK: - Regression tests for the missing-session defect

    /// Order history builds its request as `checkout/orders?buyerId=…` from the
    /// session's buyer id, so with no session installed the core rejects the
    /// call with `InvalidSession` before it reaches the network and the tab can
    /// only ever render its error state. This asserts the tab actually loads.
    func testOrdersTabLoadsRatherThanFailingWithoutASession() throws {
        app.launch()

        app.tabBars.firstMatch.buttons["Orders"].tap()

        // Either the list or the empty state is a pass: both mean the request
        // was made and answered. The error state is the defect.
        let list = element("orders.list")
        let empty = element("orders.empty")
        let loaded = expectation(for: .init(block: { _, _ in
            list.exists || empty.exists
        }), evaluatedWith: app)

        wait(for: [loaded], timeout: 60)

        XCTAssertFalse(
            element("orders.error").exists,
            "Orders failed to load. With no ApiSession installed this is exactly what "
                + "InvalidSession looks like — check SideStageClientFactory still calls "
                + "installSession. Requests served: \(server.servedRequests)"
        )
    }

    /// The live room reads the session directly to decide whether bidding is
    /// available, and reports `.signedOut` without one — which disables the
    /// control with no error anywhere. This asserts a bid can be submitted.
    func testBidControlIsAvailableToASignedInBuyer() throws {
        app.launch()

        let eventRow = app.staticTexts[StubAPIServer.Fixture.eventTitle]
        XCTAssertTrue(eventRow.waitForExistence(timeout: 60))
        eventRow.tap()

        XCTAssertTrue(element("buyer.event.auction").waitForExistence(timeout: 30))

        try placeBid(dollars: "30")

        XCTAssertTrue(
            waitForValue(of: "buyer.event.currentPrice", containing: "30"),
            "The bid did not take. If the bid button was disabled, the client has no "
                + "session and bidAvailability is .signedOut. "
                + "Requests served: \(server.servedRequests)"
        )
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func placeBid(dollars: String) throws {
        let bidField = element("buyer.event.bidField")
        XCTAssertTrue(bidField.waitForExistence(timeout: 30), "No bid field in the live room")
        bidField.tap()
        bidField.typeText(dollars)

        let placeBid = element("buyer.event.placeBid")
        XCTAssertTrue(placeBid.waitForExistence(timeout: 15))
        XCTAssertTrue(
            placeBid.isEnabled,
            "The bid button is disabled. The likeliest cause is no installed session "
                + "(bidAvailability == .signedOut); the next likeliest is an amount below "
                + "the minimum next bid."
        )
        placeBid.tap()
    }

    private func fillAddress() throws {
        let values: [(String, String)] = [
            ("email", "buyer@example.test"),
            ("name", "Test Buyer"),
            ("line1", "123 Main St"),
            ("city", "Brooklyn"),
            ("state", "NY"),
            ("postalCode", "11201"),
        ]

        for (field, value) in values {
            let input = element("buyer.checkout.field.\(field)")
            XCTAssertTrue(
                input.waitForExistence(timeout: 15),
                "Checkout is missing the \(field) field"
            )
            input.tap()
            input.typeText(value)
        }
    }

    /// Polls an element's rendered label for a substring. The price is a
    /// formatted string rather than a value the test can compare numerically, so
    /// matching on the dollars is the honest assertion.
    private func waitForValue(
        of identifier: String,
        containing needle: String,
        timeout: TimeInterval = 30
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let target = element(identifier)

        while Date() < deadline {
            if target.exists, target.label.contains(needle) { return true }
            _ = target.waitForExistence(timeout: 1)
        }
        return false
    }
}
