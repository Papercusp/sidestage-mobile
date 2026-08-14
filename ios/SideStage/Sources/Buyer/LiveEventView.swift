// SPDX-License-Identifier: MIT

import SideStageCore
import SwiftUI

/// The buyer's live room: the stage, what is on deck, and the auction.
///
/// Ordered by what a buyer in a live room is actually doing — watching first,
/// then seeing the item, then bidding on it. The auction block sits last and
/// closest to the thumb because it is the only part under time pressure.
///
/// Every value shown here comes from `LiveEventViewModel`, which gets it from
/// the shared core. This file formats; it does not decide.
struct LiveEventView: View {
    @State private var model: LiveEventViewModel
    private let title: String
    private let navigate: (BuyerRoute) -> Void

    /// Main-actor isolated because the view model is: only `body` inherits
    /// SwiftUI's isolation, so an unannotated initializer would be constructing
    /// main-actor state from a nonisolated context.
    @MainActor
    init(
        eventID: String,
        title: String,
        client: SideStageClientProtocol,
        cartStore: CartStore,
        navigate: @escaping (BuyerRoute) -> Void
    ) {
        _model = State(
            wrappedValue: LiveEventViewModel(
                eventID: eventID,
                client: client,
                cartStore: cartStore
            )
        )
        self.title = title
        self.navigate = navigate
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StageSurface(
                    title: model.event?.title ?? title,
                    thumbnailURL: model.event?.thumbnailUrl,
                    viewers: model.event?.viewers,
                    isLive: model.event.map { $0.status == .live } ?? true,
                    connection: model.connection,
                    streamError: model.streamError
                )

                if let product = model.onDeckProduct {
                    OnDeckRail(
                        product: product,
                        isBusy: model.isUpdatingCart,
                        errorMessage: model.cartError,
                        addToCart: { Task { await model.addOnDeckToCart() } },
                        buyNow: { Task { await model.buyOnDeckNow(then: navigate) } }
                    )
                }

                if let auction = model.auction {
                    AuctionBlock(
                        auction: auction,
                        leadingBid: model.leadingBid,
                        availability: model.bidAvailability,
                        errorMessage: model.bidError,
                        bidText: $model.bidText,
                        placeBid: { Task { await model.placeBid() } }
                    )
                }

                CartLink(itemCount: model.cartItemCount)
            }
            .padding()
        }
        .background(SideStageTokens.Semantic.background.ignoresSafeArea())
        .navigationTitle("Live event")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("buyer.event.\(model.eventID)")
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - Stage

/// The video surface.
///
/// The thumbnail is the poster, exactly as the web player uses it: the room has
/// a face before any stream arrives, instead of a black rectangle. There is no
/// player here yet on purpose — no playback URL crosses the core's API today
/// (`EventSummary` carries a thumbnail and nothing else), and inventing one
/// client-side would be a second source of truth about where the stream lives.
private struct StageSurface: View {
    let title: String
    let thumbnailURL: String?
    let viewers: UInt64?
    let isLive: Bool
    let connection: LiveConnectionState
    let streamError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Rectangle().fill(SideStageTokens.Semantic.stage)
                if let thumbnailURL, let url = URL(string: thumbnailURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ProgressView().tint(SideStageTokens.Semantic.accent)
                    }
                } else {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(SideStageTokens.Semantic.accent)
                }

                VStack {
                    HStack(alignment: .top) {
                        if isLive {
                            Text("LIVE")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(SideStageTokens.Component.liveIndicator.opacity(0.9))
                                .foregroundStyle(SideStageTokens.Semantic.stage)
                                .clipShape(Capsule())
                                .accessibilityIdentifier("buyer.event.live")
                        }
                        Spacer()
                        ConnectionChip(state: connection)
                    }
                    Spacer()
                    if let viewers {
                        HStack {
                            Label(
                                "\(viewers) watching",
                                systemImage: "eye.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(SideStageTokens.Semantic.text)
                            .accessibilityIdentifier("buyer.event.viewers")
                            Spacer()
                        }
                    }
                }
                .padding(10)
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(SideStageTokens.Semantic.border)
            )

            Text(title)
                .font(.title3.bold())
                .foregroundStyle(SideStageTokens.Semantic.text)

            if let streamError {
                Text(streamError)
                    .font(.footnote)
                    .foregroundStyle(SideStageTokens.Semantic.warning)
                    .accessibilityIdentifier("buyer.event.streamError")
            }
        }
    }
}

