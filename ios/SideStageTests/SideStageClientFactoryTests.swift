// SPDX-License-Identifier: MIT

import XCTest
@testable import SideStage
import SideStageCore

/// Tests for how the shared client is configured before any screen sees it.
///
/// These exist because of a defect that was invisible to every other suite: the
/// app built its client and never gave it a session. Nothing crashed and
/// nothing failed to compile — browse and cart do not need one — but
/// `checkout/orders?buyerId=…` is built from the session's buyer id and returns
/// `InvalidSession` without it, and the live room's bid control reads the
/// session directly and stays `.signedOut` forever. So the Orders tab could
/// never load and no bid could ever be placed, in a build whose tests were all
/// green.
///
/// The lesson those tests encode: a dependency that is only *read* by two
/// screens is exactly the one that gets left unwired, because the screens that
/// do not read it work perfectly. Assert the wiring itself, not just the
/// screens.
final class SideStageClientFactoryTests: XCTestCase {
    // MARK: - Session installation

    /// The invariant the defect violated.
    func testInstallSessionGivesTheClientASession() {
        let client = FakeSideStageClient()
        XCTAssertNil(client.session(), "a fresh client must start with no session")

        XCTAssertTrue(SideStageClientFactory.installSession(on: client, buyerID: "buyer-test"))

        XCTAssertEqual(
            client.session()?.buyerId,
            "buyer-test",
            "installSession must leave the client carrying the buyer it was given"
        )
    }

    /// Order history and bidding both read the buyer id off the session rather
    /// than being passed one, which is why an absent session disables them
    /// silently instead of failing loudly at the call site.
    func testSessionCarriesNoAccessTokenForAnAnonymousBuyer() {
        let client = FakeSideStageClient()
        SideStageClientFactory.installSession(on: client, buyerID: "buyer-test")

        XCTAssertNil(
            client.session()?.accessToken,
            "the sandbox buyer is anonymous; a token here would be fabricated"
        )
    }

    // MARK: - Buyer id resolution

    func testBuyerIDPrefersTheEnvironmentOverride() {
        XCTAssertEqual(
            SideStageClientFactory.resolveBuyerID(
                bundle: .main,
                environment: ["SIDESTAGE_BUYER_ID": "buyer-from-env"]
            ),
            "buyer-from-env",
            "launchEnvironment is how a UI test points the app at a stub's buyer"
        )
    }

    func testBuyerIDIgnoresAnEmptyOverride() {
        XCTAssertEqual(
            SideStageClientFactory.resolveBuyerID(
                bundle: .main,
                environment: ["SIDESTAGE_BUYER_ID": ""]
            ),
            SideStageClientFactory.defaultBuyerID,
            "an empty override is an unset one, not a request for an empty buyer id"
        )
    }

    func testBuyerIDFallsBackToTheBuiltInDefault() {
        XCTAssertEqual(
            SideStageClientFactory.resolveBuyerID(bundle: .main, environment: [:]),
            SideStageClientFactory.defaultBuyerID
        )
    }

    /// Parity guard. The two shells are supposed to act as the same buyer
    /// against one API, so this default is not free to drift: Android's
    /// `sidestageBuyerId` Gradle property defaults to this exact value in
    /// `android/app/build.gradle.kts`. If someone changes one side, this fails
    /// and points at the other.
    func testDefaultBuyerIDMatchesAndroid() {
        XCTAssertEqual(SideStageClientFactory.defaultBuyerID, "buyer-ff39f82b")
    }

    // MARK: - Base URL resolution

    /// The seam the UI test suite depends on: without environment-first
    /// resolution there is no way to point the shipping binary at a stub, and
    /// the buyer loop could not be driven end to end at all.
    func testBaseURLPrefersTheEnvironmentOverride() {
        XCTAssertEqual(
            SideStageClientFactory.resolveBaseURL(
                bundle: .main,
                environment: ["SIDESTAGE_API_BASE_URL": "http://127.0.0.1:54321/api"]
            ),
            "http://127.0.0.1:54321/api"
        )
    }

    func testBaseURLIgnoresAnEmptyOverride() {
        XCTAssertEqual(
            SideStageClientFactory.resolveBaseURL(
                bundle: .main,
                environment: ["SIDESTAGE_API_BASE_URL": ""]
            ),
            SideStageClientFactory.defaultBaseURL
        )
    }
}
