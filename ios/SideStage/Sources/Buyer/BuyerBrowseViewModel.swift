// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SideStageCore

/// Drives the buyer browse + search surface: talks to the shared core, holds
/// the result state, and leaves every formatting and ordering decision to
/// `BuyerBrowsePresentation` so those rules stay testable without the FFI.
///
/// Search runs against the core's `catalog(search:)`, which owns the
/// typo-tolerant match. Nothing here re-implements fuzzy matching — parity with
/// Android comes from both clients sending the same normalized query, not from
/// two hand-written matchers agreeing by luck.
@MainActor
@Observable
final class BuyerBrowseViewModel {
    private let client: SideStageClientProtocol

    /// What the buyer is asking for. Mutating `query` does NOT fetch — call one
    /// of the intent methods, so a redundant fetch can never be triggered by an
    /// incidental write from the view layer.
    private(set) var query = BuyerBrowseQuery()

    private(set) var events: [EventSummary] = []
    private(set) var products: [ProductCard] = []
    private(set) var productTypes: [String] = [BuyerBrowseDefaults.allTypes]
    private(set) var total: UInt64 = 0
    private(set) var totalIsFloor = false
    private(set) var hasMore = false

    private(set) var loadingEvents = false
    private(set) var loadingProducts = false
    private(set) var loadingMore = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    /// Bumped on every new search intent. An in-flight response whose token is
    /// stale is DISCARDED rather than applied: without this, a slow reply to
    /// "sho" can land after a fast reply to "shoes" and leave the buyer looking
    /// at results for a query they have finished typing past.
    private var searchToken = 0
    private var debounceTask: Task<Void, Never>?

    init(client: SideStageClientProtocol) {
        self.client = client
    }

    // NO deinit CANCELLING `debounceTask` — do not "helpfully" add one back.
    //
    // `deinit` is ALWAYS nonisolated, even on a @MainActor type, so touching a
    // main-actor-isolated stored property from it is a hard compile error
    // ("main actor-isolated property 'debounceTask' can not be referenced from
    // a nonisolated context"), not a warning. There is no spelling of that
    // cancel which compiles and is also correct.
    //
    // Nothing is leaked by its absence. The debounce task captures `[weak self]`
    // and its only effect is `await self?.loadProducts(...)`, so once this model
    // deallocates the task wakes, finds `self` nil, and returns — it holds no
    // strong reference back, so it cannot keep the model alive. Worst case is one
    // idle sleep of `debounceMillis`. A late reply is separately harmless anyway:
    // `searchToken` discards any response whose token is stale.

    // MARK: - Derived state

    /// Events in browse order, narrowed by the current search text.
    ///
    /// The text filter is applied to the already-fetched event list rather than
    /// sent to the core: the core's search covers the product catalog, not the
    /// event feed, so asking it would return products for a shows query.
    var visibleEvents: [EventSummary] {
        let matching = BuyerBrowsePresentation.matchingEventIndices(
            titles: events.map(\.title),
            sellerNames: events.map(\.sellerName),
            text: query.text
        )
        let matched = matching.map { events[$0] }
        let order = BuyerBrowsePresentation.stableSortedIndices(
            phases: matched.map { Self.phase($0.status) }
        )
        return order.map { matched[$0] }
    }

    var isEmptyProducts: Bool {
        hasLoaded && products.isEmpty && !loadingProducts && errorMessage == nil
    }

    var isEmptyEvents: Bool {
        hasLoaded && visibleEvents.isEmpty && !loadingEvents && errorMessage == nil
    }

    var resultCountLabel: String {
        BuyerBrowsePresentation.resultCountLabel(total: total, totalIsFloor: totalIsFloor)
    }

    // MARK: - Intent

    func loadIfNeeded() async {
        guard !hasLoaded, !loadingProducts, !loadingEvents else { return }
        await refresh()
    }

    /// Full reload: events, the product-type filter options, and page 1.
    func refresh() async {
        query = query.resetToFirstPage()
        searchToken += 1
        let token = searchToken
        async let eventsDone: Void = loadEvents()
        async let typesDone: Void = loadProductTypes()
        async let productsDone: Void = loadProducts(token: token, append: false)
        _ = await (eventsDone, typesDone, productsDone)
        hasLoaded = true
    }

