// SPDX-License-Identifier: MIT

import Foundation

/// Every rule the buyer browse + search surface decides with.
///
/// Pure and FFI-free on purpose — it takes scalars and returns scalars, so the
/// whole rule set typechecks and tests without the generated `SideStageCore`
/// module. `BuyerBrowseViewModel` does the talking to the core; this file does
/// the deciding.
///
/// **These rules are a deliberate PORT of the Android contract** in
/// `android/app/src/main/kotlin/com/sidestage/mobile/buyer/BuyerBrowse.kt`, so a
/// search reads identically on both clients (P-006 "typo-tolerant search
/// parity"). Where a Kotlin idiom has no Swift equivalent the divergence is
/// stated at the rule rather than papered over — see `stableSortedIndices`.
///
/// Typo tolerance itself is NOT implemented here and must not be: the `q` term
/// goes to the shared Rust core, which owns the fuzzy match. Both clients get
/// the same tolerance because neither client implements it. What parity means
/// on this side is that both clients send the SAME normalized query and render
/// the SAME result set the same way.
enum BuyerBrowseDefaults {
    /// Milliseconds to wait after the last keystroke before querying the core.
    /// Mirrors Android's `DEBOUNCE_MILLIS`; both clients must burn the same
    /// number of round-trips for the same typing, or "parity" is only visual.
    static let debounceMillis: UInt64 = 250

    static let pageSize: Int = 24

    static let firstPage: Int = 1

    /// Sentinel product type meaning "do not filter". Sent as `nil` to the core.
    static let allTypes: String = "all"
}

/// The buyer's current browse intent. Plain values — no FFI types — so it can
/// be constructed and asserted on anywhere.
struct BuyerBrowseQuery: Equatable {
    var text: String
    var productType: String
    var inStockOnly: Bool
    var page: Int
    var pageSize: Int

    init(
        text: String = "",
        productType: String = BuyerBrowseDefaults.allTypes,
        inStockOnly: Bool = true,
        page: Int = BuyerBrowseDefaults.firstPage,
        pageSize: Int = BuyerBrowseDefaults.pageSize
    ) {
        self.text = text
        self.productType = productType
        self.inStockOnly = inStockOnly
        self.page = page
        self.pageSize = pageSize
    }

    /// The search term as the core should receive it: trimmed, and absent
    /// rather than empty. An empty-string `q` and a missing `q` are different
    /// requests to the core, so the distinction is preserved deliberately.
    var normalizedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `nil` when the buyer has not narrowed by type — the `all` sentinel is a
    /// UI affordance and is never sent to the core.
    var normalizedProductType: String? {
        let trimmed = productType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != BuyerBrowseDefaults.allTypes else { return nil }
        return productType
    }

    var clampedPage: Int { max(page, BuyerBrowseDefaults.firstPage) }

    var clampedPageSize: Int { max(pageSize, 1) }

    /// The same query pointed at page 1. Every filter change resets paging —
    /// keeping the old page number would silently show the buyer page 3 of a
    /// result set they have never seen page 1 of.
    func resetToFirstPage() -> BuyerBrowseQuery {
        var copy = self
        copy.page = BuyerBrowseDefaults.firstPage
        return copy
    }
}

/// Where an event sorts in the browse list. Mirrors the core's `EventStatus`
/// without importing it, so the ordering rule stays FFI-free.
enum BuyerBrowseEventPhase: Int, Equatable {
    case live = 0
    case scheduled = 1
    case ended = 2
}

/// One product as the grid renders it — every string already decided.
struct ProductCard: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let priceLabel: String
    let readyLabel: String
    let soldOut: Bool
    let monogram: String
}

enum BuyerBrowsePresentation {
    // MARK: - Events

