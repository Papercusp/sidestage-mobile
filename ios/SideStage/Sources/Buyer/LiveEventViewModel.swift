// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SideStageCore

/// Drives the buyer's live event screen from the shared Rust core.
///
/// Everything this type knows about a live room arrives through one channel:
/// `LiveEventSync`, the core's realtime feed (SSE with a REST fallback the core
/// manages on its own). The view model never polls, never reconnects, and never
/// second-guesses a status — the core owns that ladder, and a second copy here
/// would be a copy that drifts.
///
/// The other rule it holds to: **money decisions belong to the core.** The
/// pre-filled bid and the minimum the API will accept come from
/// `suggestedBidCents` / `minimumNextBidCents` across the FFI boundary, never
/// from arithmetic written here. Only display and text-field concerns are local,
/// and those live in `LiveEventPresentation`.
@MainActor
@Observable
final class LiveEventViewModel {
    // MARK: - Inputs

    let eventID: String
    private let client: SideStageClientProtocol

    // MARK: - Observable state

    /// What the connection chip renders. Starts optimistic-but-honest: the core
    /// reports `connecting` before it has an answer either way.
    private(set) var connection: LiveConnectionState = .connecting

    /// The latest whole-room state. The core sends snapshots, not deltas, so
    /// replacing this wholesale is the correct update — there is no merge to get
    /// wrong.
    private(set) var snapshot: LiveEventSnapshot?

    /// Title, thumbnail and viewer count. Fetched once; the feed does not carry
    /// it, and it does not change during a room.
    private(set) var event: EventSummary?

    /// What the buyer has typed into the bid field.
    var bidText: String = ""

    private(set) var isSubmittingBid = false

    /// A failure the buyer needs to see: a rejected bid, a lost stream. Cleared
    /// on the next attempt rather than on a timer, so it cannot vanish mid-read.
    private(set) var bidError: String?
    private(set) var streamError: String?
    /// Cart state is read straight off the shared `CartStore` rather than
    /// mirrored here. The live room, the cart screen and checkout all have to
    /// agree on one cart, and a local copy is a copy that drifts — these three
    /// stay as properties so the view reads unchanged.
    var cartError: String? { cartStore.errorMessage }

    var cartItemCount: Int { cartStore.itemCount }

    var isUpdatingCart: Bool { cartStore.isUpdating }

    // MARK: - Internals

    private var sync: LiveEventSyncProtocol?
    private var streamTask: Task<Void, Never>?

    /// The auction identity the bid field was last pre-filled for.
    ///
    /// Mirrors the web buyer panel, which re-seeds on `${id}:${currentPriceCents}`
    /// — so a price move re-fills the field, and a mere re-render does not stomp
    /// what the buyer is typing.
    private var seededBidKey: String?

    /// The cart every buyer surface shares. This used to be a bare `cartID`
    /// held by this screen, with a note that it belonged in a shared store once
    /// the cart screen became real. It did, so this is that store.
    private let cartStore: CartStore

    var cartID: String? { cartStore.cartID }

    init(eventID: String, client: SideStageClientProtocol, cartStore: CartStore) {
        self.eventID = eventID
        self.client = client
        self.cartStore = cartStore
    }

    // MARK: - Lifecycle

