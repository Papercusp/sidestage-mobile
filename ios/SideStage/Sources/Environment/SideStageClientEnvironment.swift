// SPDX-License-Identifier: MIT

import SideStageCore
import SwiftUI

/// How a screen reaches the shared Rust core.
///
/// One client is built for the app and handed down the view tree, rather than
/// each screen constructing its own: `SideStageClient` owns a tokio runtime and
/// an HTTP connection pool, so one per screen would multiply both for no gain.
///
/// The type is the generated `SideStageClientProtocol`, not the concrete class,
/// so a test or a preview can substitute a stub without a live API.
///
/// It is `Optional` on purpose. Building the client can fail (a malformed base
/// URL), and a screen that renders "unavailable" is a better answer than one
/// that traps at launch — nothing here is worth crashing the app over.
///
/// Written out longhand rather than with the `@Entry` macro: that macro needs a
/// Swift 6 compiler, and this target pins `SWIFT_VERSION = 5.9`.
private struct SideStageClientKey: EnvironmentKey {
    static let defaultValue: SideStageClientProtocol? = SideStageClientFactory.shared
}

extension EnvironmentValues {
    /// The shared core client, or `nil` when one could not be built.
    var sideStageClient: SideStageClientProtocol? {
        get { self[SideStageClientKey.self] }
        set { self[SideStageClientKey.self] = newValue }
    }
}

enum SideStageClientFactory {
    /// The base URL the app talks to.
    ///
    /// Overridable through the `SideStageApiBaseUrl` Info.plist key so a build
    /// can point at a deployed API without a code change. The fallback matches
    /// the web client's `DEFAULT_API_ORIGIN` and the API's own default port, so
    /// a developer running the stack locally needs no configuration at all.
    static let defaultBaseURL = "http://localhost:3100"

    /// The buyer this build acts as.
    ///
    /// Matches Android's `BuildConfig.SIDESTAGE_BUYER_ID` default so the two
    /// shells read the same buyer's cart and order history against one API.
    static let defaultBuyerID = "buyer-ff39f82b"

    static func resolveBaseURL(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["SIDESTAGE_API_BASE_URL"], !override.isEmpty {
            return override
        }
        if let configured = bundle.object(forInfoDictionaryKey: "SideStageApiBaseUrl") as? String,
           !configured.isEmpty {
            return configured
        }
        return defaultBaseURL
    }

    /// Resolved exactly like the base URL — environment first so a UI test can
    /// inject one through `launchEnvironment`, then Info.plist, then the
    /// built-in default.
    static func resolveBuyerID(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["SIDESTAGE_BUYER_ID"], !override.isEmpty {
            return override
        }
        if let configured = bundle.object(forInfoDictionaryKey: "SideStageBuyerId") as? String,
           !configured.isEmpty {
            return configured
        }
        return defaultBuyerID
    }

    /// Give the client the session every buyer-scoped call needs.
    ///
    /// This is not optional plumbing. The core starts with `session: None`, and
    /// two surfaces read it rather than the API: order history builds its query
    /// as `checkout/orders?buyerId=…` from `buyer_id()` and fails outright with
    /// `InvalidSession` without one, and the live room's `bidAvailability`
    /// reports `.signedOut` and disables the bid control. A client handed out
    /// without a session therefore launches and browses perfectly well while
    /// Orders can never load and no bid can ever be placed — which is precisely
    /// the state this app shipped in until now. Android has always installed
    /// one here (`SideStageClientFactory.kt`); iOS simply never did.
    ///
    /// Returns false only if the id itself is rejected by the core.
    @discardableResult
    static func installSession(
        on client: SideStageClientProtocol,
        buyerID: String
    ) -> Bool {
        do {
            try client.setSession(session: ApiSession(buyerId: buyerID, accessToken: nil))
            return true
        } catch {
            return false
        }
    }

    /// Built once. A failure here is not fatal: it leaves the environment value
    /// nil and every screen that needs the core says so plainly.
    static let shared: SideStageClientProtocol? = makeShared()

    private static func makeShared() -> SideStageClientProtocol? {
        guard let client = try? SideStageClient(baseUrl: resolveBaseURL()) else { return nil }

        if installSession(on: client, buyerID: resolveBuyerID()) {
            return client
        }

        // A rejected id is a configuration error (an empty or over-long
        // override), not a transport one. Fall back to the built-in id rather
        // than returning a client with no session: that half-working state is
        // the defect above, and it is worse than either alternative because it
        // fails only on the two surfaces nobody exercises at launch.
        guard installSession(on: client, buyerID: defaultBuyerID) else { return nil }
        return client
    }
}
