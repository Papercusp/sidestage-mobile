// SPDX-License-Identifier: MIT

import SideStageCore
import SwiftUI

/// The buyer's browse + search surface: live shows on top, the searchable
/// product catalog below.
///
/// Every string and every ordering decision comes from
/// `BuyerBrowsePresentation` via `BuyerBrowseViewModel`; this file only lays
/// them out. That split is what lets the rules be asserted against the Android
/// contract without a simulator.
struct BuyerBrowseView: View {
    @State private var model: BuyerBrowseViewModel
    /// Events handed down by the shell. Used ONLY when the core is unreachable
    /// so the tab still shows something rather than an empty screen.
    private let fallbackEvents: [BuyerFeedItem]
    private let onSelectEvent: (String, String) -> Void

    init(
        client: SideStageClientProtocol,
        fallbackEvents: [BuyerFeedItem] = [],
        onSelectEvent: @escaping (String, String) -> Void
    ) {
        _model = State(wrappedValue: BuyerBrowseViewModel(client: client))
        self.fallbackEvents = fallbackEvents
        self.onSelectEvent = onSelectEvent
    }

    var body: some View {
        ZStack {
            SideStageTokens.Semantic.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                    filters
                    eventsSection
                    productsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable { await model.refresh() }
        }
        .navigationTitle(BuyerBrowsePresentation.title)
        .searchable(
            text: Binding(
                get: { model.query.text },
                set: { model.setSearchText($0) }
            ),
            prompt: BuyerBrowsePresentation.searchPrompt
        )
        .task { await model.loadIfNeeded() }
    }

    // MARK: - Filters

    @ViewBuilder
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.productTypes, id: \.self) { type in
                        Button {
                            Task { await model.setProductType(type) }
                        } label: {
                            Text(BuyerBrowsePresentation.productTypeLabel(type))
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    type == model.query.productType
                                        ? SideStageTokens.Semantic.surfaceRaised
                                        : SideStageTokens.Semantic.surface
                                )
                                .foregroundStyle(
                                    type == model.query.productType
                                        ? SideStageTokens.Semantic.accentStrong
                                        : SideStageTokens.Semantic.textMuted
                                )
                                .clipShape(Capsule())
                        }
                        .accessibilityAddTraits(
                            type == model.query.productType ? [.isSelected] : []
                        )
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { model.query.inStockOnly },
                set: { value in Task { await model.setInStockOnly(value) } }
            )) {
                Text("In stock only")
                    .font(.subheadline)
                    .foregroundStyle(SideStageTokens.Semantic.textMuted)
            }
            .tint(SideStageTokens.Semantic.accent)
        }
    }

    // MARK: - Events

    @ViewBuilder
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(BuyerBrowsePresentation.eventsSectionTitle, trailing: nil)

            if model.loadingEvents, model.visibleEvents.isEmpty {
                ProgressView().tint(SideStageTokens.Semantic.accent)
            } else if model.visibleEvents.isEmpty {
                // The shell-provided list is the fallback for an unreachable
                // core; when the core answered and simply had nothing, say so.
                if model.hasLoaded {
                    emptyLine(BuyerBrowsePresentation.emptyEventsMessage(query: model.query.text))
                } else if fallbackEvents.isEmpty {
                    emptyLine(BuyerBrowsePresentation.emptyEventsMessage(query: model.query.text))
                } else {
                    ForEach(fallbackEvents) { event in
                        eventRow(
                            id: event.id,
                            title: event.title,
                            sellerName: event.sellerName,
                            isLive: event.isLive
                        )
                    }
                }
            } else {
                ForEach(model.visibleEvents, id: \.eventId) { event in
                    eventRow(
                        id: event.eventId,
                        title: event.title,
                        sellerName: event.sellerName,
                        isLive: BuyerBrowseViewModel.phase(event.status) == .live
                    )
                }
            }
        }
    }

    private func eventRow(id: String, title: String, sellerName: String, isLive: Bool) -> some View {
        Button {
            onSelectEvent(id, title)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(SideStageTokens.Semantic.text)
                        if isLive {
                            Text("LIVE")
                                .font(.caption.bold())
                                .foregroundStyle(SideStageTokens.Component.liveIndicator)
                        }
                    }
                    Text(sellerName)
                        .font(.subheadline)
                        .foregroundStyle(SideStageTokens.Semantic.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(SideStageTokens.Semantic.textFaint)
            }
            .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
            .padding(.horizontal, 12)
            .background(SideStageTokens.Semantic.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Products

    @ViewBuilder
    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                BuyerBrowsePresentation.productsSectionTitle,
                trailing: model.hasLoaded ? model.resultCountLabel : nil
            )

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(SideStageTokens.Semantic.textMuted)
                    .padding(.vertical, 8)
            }

            if model.loadingProducts, model.products.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(SideStageTokens.Semantic.accent)
                    Text(BuyerBrowsePresentation.loadingMessage)
                        .font(.subheadline)
                        .foregroundStyle(SideStageTokens.Semantic.textMuted)
                }
            } else if model.isEmptyProducts {
                emptyLine(BuyerBrowsePresentation.emptyProductsMessage(query: model.query.text))
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(model.products) { card in
                        productCell(card)
                    }
                }

                if model.hasMore {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        HStack(spacing: 8) {
                            if model.loadingMore {
                                ProgressView().tint(SideStageTokens.Semantic.accent)
                            }
                            Text(BuyerBrowsePresentation.loadMoreLabel)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SideStageTokens.Semantic.accent)
                    .disabled(model.loadingMore)
                }
            }
        }
    }

    private func productCell(_ card: ProductCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SideStageTokens.Semantic.surfaceRaised)
                Text(card.monogram)
                    .font(.title.bold())
                    .foregroundStyle(SideStageTokens.Semantic.textFaint)
            }
            .frame(height: 96)

            Text(card.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SideStageTokens.Semantic.text)
                .lineLimit(2)
            Text(card.subtitle)
                .font(.caption)
                .foregroundStyle(SideStageTokens.Semantic.textMuted)
                .lineLimit(1)
            HStack {
                Text(card.priceLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SideStageTokens.Semantic.text)
                Spacer(minLength: 0)
                Text(card.soldOut ? BuyerBrowsePresentation.soldOutLabel : card.readyLabel)
                    .font(.caption)
                    .foregroundStyle(
                        card.soldOut
                            ? SideStageTokens.Semantic.textFaint
                            : SideStageTokens.Semantic.accent
                    )
            }
        }
        .padding(10)
        .background(SideStageTokens.Semantic.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(card.soldOut ? 0.65 : 1)
        // One label for the whole cell: a grid of four separately-focusable
        // fragments per product makes VoiceOver paging through the catalog
        // four times as long for no added information.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(card.title), \(card.subtitle), \(card.priceLabel), "
                + (card.soldOut ? BuyerBrowsePresentation.soldOutLabel : card.readyLabel)
        )
    }

    // MARK: - Bits

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SideStageTokens.Semantic.text)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(SideStageTokens.Semantic.textFaint)
            }
        }
    }

    private func emptyLine(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(SideStageTokens.Semantic.textMuted)
            .padding(.vertical, 8)
    }
}
