// SPDX-License-Identifier: MIT

import Foundation
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
            "http://10.0.2.2:3100",
            "an empty environment override must fall through to the installed bundle configuration"
        )
    }

    /// Cross-client parity guard. The iOS and Android shells are the same buyer
    /// experience, so their checked-in defaults must resolve to one catalog
    /// authority. Read Android's actual Gradle writer instead of copying its
    /// expected value into a second assertion that could drift independently.
    func testInstalledAppConfigurationMatchesAndroidDemoAPI() throws {
        let baseURL = SideStageClientFactory.resolveBaseURL(bundle: .main, environment: [:])
        let buyerID = SideStageClientFactory.resolveBuyerID(bundle: .main, environment: [:])

        XCTAssertEqual(baseURL, try androidDefaultAPIBaseURL())
        XCTAssertEqual(baseURL, "http://10.0.2.2:3100")
        XCTAssertEqual(buyerID, "buyer-ff39f82b")
        XCTAssertFalse(baseURL.contains("localhost"))
    }

    /// The local demo route must not weaken transport policy for unrelated
    /// hosts. iOS 17+ supports a scoped local-network ATS allowance, so a broad
    /// NSAllowsArbitraryLoads escape hatch would be a regression.
    func testInstalledAppDeclaresOnlyLocalNetworkAccess() throws {
        let transport = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        )
        XCTAssertEqual(transport["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNil(transport["NSAllowsArbitraryLoads"])

        let purpose = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        )
        XCTAssertFalse(purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// A simulator installs the generated app bundle, not an editor's shell
    /// environment. Prove that the configured demo authority is reachable from
    /// the hosted simulator test process.
    func testInstalledAppConfigurationReachesTheDemoAPI() async throws {
        let baseURL = SideStageClientFactory.resolveBaseURL(bundle: .main, environment: [:])

        guard var healthComponents = URLComponents(string: baseURL) else {
            return XCTFail("generated SideStageApiBaseUrl is not a URL: \(baseURL)")
        }
        healthComponents.path = "/healthz"
        healthComponents.query = nil
        healthComponents.fragment = nil
        guard let healthURL = healthComponents.url else {
            return XCTFail("could not derive /healthz from generated API URL: \(baseURL)")
        }

        let (data, response) = try await URLSession.shared.data(from: healthURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(body["status"] as? String, "ok")
    }

    private func androidDefaultAPIBaseURL() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SideStageTests
            .deletingLastPathComponent() // ios
        let gradlePath = repositoryRoot.appendingPathComponent("android/app/build.gradle.kts")
        let gradle = try String(contentsOf: gradlePath, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"providers\.gradleProperty\("sidestageApiBaseUrl"\)\.getOrElse\("([^"]+)"\)"#
        )
        let sourceRange = NSRange(gradle.startIndex..., in: gradle)
        let match = try XCTUnwrap(
            expression.firstMatch(in: gradle, range: sourceRange),
            "could not find Android's sidestageApiBaseUrl default in \(gradlePath.path)"
        )
        let valueRange = try XCTUnwrap(Range(match.range(at: 1), in: gradle))
        return String(gradle[valueRange])
    }
}
