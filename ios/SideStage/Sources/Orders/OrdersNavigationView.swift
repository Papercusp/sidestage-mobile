// SPDX-License-Identifier: MIT

import SideStageCore
import SwiftUI

/// The Orders tab: what the buyer has bought, newest first, and the receipt for
/// any one of them.
///
/// Everything shown comes from the core's `orders()`; every string comes from
/// `OrdersPresentation`. This file lays out — it neither fetches nor formats.
struct OrdersNavigationView: View {
    @Environment(\.sideStageClient) private var client

    /// Whether this tab is the one on screen. Selecting the tab reloads the
    /// list, which is how D-007's "a successful purchase refreshes Orders" is
    /// satisfied without the Buyer tab having to reach across and poke this one:
    /// the buyer's own move to the Orders tab is the refresh trigger.
    let isActive: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        if let client {
            OrdersStack(client: client, isActive: isActive)
        } else {
            NavigationStack {
                ZStack {
                    SideStageTokens.Semantic.background.ignoresSafeArea()
                    ContentUnavailableView {
                        Label(OrdersPresentation.coreUnavailableTitle, systemImage: "wifi.slash")
                    } description: {
                        Text(OrdersPresentation.coreUnavailableMessage)
                    }
                }
                .navigationTitle(OrdersPresentation.title)
                .accessibilityIdentifier("orders.unavailable")
            }
        }
    }
}

private struct OrdersStack: View {
    @State private var path: [OrdersRoute] = []
    @State private var model: OrdersViewModel
    private let isActive: Bool

    /// Main-actor isolated because the view model is: only `body` inherits
    /// SwiftUI's isolation.
    @MainActor
    init(client: SideStageClientProtocol, isActive: Bool) {
        _model = State(wrappedValue: OrdersViewModel(client: client))
        self.isActive = isActive
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SideStageTokens.Semantic.background.ignoresSafeArea()
                content
            }
            .navigationTitle(OrdersPresentation.title)
            .accessibilityIdentifier("orders.list")
            .navigationDestination(for: OrdersRoute.self) { route in
                switch route {
                case let .order(id):
                    if let order = model.order(id: id) {
                        OrderDetailView(order: order)
                    } else {
                        // The order left the list while its detail was open —
                        // say so rather than rendering an empty receipt.
                        ContentUnavailableView {
                            Label("Order unavailable", systemImage: "shippingbox")
                        } description: {
                            Text(OrdersPresentation.orderReference(id: id))
                        }
                        .accessibilityIdentifier("orders.detail.missing")
                    }
                }
            }
        }
        // Reloads on first appearance and again whenever the tab is selected.
        .task(id: isActive) {
            guard isActive else { return }
            await model.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = model.errorMessage, model.orders.isEmpty {
            ContentUnavailableView {
                Label(OrdersPresentation.coreUnavailableTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try again") { Task { await model.load() } }
                    .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
            }
            .accessibilityIdentifier("orders.error")
        } else if model.isLoading, model.orders.isEmpty {
            ProgressView(OrdersPresentation.loadingMessage)
                .tint(SideStageTokens.Semantic.accent)
                .accessibilityIdentifier("orders.loading")
        } else if model.isEmpty {
            ContentUnavailableView {
                Label(OrdersPresentation.emptyTitle, systemImage: "shippingbox")
            } description: {
                Text(OrdersPresentation.emptyMessage)
            }
            .accessibilityIdentifier("orders.empty")
        } else {
            list
        }
    }

    private var list: some View {
        List {
            // A refresh that failed while orders are already on screen is shown
            // as a banner, not by replacing the list the buyer is reading.
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(SideStageTokens.Semantic.warning)
                    .listRowBackground(SideStageTokens.Semantic.surface)
                    .accessibilityIdentifier("orders.refresh-error")
            }

            ForEach(model.orders, id: \.id) { order in
                NavigationLink(value: OrdersRoute.order(id: order.id)) {
                    OrderRow(order: order)
                }
                .listRowBackground(SideStageTokens.Semantic.surface)
                .accessibilityIdentifier("orders.row.\(order.id)")
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }
}

/// One row: when, what it cost, and where it stands.
private struct OrderRow: View {
    let order: CheckoutOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OrdersPresentation.formatDate(order.createdAt))
                .font(.subheadline)
                .foregroundStyle(SideStageTokens.Semantic.textMuted)

            Text(OrdersPresentation.itemCountLabel(order.items.count))
                .font(.headline)
                .foregroundStyle(SideStageTokens.Semantic.text)

            HStack {
                StatusChip(status: order.status)
                Spacer()
                Text(OrdersPresentation.formatPrice(cents: order.totalCents))
                    .fontWeight(.semibold)
                    .foregroundStyle(SideStageTokens.Semantic.text)
            }
            .font(.subheadline)
        }
        .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
    }
}