    /// The buyer typed. Debounced — one core round-trip per pause, not per
    /// keystroke, at the same interval Android uses.
    func setSearchText(_ text: String) {
        query.text = text
        query = query.resetToFirstPage()
        searchToken += 1
        let token = searchToken
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: BuyerBrowseDefaults.debounceMillis * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadProducts(token: token, append: false)
        }
    }

    /// A filter changed. Not debounced: a tap is a finished intent, so making
    /// the buyer wait out a keystroke delay would only feel broken.
    func setProductType(_ productType: String) async {
        guard productType != query.productType else { return }
        query.productType = productType
        query = query.resetToFirstPage()
        searchToken += 1
        await loadProducts(token: searchToken, append: false)
    }

    func setInStockOnly(_ inStockOnly: Bool) async {
        guard inStockOnly != query.inStockOnly else { return }
        query.inStockOnly = inStockOnly
        query = query.resetToFirstPage()
        searchToken += 1
        await loadProducts(token: searchToken, append: false)
    }

    /// Append the next page. A no-op unless the last page said there is more,
    /// so a doubled tap cannot skip a page.
    func loadMore() async {
        guard hasMore, !loadingMore, !loadingProducts else { return }
        query.page = query.clampedPage + 1
        await loadProducts(token: searchToken, append: true)
    }

    // MARK: - Core calls

    private func loadEvents() async {
        loadingEvents = true
        defer { loadingEvents = false }
        do {
            events = try await client.events()
        } catch {
            errorMessage = Self.message(for: error)
            // `events` is left alone: a failed refresh must not blank a list the
            // buyer is already reading.
        }
    }

    private func loadProductTypes() async {
        do {
            let loaded = try await client.productTypes()
            productTypes = [BuyerBrowseDefaults.allTypes] + loaded
        } catch {
            // A missing filter list degrades the surface but does not break it,
            // so this failure deliberately does NOT set errorMessage — the
            // buyer can still search, and claiming browse is broken would be
            // false.
            productTypes = [BuyerBrowseDefaults.allTypes]
        }
    }

    private func loadProducts(token: Int, append: Bool) async {
        if append { loadingMore = true } else { loadingProducts = true }
        defer {
            if append { loadingMore = false } else { loadingProducts = false }
        }
        if !append { errorMessage = nil }

        let search = CatalogSearch(
            q: query.normalizedText,
            productType: query.normalizedProductType,
            availability: query.inStockOnly ? .inStock : .all,
            page: UInt32(query.clampedPage),
            pageSize: UInt32(query.clampedPageSize)
        )

        do {
            let page = try await client.catalog(search: search)
            // Stale-response guard: the buyer has typed since this went out.
            guard token == searchToken else { return }
            let cards = page.rows.map(Self.card(for:))
            products = append ? products + cards : cards
            total = page.total
            totalIsFloor = page.totalIsFloor
            hasMore = BuyerBrowsePresentation.hasMoreAfter(
                page: Int(page.page),
                pageSize: Int(page.pageSize),
                rowsInPage: page.rows.count,
                total: page.total,
                totalIsFloor: page.totalIsFloor
            )
            hasLoaded = true
        } catch {
            guard token == searchToken else { return }
            errorMessage = Self.message(for: error)
            if append {
                // Put the page number back so a retry does not silently skip
                // the page that just failed.
                query.page = max(query.clampedPage - 1, BuyerBrowseDefaults.firstPage)
            }
        }
    }

    // MARK: - Pure adapters

    nonisolated static func phase(_ status: EventStatus) -> BuyerBrowseEventPhase {
        switch status {
        case .live: return .live
        case .scheduled: return .scheduled
        case .ended: return .ended
        }
    }

    nonisolated static func card(for variant: CatalogVariant) -> ProductCard {
        BuyerBrowsePresentation.productCard(
            id: variant.id,
            title: variant.title,
            brand: variant.brand,
            condition: variant.condition,
            sku: variant.sku,
            priceCents: variant.priceCents,
            availableQty: variant.availableQty
        )
    }

    /// Failure mapping for the browse reads.
    ///
    /// Nothing here charges the buyer, so the offline case says so plainly
    /// rather than implying anything was lost.
    nonisolated static func message(for error: Error) -> String {
        guard let apiError = error as? ApiError else {
            return BuyerBrowsePresentation.failureMessage(detail: nil)
        }
        switch apiError {
        case .Transport:
            return "You're offline. Browsing will work when you reconnect."
        case let .Http(status, _) where status >= 500:
            return "SideStage is having trouble. Try again in a moment."
        default:
            return BuyerBrowsePresentation.failureMessage(detail: nil)
        }
    }
}
