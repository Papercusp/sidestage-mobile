// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SideStageCore

/// Loads the buyer's orders from the shared core.
///
/// The division of labour matches the rest of the app: this type talks to the
/// core and owns loading/failure state; `OrdersPresentation` owns every wording
/// and formatting rule and is pure. Nothing here formats, and nothing there
/// touches the FFI.
///
/// ⚠️ SCOPE: the core's `orders()` reads `GET /checkout/orders`, so this is
/// checkout orders only. Auction wins and accepted offers — which the web's
/// Orders tab shows — do not cross the FFI yet, and are not synthesised here.
@MainActor
@Observable
final class OrdersViewModel {
    private let client: SideStageClientProtocol

    private(set) var orders: [CheckoutOrder] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Distinguishes "no orders" from "not asked yet", so the empty state does
    /// not flash before the first load has had a chance to return anything.
    private(set) var hasLoaded = false

    init(client: SideStageClientProtocol) {
        self.client = client
    }

    var isEmpty: Bool { hasLoaded && orders.isEmpty && errorMessage == nil }

    func order(id: String) -> CheckoutOrder? {
        orders.first { $0.id == id }
    }

    /// Loads once. Safe to call from `.task`, which SwiftUI may re-run when the
    /// view identity changes; a completed load is not repeated.
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    /// Loads unconditionally — pull-to-refresh, and the refresh a completed
    /// checkout triggers (D-007: "a successful purchase refreshes Orders").
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await client.orders()
            orders = Self.sorted(loaded)
            hasLoaded = true
        } catch {
            errorMessage = Self.message(for: error)
            // `hasLoaded` stays as it was: a failed refresh must not turn a list
            // the buyer is looking at into an empty state.
        }
    }

    /// Newest first, by the pure rule so the ordering is testable without the
    /// FFI and cannot drift from what the list header claims.
    nonisolated static func sorted(_ orders: [CheckoutOrder]) -> [CheckoutOrder] {
        orders.sorted { lhs, rhs in
            OrdersPresentation.isOrderedBefore(
                lhsCreatedAt: lhs.createdAt,
                lhsID: lhs.id,
                rhsCreatedAt: rhs.createdAt,
                rhsID: rhs.id
            )
        }
    }

    /// Failure mapping for the orders read.
    ///
    /// Deliberately narrower than checkout's: this call charges nothing, so the
    /// offline case says so plainly rather than reassuring about a payment.
    nonisolated static func message(for error: Error) -> String {
        guard let apiError = error as? ApiError else {
            return OrdersPresentation.failureMessage(detail: nil)
        }
        switch apiError {
        case let .Http(status, _) where status == 401 || status == 403:
            return "Sign in again to see your orders."
        case .InvalidSession:
            return "Sign in again to see your orders."
        case .Transport:
            return "You're offline. Your orders will load when you reconnect."
        default:
            return OrdersPresentation.failureMessage(detail: nil)
        }
    }
}