    /// Indices of `phases` in browse order: live first, then scheduled, then
    /// ended, and within a phase the order the core returned.
    ///
    /// DIVERGENCE, deliberate: Kotlin's `sortedBy` is a documented STABLE sort,
    /// so Android gets the core's ordering preserved inside each phase for
    /// free. Swift's `sort(by:)` is explicitly NOT guaranteed stable, so the
    /// same one-line port would give the two clients different orderings for
    /// the same payload whenever two events share a phase — a parity break that
    /// no compiler or typecheck would catch. The original index is therefore
    /// carried as an explicit tiebreak.
    static func stableSortedIndices(phases: [BuyerBrowseEventPhase]) -> [Int] {
        phases.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.rawValue != rhs.element.rawValue {
                    return lhs.element.rawValue < rhs.element.rawValue
                }
                return lhs.offset < rhs.offset
            }
            .map(\.offset)
    }

    /// Indices of the events whose title or seller name contains `text`.
    ///
    /// Client-side and case-insensitive, matching Android. This filter is a
    /// convenience over the already-fetched event list, NOT the product search
    /// — the core never sees it, so it is a plain substring match with no typo
    /// tolerance. An empty needle keeps everything.
    static func matchingEventIndices(
        titles: [String],
        sellerNames: [String],
        text: String
    ) -> [Int] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(titles.indices) }
        return titles.indices.filter { index in
            let title = titles[index].lowercased()
            let seller = index < sellerNames.count ? sellerNames[index].lowercased() : ""
            return title.contains(needle) || seller.contains(needle)
        }
    }

    // MARK: - Products

    static func productCard(
        id: String,
        title: String,
        brand: String,
        condition: String?,
        sku: String,
        priceCents: Int64,
        availableQty: Int64
    ) -> ProductCard {
        let parts = [brand, condition ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Falling back to the SKU keeps the card's second line from collapsing
        // when a variant carries neither brand nor condition.
        let subtitle = parts.isEmpty ? sku : parts.joined(separator: " · ")
        let monogramSource = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sku : title
        return ProductCard(
            id: id,
            title: title,
            subtitle: subtitle,
            priceLabel: formatPriceCents(priceCents),
            readyLabel: "\(availableQty) ready",
            soldOut: availableQty <= 0,
            monogram: monogramFor(monogramSource)
        )
    }

    static func productTypeLabel(_ productType: String) -> String {
        if productType == BuyerBrowseDefaults.allTypes { return "All types" }
        let words = productType
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return productType }
        let joined = words.map { $0.lowercased() }.joined(separator: " ")
        guard let first = joined.first else { return joined }
        return first.uppercased() + joined.dropFirst()
    }

    static func monogramFor(_ source: String) -> String {
        guard let first = source.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "?"
        }
        return first.uppercased()
    }

    /// Cents to a display price. Hand-rolled rather than `NumberFormatter` on
    /// purpose: Android formats this by hand too, and a locale-aware formatter
    /// would render the same order differently on two devices in the same room.
    static func formatPriceCents(_ cents: Int64) -> String {
        let magnitude = cents.magnitude
        let dollars = String(magnitude / 100)
        let grouped = groupThousands(dollars)
        let fraction = String(format: "%02d", magnitude % 100)
        return (cents < 0 ? "-" : "") + "$" + grouped + "." + fraction
    }

    private static func groupThousands(_ digits: String) -> String {
        var out: [Character] = []
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return String(out.reversed())
    }

    // MARK: - Paging

    /// Whether a "load more" affordance should be offered after this page.
    ///
    /// `totalIsFloor` means the core reported a LOWER BOUND, not a count — the
    /// total cannot be compared against, so a full page is the only evidence
    /// that more may exist.
    static func hasMoreAfter(
        page: Int,
        pageSize: Int,
        rowsInPage: Int,
        total: UInt64,
        totalIsFloor: Bool
    ) -> Bool {
        if rowsInPage == 0 { return false }
        if totalIsFloor { return rowsInPage >= pageSize }
        return UInt64(max(page, 0)) * UInt64(max(pageSize, 0)) < total
    }

    // MARK: - Copy

    static let title = "Browse"

    static let searchPrompt = "Search products and shows"

    static let eventsSectionTitle = "Live now"

    static let productsSectionTitle = "Products"

    static let loadingMessage = "Finding what's on…"

    static let loadMoreLabel = "Load more"

    static let soldOutLabel = "Sold out"

    static let coreUnavailableTitle = "Browse unavailable"

    static let coreUnavailableMessage =
        "The SideStage core isn't reachable, so browsing is off until it is back."

    static func emptyProductsMessage(query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Nothing in the catalog yet." }
        return "No products match “\(trimmed)”."
    }

    static func emptyEventsMessage(query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No shows on right now." }
        return "No shows match “\(trimmed)”."
    }

    static func failureMessage(detail: String?) -> String {
        guard let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Browsing failed. Pull to try again."
        }
        return "Browsing failed: \(detail)"
    }

    /// The result count line. `totalIsFloor` is surfaced rather than hidden —
    /// rendering a floor as an exact count is the kind of quiet lie that makes
    /// a buyer think the catalog is smaller than it is.
    static func resultCountLabel(total: UInt64, totalIsFloor: Bool) -> String {
        let noun = total == 1 ? "product" : "products"
        return totalIsFloor ? "\(total)+ \(noun)" : "\(total) \(noun)"
    }
}
