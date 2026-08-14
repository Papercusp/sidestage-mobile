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

    /// Built once. A failure here is not fatal: it leaves the environment value
    /// nil and every screen that needs the core says so plainly.
    static let shared: SideStageClientProtocol? = try? SideStageClient(
        baseUrl: resolveBaseURL()
    )
}
