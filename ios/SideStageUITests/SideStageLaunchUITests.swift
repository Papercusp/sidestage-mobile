// SPDX-License-Identifier: MIT
import XCTest

/// Launch smoke test for the SideStage buyer app.
///
/// `ios/project.yml` declares a `SideStageUITests` target and the SideStage
/// scheme wires it into the `test` action, so XcodeGen requires this directory
/// to exist — a missing one fails `xcodegen generate` outright with
/// "Target \"SideStageUITests\" has a missing source directory", which blocks
/// project generation before any build can start.
///
/// Rather than satisfy that with an empty stub, this asserts the invariant the
/// buyer shell is built around: the app launches and presents exactly the two
/// tabs that D-007/D-008 scoped it to (Buyer and Orders — no Seller, History,
/// Config or Test surfaces). Titles come from `MobileTab.title`.
final class SideStageLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesIntoBuyerAndOrdersTabs() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "SideStage did not reach the foreground after launch"
        )

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: 30),
            "No tab bar appeared after launch"
        )

        for title in ["Buyer", "Orders"] {
            XCTAssertTrue(
                tabBar.buttons[title].waitForExistence(timeout: 10),
                "Expected a \(title) tab after launch"
            )
        }

        // Scope guard: the buyer shell ships two tabs only. A third arriving
        // here means a surface was added without revisiting D-007/D-008.
        XCTAssertEqual(
            tabBar.buttons.count,
            2,
            "Expected exactly the Buyer and Orders tabs, found \(tabBar.buttons.count)"
        )
    }

    @MainActor
    func testOrdersTabIsReachableFromLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let ordersTab = app.tabBars.firstMatch.buttons["Orders"]
        XCTAssertTrue(
            ordersTab.waitForExistence(timeout: 30),
            "Orders tab was not present after launch"
        )

        ordersTab.tap()
        XCTAssertTrue(
            ordersTab.isSelected,
            "Tapping the Orders tab did not select it"
        )
    }
}
