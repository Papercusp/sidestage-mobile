// SPDX-License-Identifier: MIT

import SideStageCore
import SwiftUI

/// The buyer's checkout: address → live shipping rates → Square sandbox →
/// receipt. Mirrors the web surface's ladder so the two cannot diverge.
struct CheckoutView: View {
    @Bindable var viewModel: CheckoutViewModel

    var body: some View {
        ZStack {
            SideStageTokens.Semantic.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(SideStageTokens.Semantic.danger)
                            .accessibilityIdentifier("buyer.checkout.error")
                    }

                    switch viewModel.step {
                    case .cart, .address: addressStep
                    case .shipping: shippingStep
                    case .payment: paymentStep
                    case .success: successStep
                    }
                }
                .padding()
            }
        }
        .navigationTitle(viewModel.step.title)
        .accessibilityIdentifier("buyer.checkout")
    }

    // MARK: - Address

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Email", text: $viewModel.draft.email, field: .email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
            field("Full name", text: $viewModel.draft.name, field: .name)
                .textContentType(.name)
            field("Address", text: $viewModel.draft.line1, field: .line1)
                .textContentType(.streetAddressLine1)
            field("Apt, suite (optional)", text: $viewModel.draft.line2, field: nil)
                .textContentType(.streetAddressLine2)
            field("City", text: $viewModel.draft.city, field: .city)
                .textContentType(.addressCity)
            field("State", text: $viewModel.draft.state, field: .state)
                .textContentType(.addressState)
            field("ZIP code", text: $viewModel.draft.postalCode, field: .postalCode)
                .textContentType(.postalCode)
            field("Country", text: $viewModel.draft.country, field: nil)
                .textContentType(.countryName)
            field("Phone (optional)", text: $viewModel.draft.phone, field: nil)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)

            Button {
                Task { await viewModel.findShippingRates() }
            } label: {
                Text(viewModel.isBusy ? "Finding rates…" : "Find shipping rates")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier("buyer.checkout.findRates")
        }
    }

    /// One labelled input. `field` is the validation identity, or `nil` for the
    /// optional inputs — which is what keeps "missing" highlighting off fields
    /// that were never required.
    private func field(
        _ label: String,
        text: Binding<String>,
        field: CheckoutPresentation.AddressField?
    ) -> some View {
        let isMissing = field.map { viewModel.missingFields.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(SideStageTokens.Semantic.textMuted)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isMissing ? SideStageTokens.Semantic.danger : .clear,
                            lineWidth: isMissing ? 1 : 0
                        )
                )
                .accessibilityIdentifier("buyer.checkout.field.\(field?.rawValue ?? label)")
        }
    }

    // MARK: - Shipping

    private var shippingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.rates.isEmpty {
                Text(CheckoutPresentation.noRatesMessage)
                    .accessibilityIdentifier("buyer.checkout.noRates")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Live rates").font(.headline)
                    ForEach(viewModel.rates, id: \.id) { rate in
                        rateRow(rate)
                    }
                }
            }

            summary

            HStack {
                Button("Edit address") { viewModel.goTo(.address) }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    Task { await viewModel.startCheckout() }
                } label: {
                    Text(viewModel.isBusy ? "Starting checkout…" : "Continue to Square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStartCheckout)
                .accessibilityIdentifier("buyer.checkout.continue")
            }
            .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
        }
    }

    private func rateRow(_ rate: ShippingRate) -> some View {
        Button {
            viewModel.selectedRateID = rate.id
        } label: {
            HStack {
                Image(systemName: viewModel.selectedRateID == rate.id
                    ? "largecircle.fill.circle"
                    : "circle")
                VStack(alignment: .leading, spacing: 2) {
                    Text(CheckoutPresentation.rateTitle(carrier: rate.carrier, service: rate.service))
                        .fontWeight(.semibold)
                    Text(CheckoutPresentation.deliveryEstimate(days: rate.deliveryDays))
                        .font(.caption)
                        .foregroundStyle(SideStageTokens.Semantic.textMuted)
                }
                Spacer()
                Text(CheckoutPresentation.formatPrice(cents: rate.totalCents))
                    .fontWeight(.semibold)
            }
            .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("buyer.checkout.rate.\(rate.id)")
    }

    /// The pre-order preview. Labelled "Estimated total" rather than "Total"
    /// on purpose: no order exists yet, and the server revalidates the cart
    /// before charging anything.
    private var summary: some View {
        VStack(spacing: 6) {
            summaryLine("Cart", cents: viewModel.previewTotalCents - (viewModel.selectedRate?.totalCents ?? 0))
            summaryLine("Shipping", cents: viewModel.selectedRate?.totalCents ?? 0)
            Divider()
            summaryLine("Estimated total", cents: viewModel.previewTotalCents, emphasized: true)
        }
        .accessibilityIdentifier("buyer.checkout.summary")
    }

    private func summaryLine(_ label: String, cents: Int64, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(emphasized ? SideStageTokens.Semantic.text : SideStageTokens.Semantic.textMuted)
            Spacer()
            Text(CheckoutPresentation.formatPrice(cents: cents))
                .fontWeight(emphasized ? .bold : .regular)
        }
        .font(.subheadline)
    }

    // MARK: - Payment

    private var paymentStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let total = viewModel.orderTotalCents {
                HStack {
                    Text("Order total").font(.headline)
                    Spacer()
                    Text(CheckoutPresentation.formatPrice(cents: total))
                        .font(.headline)
                        .accessibilityIdentifier("buyer.checkout.orderTotal")
                }
            }

            if viewModel.needsSquareConfiguration {
                VStack(alignment: .leading, spacing: 6) {
                    Text(CheckoutPresentation.squareNeedsConfigurationTitle).fontWeight(.semibold)
                    Text(CheckoutPresentation.squareNeedsConfigurationDetail)
                        .font(.subheadline)
                        .foregroundStyle(SideStageTokens.Semantic.textMuted)
                }
                .accessibilityIdentifier("buyer.checkout.needsConfiguration")
            } else {
                sandboxPayment
            }

            Button("Back to shipping") { viewModel.goTo(.shipping) }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)
        }
    }

    /// States plainly that this is a sandbox payment rather than presenting a
    /// card form that does not exist. See `CheckoutViewModel.sandboxSourceID`
    /// for why iOS has no tokenized card entry yet.
    private var sandboxPayment: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Square sandbox payment")
                .fontWeight(.semibold)
            Text("This build pays with Square's sandbox test card. No real card is charged.")
                .font(.subheadline)
                .foregroundStyle(SideStageTokens.Semantic.textMuted)

            Button {
                Task { await viewModel.confirmPayment() }
            } label: {
                Text(viewModel.isBusy ? "Paying…" : "Pay with sandbox card")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier("buyer.checkout.pay")
        }
    }

    // MARK: - Success

    private var successStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Payment received", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(SideStageTokens.Semantic.success)
            if let order = viewModel.completedOrder {
                Text(CheckoutPresentation.receiptMessage(orderID: order.id))
                    .font(.subheadline)
                HStack {
                    Text("Paid")
                    Spacer()
                    Text(CheckoutPresentation.formatPrice(cents: order.totalCents))
                        .fontWeight(.bold)
                }
                .font(.subheadline)
            }
            Text("It will appear on the Orders tab.")
                .font(.footnote)
                .foregroundStyle(SideStageTokens.Semantic.textMuted)
        }
        .accessibilityIdentifier("buyer.checkout.success")
    }
}