/// Connection state, phrased as still-working while the core is on its REST
/// fallback — that path recovers on its own, so alarming the buyer would
/// misrepresent what is happening.
private struct ConnectionChip: View {
    let state: LiveConnectionState

    private var tint: Color {
        switch state {
        case .live: SideStageTokens.Component.liveIndicator
        case .connecting: SideStageTokens.Semantic.textMuted
        case .reconnecting: SideStageTokens.Semantic.warning
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(LiveEventPresentation.connectionLabel(state))
                .font(.caption)
                .foregroundStyle(SideStageTokens.Semantic.text)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SideStageTokens.Semantic.surfaceRaised)
        .clipShape(Capsule())
        .accessibilityIdentifier("buyer.event.connection")
    }
}

// MARK: - On deck

/// What the seller is presenting right now, with the two ways to take it.
///
/// Add-to-cart is the default and keeps the buyer on the stream; buy-now hands
/// off to checkout. Both are one tap, because a live room does not wait.
private struct OnDeckRail: View {
    let product: CatalogVariant
    let isBusy: Bool
    let errorMessage: String?
    let addToCart: () -> Void
    let buyNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On deck")
                .font(.caption.bold())
                .foregroundStyle(SideStageTokens.Semantic.textMuted)

            HStack(alignment: .top, spacing: 12) {
                if let imageURL = product.imageUrl, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        SideStageTokens.Semantic.surfaceRaised
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(product.title)
                        .font(.headline)
                        .foregroundStyle(SideStageTokens.Semantic.text)
                    Text(product.brand)
                        .font(.subheadline)
                        .foregroundStyle(SideStageTokens.Semantic.textMuted)
                    Text(LiveEventPresentation.formatPrice(cents: product.priceCents))
                        .font(.title3.bold())
                        .foregroundStyle(SideStageTokens.Semantic.text)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: addToCart) {
                    Label("Add to cart", systemImage: "cart.badge.plus")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: SideStageTokens.Component.minimumTouchTarget
                        )
                }
                .buttonStyle(.bordered)
                .tint(SideStageTokens.Semantic.accent)
                .disabled(isBusy)
                .accessibilityIdentifier("buyer.event.addToCart")

                Button(action: buyNow) {
                    Text("Buy now")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: SideStageTokens.Component.minimumTouchTarget
                        )
                }
                .buttonStyle(.borderedProminent)
                .tint(SideStageTokens.Component.primaryButtonBackground)
                .foregroundStyle(SideStageTokens.Component.primaryButtonText)
                .disabled(isBusy)
                .accessibilityIdentifier("buyer.event.buyNow")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(SideStageTokens.Semantic.danger)
                    .accessibilityIdentifier("buyer.event.cartError")
            }
        }
        .padding()
        .background(SideStageTokens.Semantic.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // `children: .contain` is REQUIRED alongside a block-level identifier.
        // Without it the identifier propagates onto every descendant and
        // OVERRIDES the descendant's own — measured in the live element tree,
        // where the bid TextField, "Place bid" button and current-price label all
        // reported `buyer.event.auction` and their real identifiers existed
        // nowhere. That is an accessibility defect first (VoiceOver loses each
        // control's identity) and only incidentally a testing one.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("buyer.event.onDeck")
    }
}

// MARK: - Auction