private struct StatusChip: View {
    let status: String

    private var tint: Color {
        if OrdersPresentation.isFailed(status) { return SideStageTokens.Semantic.danger }
        if OrdersPresentation.isSettled(status) { return SideStageTokens.Semantic.success }
        return SideStageTokens.Semantic.textMuted
    }

    var body: some View {
        Text(OrdersPresentation.statusLabel(status))
            .foregroundStyle(tint)
    }
}

/// The receipt: what was bought, what it cost, and where it is going.
private struct OrderDetailView: View {
    let order: CheckoutOrder

    var body: some View {
        ZStack {
            SideStageTokens.Semantic.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    items
                    totals
                    if let address = order.shippingAddress {
                        shipping(address: address)
                    }
                    Text(OrdersPresentation.orderReference(id: order.id))
                        .font(.footnote)
                        .foregroundStyle(SideStageTokens.Semantic.textFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .navigationTitle("Order")
        .accessibilityIdentifier("orders.detail.\(order.id)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OrdersPresentation.formatDate(order.createdAt))
                .font(.subheadline)
                .foregroundStyle(SideStageTokens.Semantic.textMuted)
            StatusChip(status: order.status)
                .font(.headline)
        }
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(order.items, id: \.productId) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(SideStageTokens.Semantic.text)
                    Text(
                        OrdersPresentation.itemLine(
                            quantity: item.quantity,
                            unitPriceCents: item.priceCents
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(SideStageTokens.Semantic.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Server figures only. Nothing on this screen is summed locally — the
    /// order's own totals are the ones the buyer was actually charged.
    private var totals: some View {
        VStack(alignment: .leading, spacing: 6) {
            totalRow("Subtotal", cents: order.subtotalCents, emphasised: false)
            if let note = OrdersPresentation.shippingNote(shippingCents: order.shippingCents) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(SideStageTokens.Semantic.textMuted)
            }
            totalRow("Total", cents: order.totalCents, emphasised: true)
        }
    }

    private func totalRow(_ label: String, cents: Int64, emphasised: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(SideStageTokens.Semantic.textMuted)
            Spacer()
            Text(OrdersPresentation.formatPrice(cents: cents))
                .fontWeight(emphasised ? .bold : .regular)
                .foregroundStyle(SideStageTokens.Semantic.text)
        }
        .font(emphasised ? .headline : .subheadline)
    }

    private func shipping(address: ShippingAddress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Shipping to")
                .font(.subheadline)
                .foregroundStyle(SideStageTokens.Semantic.textMuted)
            Text(address.name)
                .foregroundStyle(SideStageTokens.Semantic.text)
            Text(address.line1)
                .foregroundStyle(SideStageTokens.Semantic.text)
            if let line2 = address.line2, !line2.isEmpty {
                Text(line2).foregroundStyle(SideStageTokens.Semantic.text)
            }
            Text("\(address.city), \(address.state) \(address.postalCode)")
                .foregroundStyle(SideStageTokens.Semantic.text)
        }
        .font(.subheadline)
    }
}
