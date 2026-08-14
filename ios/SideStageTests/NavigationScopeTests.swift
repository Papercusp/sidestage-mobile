// SPDX-License-Identifier: MIT

import XCTest
@testable import SideStage

final class NavigationScopeTests: XCTestCase {
    func testMobileTabsAreBuyerAndOrdersOnly() {
        XCTAssertEqual(MobileTab.allCases, [.buyer, .orders])
    }

    func testBuyerIsTheInitialTab() {
        XCTAssertEqual(MobileTab.initial, .buyer)
    }

    func testBuyerRoutePreservesEventIdentity() {
        let route = BuyerRoute.liveEvent(id: "event-42", title: "Sunday vintage drop")

        guard case let .liveEvent(id, title) = route else {
            return XCTFail("Expected a live-event route")
        }
        XCTAssertEqual(id, "event-42")
        XCTAssertEqual(title, "Sunday vintage drop")
    }

    func testOrdersRoutePreservesOrderIdentity() {
        let route = OrdersRoute.order(id: "order-17")

        guard case let .order(id) = route else {
            return XCTFail("Expected an order route")
        }
        XCTAssertEqual(id, "order-17")
    }
}