private struct AuctionBlock: View {
    let auction: LiveAuction
    let leadingBid: AuctionBid?
    let availability: BidAvailability
    let errorMessage: String?
    @Binding var bidText: String
    let placeBid: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current bid")
                        .font(.caption.bold())
                        .foregroundStyle(SideStageTokens.Semantic.textMuted)
                    Text(LiveEventPresentation.formatPrice(cents: auction.currentPriceCents))
                        .font(.largeTitle.bold())
                        .foregroundStyle(SideStageTokens.Semantic.text)
                        .accessibilityIdentifier("buyer.event.currentPrice")
                }
                Spacer()
                Countdown(endsAt: auction.endsAt, isOpen: isOpen)
            }

            if let leadingBid {
                Label(
                    "\(leadingBid.displayName ?? "A buyer") leads",
                    systemImage: "crown.fill"
                )
                .font(.subheadline)
                .foregroundStyle(SideStageTokens.Component.auctionLeader)
                .accessibilityIdentifier("buyer.event.leader")
            }

            HStack(spacing: 10) {
                TextField("Amount", text: $bidText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
                    .accessibilityIdentifier("buyer.event.bidField")

                Button(action: placeBid) {
                    Group {
                        if case .submitting = availability {
                            ProgressView()
                        } else {
                            Text("Place bid")
                        }
                    }
                    .frame(minWidth: 96, minHeight: SideStageTokens.Component.minimumTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(SideStageTokens.Component.primaryButtonBackground)
                .foregroundStyle(SideStageTokens.Component.primaryButtonText)
                .disabled(!availability.isReady)
                .accessibilityIdentifier("buyer.event.placeBid")
            }

            // The disabled button always says why. A dead control with no
            // explanation is the thing this screen must never show during a
            // live auction.
            if let message = availability.message() {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(SideStageTokens.Component.bidWarning)
                    .accessibilityIdentifier("buyer.event.bidHint")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(SideStageTokens.Semantic.danger)
                    .accessibilityIdentifier("buyer.event.bidError")
            }
        }
        .padding()
        .background(SideStageTokens.Semantic.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("buyer.event.auction")
    }

    /// Openness is the server's call, mirroring the core's `is_open`: status
    /// alone. The countdown is display; it never disables the bid button, so a
    /// client clock that runs fast cannot block a bid the API would accept.
    private var isOpen: Bool {
        if case .active = auction.status { return true }
        return false
    }
}

/// Ticks once a second off the render timeline rather than a stored timer, so
/// the countdown costs nothing when the screen is not on-screen.
private struct Countdown: View {
    let endsAt: String
    let isOpen: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = LiveEventPresentation.secondsRemaining(endsAt: endsAt, now: context.date)
            VStack(alignment: .trailing, spacing: 2) {
                Text(isOpen ? "Ends in" : "Closed")
                    .font(.caption.bold())
                    .foregroundStyle(SideStageTokens.Semantic.textMuted)
                Text(isOpen ? LiveEventPresentation.formatCountdown(seconds: seconds) : "—")
                    .font(.title2.monospacedDigit().bold())
                    .foregroundStyle(
                        seconds <= 10 && isOpen
                            ? SideStageTokens.Semantic.warning
                            : SideStageTokens.Semantic.text
                    )
            }
            .accessibilityIdentifier("buyer.event.countdown")
        }
    }
}

// MARK: - Cart

private struct CartLink: View {
    let itemCount: Int

    var body: some View {
        NavigationLink(value: BuyerRoute.cart) {
            HStack {
                Label("View cart", systemImage: "cart.fill")
                Spacer()
                if itemCount > 0 {
                    Text("\(itemCount)")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SideStageTokens.Semantic.accent)
                        .foregroundStyle(SideStageTokens.Component.primaryButtonText)
                        .clipShape(Capsule())
                }
            }
            .frame(minHeight: SideStageTokens.Component.minimumTouchTarget)
        }
        .buttonStyle(.bordered)
        .tint(SideStageTokens.Semantic.accent)
        .accessibilityIdentifier("buyer.event.cart")
    }
}