    /// Idempotent: a second call while the feed is running is a no-op, so an
    /// `onAppear` that fires twice cannot open two feeds against one room.
    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            await self?.loadEventSummary()
            await self?.runFeed()
        }
    }

    /// Tears the feed down. The core's sync closes its transport when the handle
    /// goes away, and dropping the task stops us consuming from a closed feed.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        sync?.stop()
        sync = nil
        connection = .connecting
    }

    private func loadEventSummary() async {
        do {
            event = try await client.event(eventId: eventID)
        } catch {
            // A missing summary costs the header its title and poster; the room
            // itself still works, so this is not worth blocking the screen on.
            event = nil
        }
    }

    private func runFeed() async {
        do {
            sync = try client.liveEventSync(eventId: eventID)
        } catch {
            connection = .connecting
            streamError = "Could not join the live room."
            return
        }
        guard let sync else { return }

        // `nextEvent()` returns nil exactly once, when the feed is finished; a
        // dropped connection surfaces as a `status` update instead, because the
        // core reconnects rather than ending.
        while let update = await sync.nextEvent() {
            if Task.isCancelled { break }
            apply(update)
        }
    }

    private func apply(_ update: LiveEventUpdate) {
        switch update {
        case let .status(status):
            connection = Self.connectionState(from: status)
            if case .live = status { streamError = nil }
        case let .snapshot(snapshot):
            self.snapshot = snapshot
            streamError = nil
            reseedBidFieldIfNeeded()
        case let .error(message):
            streamError = message
        }
    }

    /// Maps the core's transport status onto what the buyer is told.
    ///
    /// `polling` is the core's REST fallback — still delivering, just slower —
    /// so it reads as reconnecting rather than as an error. The retry is
    /// reported in whole seconds, rounded UP, so a sub-second retry never
    /// renders as the misleading "0s".
    nonisolated static func connectionState(from status: LiveSyncStatus) -> LiveConnectionState {
        switch status {
        case .connecting: .connecting
        case .live: .live
        case let .polling(retryInMs):
            .reconnecting(retryInSeconds: Int((retryInMs + 999) / 1000))
        }
    }

    // MARK: - Bidding

    var auction: LiveAuction? { snapshot?.auction }

    /// The highest bid. The API returns `bids` sorted by amount descending, and
    /// the core deliberately does not re-sort — taking the first entry keeps
    /// every surface agreeing about who is leading.
    var leadingBid: AuctionBid? { auction?.bids.first }

    /// Whether a bid can go through right now, and if not, why.
    ///
    /// The minimum comes from the core (`minimumNextBidCents`), which mirrors
    /// what `AuctionService::placeBid` enforces — so the button is disabled for
    /// exactly the amounts the server would reject with a 409.
    var bidAvailability: BidAvailability {
        if isSubmittingBid { return .submitting }
        guard let auction else { return .noAuction }
        guard case .active = auction.status else { return .auctionClosed }
        guard client.session() != nil else { return .signedOut }
        guard let cents = LiveEventPresentation.parseBidDollars(bidText) else {
            return .amountNotANumber
        }
        let minimum = minimumNextBidCents(currentPriceCents: auction.currentPriceCents)
        guard cents >= minimum else { return .belowMinimum(minimumCents: minimum) }
        return .ready(amountCents: cents)
    }

    func placeBid() async {
        guard case let .ready(amountCents) = bidAvailability,
              let auction,
              let session = client.session()
        else { return }

        bidError = nil
        isSubmittingBid = true
        defer { isSubmittingBid = false }

        do {
            let updated = try await client.placeBid(
                input: PlaceBidRequest(
                    auctionId: auction.id,
                    bidderId: session.buyerId,
                    displayName: nil,
                    amountCents: amountCents
                )
            )
            // The feed will deliver this same auction moments from now; applying
            // the response immediately means the buyer sees their own bid land
            // without waiting on a round trip they already paid for.
            applyLocally(auction: updated)
        } catch let error as ApiError {
            bidError = Self.bidErrorMessage(for: error)
        } catch {
            bidError = "Could not place your bid. Try again."
        }
    }

    /// Turns a transport-level failure into something a buyer can act on.
    ///
    /// 409 is the one that matters: `AuctionService::placeBid` returns it when
    /// the amount no longer clears the current price — which in a live room
    /// almost always means somebody else got there first.
    nonisolated static func bidErrorMessage(for error: ApiError) -> String {
        switch error {
        case let .Http(status, _) where status == 409:
            "Someone outbid you — the price just moved."
        case let .Http(status, _) where status == 401 || status == 403:
            "Sign in again to bid."
        case .Transport:
            "You're offline. Your bid was not placed."
        default:
            "Could not place your bid. Try again."
        }
    }

    private func applyLocally(auction: LiveAuction) {
        guard var snapshot else { return }
        snapshot.auction = auction
        self.snapshot = snapshot
        reseedBidFieldIfNeeded()
    }

    private func reseedBidFieldIfNeeded() {
        guard let auction else {
            seededBidKey = nil
            return
        }
        let key = "\(auction.id):\(auction.currentPriceCents)"
        guard key != seededBidKey else { return }
        seededBidKey = key
        bidText = LiveEventPresentation.bidFieldText(
            cents: suggestedBidCents(currentPriceCents: auction.currentPriceCents)
        )
    }

    // MARK: - Cart

    var onDeckProduct: CatalogVariant? { snapshot?.onDeckProduct }

    /// Adds the on-deck item and stays on the stream — the buyer is watching a
    /// live room, so the default action must not navigate away from it.
    @discardableResult
    func addOnDeckToCart() async -> Bool {
        guard let product = onDeckProduct else { return false }
        return await cartStore.add(
            productID: product.id,
            title: product.title,
            priceCents: product.priceCents,
            quantity: 1,
            imageURL: product.imageUrl,
            fromEvent: eventID
        )
    }

    /// Buy now is add-to-cart plus a hand-off to checkout — one intent, so a
    /// failed add must not navigate. The caller supplies the navigation because
    /// the route belongs to the stack, not to this screen.
    func buyOnDeckNow(then navigate: (BuyerRoute) -> Void) async {
        guard await addOnDeckToCart() else { return }
        navigate(.checkout(eventID: eventID))
    }
}
