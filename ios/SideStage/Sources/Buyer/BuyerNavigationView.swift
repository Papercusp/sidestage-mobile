// SPDX-License-Identifier: MIT

import SideStageCore
import SwiftUI

struct BuyerNavigationView: View {
    @State private var path: [BuyerRoute] = []
    @Environment(\.sideStageClient) private var client
    let events: [BuyerFeedItem]

    /// The one cart the buyer tab shares. Handed in rather than built here so
    /// the live room, the cart screen and checkout all operate on the same one.
    let cartStore: CartStore?

    init(events: [BuyerFeedItem] = [], cartStore: CartStore? = nil) {
        self.events = events
        self.cartStore = cartStore
    }

    var body: some View {
        NavigationStack(path: $path) {
            // The browse + search surface is the buyer's landing screen when
            // the core is reachable (P-006). `BuyerFeedView` stays as the
            // fallback: with no client there is nothing to search, and a
            // shell-provided event list still beats an empty tab.
            Group {
                if let client {
                    BuyerBrowseView(
                        client: client,
                        fallbackEvents: events,
                        onSelectEvent: { id, title in
                            path.append(.liveEvent(id: id, title: title))
                        }
                    )
                } else {
                    BuyerFeedView(events: events)
                }
            }
                .navigationDestination(for: BuyerRoute.self) { route in
                    switch route {
                    case let .liveEvent(id, title):
                        // Buy-now has to push checkout, and the path belongs to
                        // this stack — so navigation is handed in rather than
                        // reached for from inside the screen.
                        if let client, let cartStore {
                            LiveEventView(
                                eventID: id,
                                title: title,
                                client: client,
                                cartStore: cartStore,
                                navigate: { path.append($0) }
                            )
                        } else {
                            LiveEventUnavailable(title: title)
                        }
                    case .cart:
                        if let cartStore {
                            CartView(
                                store: cartStore,
                                onCheckout: { path.append(.checkout(eventID: $0)) }
                            )
                        } else {
                            CoreUnavailable(title: CheckoutPresentation.Step.cart.title)
                        }
                    case let .checkout(eventID):
                        if let client, let cartStore {
                            CheckoutDestination(
                                client: client,
                                cartStore: cartStore,
                                eventID: eventID
                            )
                        } else {
                            CoreUnavailable(title: CheckoutPresentation.Step.address.title)
                        }
                    }
                }
        }
    }
}

private struct BuyerFeedView: View {
    let events: [BuyerFeedItem]

    var body: some View {
        ZStack {
            SideStageTokens.Semantic.background.ignoresSafeArea()
            Group {
                if events.isEmpty {
                    ContentUnavailableView {
                        Label("No live events yet", systemImage: "sparkles.tv")
                    } description: {
                        Text("When a seller goes live, the event will appear here.")
                    }
                } else {
                    List(events) { event in
                        NavigationLink(value: BuyerRoute.liveEvent(id: event.id, title: event.title)) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(event.title).font(.headline)
                                    if event.isLive {
                                        Text("LIVE")
                                            .font(.caption.bold())
                                            .foregroundStyle(SideStageTokens.Component.liveIndicator)
                                    }
                                }
                                Text(event.sellerName)
                                    .font(.subheadline)
                                    .foregroundStyle(SideStageTokens.Semantic.textMuted)
                            }
                            .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("SideStage")
        // See LiveEventView: `children: .contain` keeps the listed event rows
        // individually identifiable instead of every one reporting `buyer.feed`.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("buyer.feed")
    }
}

/// Shown when the app could not build a core client at all — a malformed API
/// base URL, essentially. Says what is wrong instead of presenting a live room
/// that can never load.
private struct LiveEventUnavailable: View {
    let title: String

    var body: some View {
        ContentUnavailableView {
            Label("Live room unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text("\(title) can't connect right now. Check the app's API address and try again.")
        }
        .background(SideStageTokens.Semantic.background)
        .navigationTitle("Live event")
        .accessibilityIdentifier("buyer.event.unavailable")
    }
}

/// Shown when there is no core client to talk to, so a cart or checkout screen
/// cannot function. Says what is wrong rather than presenting controls that
/// can only fail.
private struct CoreUnavailable: View {
    let title: String

    var body: some View {
        ContentUnavailableView {
            Label("Unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text("SideStage can't reach its services right now. Check the app's API address and try again.")
        }
        .background(SideStageTokens.Semantic.background)
        .navigationTitle(title)
        .accessibilityIdentifier("buyer.core.unavailable")
    }
}

/// Owns the checkout view model for the lifetime of the pushed screen.
///
/// A `navigationDestination` closure is re-evaluated on redraw, so building the
/// view model inline would discard a half-typed address every time the stack
/// re-rendered. `@State` gives it the screen's lifetime instead.
private struct CheckoutDestination: View {
    @State private var viewModel: CheckoutViewModel

    init(client: SideStageClientProtocol, cartStore: CartStore, eventID: String) {
        _viewModel = State(
            wrappedValue: CheckoutViewModel(
                client: client,
                cartStore: cartStore,
                eventID: eventID
            )
        )
    }

    var body: some View {
        CheckoutView(viewModel: viewModel)
    }
}

#Preview("Buyer feed") {
    BuyerNavigationView(events: [
        BuyerFeedItem(id: "sunday-drop", title: "Sunday vintage drop", sellerName: "SideStage Studio", isLive: true),
    ])
}
