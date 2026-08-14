// SPDX-License-Identifier: MIT

import SideStageCore
import SwiftUI

/// The app's two tabs, and the one place the buyer's cart is created.
///
/// The cart has to outlive any single screen — a buyer adds from the live room,
/// leaves, and expects the cart tab to still hold it — so exactly one
/// `CartStore` is built here and handed down, rather than each screen making its
/// own (which would give the same buyer several disagreeing carts).
struct SideStageRootView: View {
    @Environment(\.sideStageClient) private var client

    var body: some View {
        // The store needs the client, and `@Environment` is not readable from an
        // initializer — so the tabs live in a child view that takes the client as
        // a plain value and builds the store once in its own `@State`.
        if let client {
            SideStageTabs(client: client)
        } else {
            // No core: the tabs still render, and each screen says plainly that
            // it is unavailable rather than the app failing to launch.
            SideStageTabs()
        }
    }
}

private struct SideStageTabs: View {
    @State private var selectedTab: MobileTab = .initial
    @State private var cartStore: CartStore?

    /// Main-actor isolated because `CartStore` is: only `body` inherits
    /// SwiftUI's isolation, so an unannotated initializer would be constructing
    /// main-actor state from a nonisolated context.
    @MainActor
    init(client: SideStageClientProtocol) {
        _cartStore = State(wrappedValue: CartStore(client: client))
    }

    init() {
        _cartStore = State<CartStore?>(wrappedValue: nil)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            BuyerNavigationView(cartStore: cartStore)
                .tag(MobileTab.buyer)
                .tabItem {
                    Label(MobileTab.buyer.title, systemImage: MobileTab.buyer.symbolName)
                }
                .accessibilityIdentifier("tab.buyer")

            // Selecting the tab is what refreshes the list, so that a purchase
            // made in the Buyer tab is reflected the moment the buyer looks
            // (D-007) without the two tabs having to know about each other.
            OrdersNavigationView(isActive: selectedTab == .orders)
                .tag(MobileTab.orders)
                .tabItem {
                    Label(MobileTab.orders.title, systemImage: MobileTab.orders.symbolName)
                }
                .accessibilityIdentifier("tab.orders")
        }
        .tint(SideStageTokens.Semantic.accent)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    SideStageRootView()
}
