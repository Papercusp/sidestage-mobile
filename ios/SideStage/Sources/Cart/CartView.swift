// SPDX-License-Identifier: MIT

import SideStageCore
import SwiftUI

/// The buyer's cart: review what the live room added, adjust it, then check out.
///
/// Every figure on screen is the server's — line prices and the subtotal come
/// off the `Cart` the store last received. The quantity stepper's ceiling comes
/// from the shared core, not from a literal typed here.
struct CartView: View {
    @Bindable var store: CartStore

    /// Supplied by the navigation stack, because the route belongs to the stack
    /// rather than to this screen — the same split the live room uses.
    let onCheckout: (String) -> Void

    var body: some View {
        ZStack {
            SideStageTokens.Semantic.background.ignoresSafeArea()
            Group {
                if store.isEmpty {
                    emptyState
                } else {
                    filledCart
                }
            }
        }
        .navigationTitle(CheckoutPresentation.Step.cart.title)
        .accessibilityIdentifier("buyer.cart")
        .task { await store.refresh() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your cart is empty", systemImage: "cart")
        } description: {
            Text("Items added during a live event will appear here.")
        }
    }

    private var filledCart: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(store.items, id: \.productId) { item in
                        CartLineRow(
                            item: item,
                            maximumQuantity: store.maximumQuantity,
                            isBusy: store.isUpdating,
                            onQuantity: { quantity in
                                Task { await store.setQuantity(productID: item.productId, to: quantity) }
                            },
                            onRemove: {
                                Task { await store.remove(productID: item.productId) }
                            }
                        )
                    }
                }

                if let errorMessage = store.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(SideStageTokens.Semantic.danger)
                            .accessibilityIdentifier("buyer.cart.error")
                    }
                }
            }
            .scrollContentBackground(.hidden)

            checkoutBar
        }
    }

    private var checkoutBar: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Subtotal")
                    .foregroundStyle(SideStageTokens.Semantic.textMuted)
                Spacer()
                Text(CheckoutPresentation.formatPrice(cents: store.subtotalCents))
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("buyer.cart.subtotal")
            }
            .font(.subheadline)

            Button {
                // The event is required by `createCheckoutSession`; a cart with
                // no recorded event cannot start one, so the button stays down
                // rather than failing after a tap.
                if let eventID = store.eventID { onCheckout(eventID) }
            } label: {
                Text("Continue to checkout")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isEmpty || store.isUpdating || store.eventID == nil)
            .accessibilityIdentifier("buyer.cart.checkout")
        }
        .padding()
        .background(SideStageTokens.Semantic.background)
    }
}

/// One cart line. Split out so the quantity control's bounds live in one place.
private struct CartLineRow: View {
    let item: CartItem
    let maximumQuantity: UInt32
    let isBusy: Bool
    let onQuantity: (UInt32) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.headline)

            HStack {
                Text(CheckoutPresentation.formatPrice(cents: item.priceCents))
                    .foregroundStyle(SideStageTokens.Semantic.textMuted)
                Spacer()
                Text("×\(item.quantity)")
                    .monospacedDigit()
            }
            .font(.subheadline)

            HStack(spacing: 16) {
                Stepper(
                    "Quantity",
                    value: Binding(
                        get: { Int(item.quantity) },
                        set: { onQuantity(UInt32(max(1, $0))) }
                    ),
                    in: 1...Int(maximumQuantity)
                )
                .labelsHidden()
                .disabled(isBusy)
                .accessibilityIdentifier("buyer.cart.quantity.\(item.productId)")

                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                    .accessibilityIdentifier("buyer.cart.remove.\(item.productId)")
            }
        }
        .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
    }
}
