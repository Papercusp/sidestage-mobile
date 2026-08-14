// SPDX-License-Identifier: MIT

import XCTest
@testable import SideStage

/// Tests for the buyer browse + search rules that are pure enough to assert
/// without a core client or a running API.
///
/// The bar these hold: every rule here is one the *Android* buyer browse
/// surface also applies
/// (`android/app/src/main/kotlin/com/sidestage/mobile/buyer/BuyerBrowse.kt`), so
/// a divergence shows up as a red test rather than as a catalog that reads one
/// way on iPhone and another on Android. Where a case below looks arbitrary, it
/// is pinned to a specific line of the Kotlin — that is the point of it.
final class BuyerBrowsePresentationTests: XCTestCase {
    // MARK: - Price formatting (parity with Kotlin formatPriceCents)

    func testFormatsPriceCentsLikeAndroid() {
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(0), "$0.00")
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(5), "$0.05")
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(99), "$0.99")
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(100), "$1.00")
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(999), "$9.99")
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(123_456), "$1,234.56")
    }

    /// The grouping boundaries are where a hand-rolled formatter goes wrong:
    /// three digits must NOT get a separator, four must, and the separator must
    /// not reappear inside the cents.
    func testGroupsThousandsAtTheRightBoundaries() {
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(99_999), "$999.99")
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(100_000), "$1,000.00")
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(100_000_000), "$1,000,000.00")
    }

    /// A negative price is not expected from the catalog, but the Kotlin
    /// handles it by putting the sign OUTSIDE the currency symbol, and a client
    /// that renders `$-2.50` where the other renders `-$2.50` is a parity break
    /// however unlikely the input.
    func testNegativeCentsPutTheSignBeforeTheCurrencySymbol() {
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(-250), "-$2.50")
        XCTAssertEqual(BuyerBrowsePresentation.formatPriceCents(-5), "-$0.05")
    }

    // MARK: - Monogram (parity with Kotlin monogramFor)

    func testMonogramTakesTheFirstNonBlankCharacterUppercased() {
        XCTAssertEqual(BuyerBrowsePresentation.monogramFor("shoes"), "S")
        XCTAssertEqual(BuyerBrowsePresentation.monogramFor("  nike air"), "N")
        XCTAssertEqual(BuyerBrowsePresentation.monogramFor("Ω omega"), "Ω")
    }

    /// The Kotlin returns "?" rather than an empty string, so the avatar slot
    /// never collapses to zero width mid-grid.
    func testMonogramFallsBackToQuestionMarkWhenThereIsNothingToShow() {
        XCTAssertEqual(BuyerBrowsePresentation.monogramFor(""), "?")
        XCTAssertEqual(BuyerBrowsePresentation.monogramFor("   "), "?")
    }

    // MARK: - Product type labels (parity with Kotlin productTypeLabel)

    func testProductTypeLabelsMatchAndroid() {
        XCTAssertEqual(BuyerBrowsePresentation.productTypeLabel("all"), "All types")
        XCTAssertEqual(BuyerBrowsePresentation.productTypeLabel("sneaker_low"), "Sneaker low")
        XCTAssertEqual(BuyerBrowsePresentation.productTypeLabel("TRADING-CARD"), "Trading card")
        XCTAssertEqual(BuyerBrowsePresentation.productTypeLabel("vinyl"), "Vinyl")
    }

    /// Kotlin returns the raw input when splitting yields no words, rather than
    /// an empty label. Reproduced exactly: an unlabelled filter chip is worse
    /// than an ugly one.
    func testProductTypeLabelReturnsTheRawValueWhenThereAreNoWords() {
        XCTAssertEqual(BuyerBrowsePresentation.productTypeLabel(""), "")
        XCTAssertEqual(BuyerBrowsePresentation.productTypeLabel("___"), "___")
        XCTAssertEqual(BuyerBrowsePresentation.productTypeLabel("--"), "--")
    }

    // MARK: - Query normalization (parity with Kotlin toCatalogSearch)

    func testBlankSearchTextBecomesAnAbsentQueryNotAnEmptyOne() {
        XCTAssertNil(BuyerBrowseQuery(text: "").normalizedText)
        XCTAssertNil(BuyerBrowseQuery(text: "   ").normalizedText)
        XCTAssertEqual(BuyerBrowseQuery(text: "  shoes ").normalizedText, "shoes")
    }

    /// The `all` sentinel is a UI affordance. Sending it to the core would
    /// filter for a product type literally named "all" and return nothing.
    func testAllTypesSentinelIsNeverSentToTheCore() {
        XCTAssertNil(BuyerBrowseQuery(productType: BuyerBrowseDefaults.allTypes).normalizedProductType)
        XCTAssertNil(BuyerBrowseQuery(productType: "  ").normalizedProductType)
        XCTAssertEqual(BuyerBrowseQuery(productType: "vinyl").normalizedProductType, "vinyl")
    }

    func testPageAndPageSizeAreClampedToLegalValues() {
        let query = BuyerBrowseQuery(page: 0, pageSize: 0)
        XCTAssertEqual(query.clampedPage, BuyerBrowseDefaults.firstPage)
        XCTAssertEqual(query.clampedPageSize, 1)

        let negative = BuyerBrowseQuery(page: -3, pageSize: -10)
        XCTAssertEqual(negative.clampedPage, BuyerBrowseDefaults.firstPage)
        XCTAssertEqual(negative.clampedPageSize, 1)
    }

    func testResetToFirstPageKeepsEveryOtherFilter() {
        let query = BuyerBrowseQuery(
            text: "shoes",
            productType: "vinyl",
            inStockOnly: false,
            page: 4
        )
        let reset = query.resetToFirstPage()
        XCTAssertEqual(reset.page, BuyerBrowseDefaults.firstPage)
        XCTAssertEqual(reset.text, "shoes")
        XCTAssertEqual(reset.productType, "vinyl")
        XCTAssertFalse(reset.inStockOnly)
    }

    /// The default is deliberately in-stock-only, matching Android. A buyer
    /// landing on a grid full of things they cannot buy is the worse default.
    func testDefaultQueryIsInStockOnlyOnPageOne() {
        let query = BuyerBrowseQuery()
        XCTAssertTrue(query.inStockOnly)
        XCTAssertEqual(query.page, BuyerBrowseDefaults.firstPage)
        XCTAssertEqual(query.pageSize, BuyerBrowseDefaults.pageSize)
        XCTAssertEqual(query.productType, BuyerBrowseDefaults.allTypes)
    }

    // MARK: - Event ordering (parity with Kotlin sortEventsForBrowse)

    func testEventsSortLiveThenScheduledThenEnded() {
        let order = BuyerBrowsePresentation.stableSortedIndices(
            phases: [.ended, .scheduled, .live]
        )
        XCTAssertEqual(order, [2, 1, 0])
    }

    /// Kotlin's `sortedBy` is a STABLE sort, so Android preserves the core's
    /// ordering within a phase. Swift's sort is not stable, so this is the case
    /// a naive one-line port silently breaks — and nothing else would catch it,
    /// because both clients would still show "live first".
    func testEventsInTheSamePhaseKeepTheOrderTheCoreReturned() {
        let order = BuyerBrowsePresentation.stableSortedIndices(
            phases: [.live, .live, .live, .live, .live, .live, .live, .live]
        )
        XCTAssertEqual(order, [0, 1, 2, 3, 4, 5, 6, 7])

        let mixed = BuyerBrowsePresentation.stableSortedIndices(
            phases: [.scheduled, .live, .scheduled, .live, .ended, .live]
        )
        // live: 1,3,5 (in core order) — then scheduled: 0,2 — then ended: 4.
        XCTAssertEqual(mixed, [1, 3, 5, 0, 2, 4])
    }

    func testSortingAnEmptyEventListIsEmptyNotACrash() {
        XCTAssertEqual(BuyerBrowsePresentation.stableSortedIndices(phases: []), [])
    }

    // MARK: - Event filtering (parity with Kotlin filterEventsForBrowse)

    func testEmptyNeedleKeepsEveryEvent() {
        let indices = BuyerBrowsePresentation.matchingEventIndices(
            titles: ["Sneaker drop", "Vinyl night"],
            sellerNames: ["Ada", "Bo"],
            text: "   "
        )
        XCTAssertEqual(indices, [0, 1])
    }

    func testEventFilterIsCaseInsensitiveOnTitleAndSeller() {
        let titles = ["Sneaker drop", "Vinyl night", "Card break"]
        let sellers = ["Ada", "Bo", "SNEAKER Bo"]

        XCTAssertEqual(
            BuyerBrowsePresentation.matchingEventIndices(
                titles: titles, sellerNames: sellers, text: "SNEAKER"
            ),
            [0, 2],
            "the needle must match the title of 0 and the seller name of 2"
        )
        XCTAssertEqual(
            BuyerBrowsePresentation.matchingEventIndices(
                titles: titles, sellerNames: sellers, text: "bo"
            ),
            [1, 2]
        )
    }

    func testEventFilterReturnsNothingWhenNothingMatches() {
        XCTAssertEqual(
            BuyerBrowsePresentation.matchingEventIndices(
                titles: ["Sneaker drop"], sellerNames: ["Ada"], text: "zzz"
            ),
            []
        )
    }

    /// A short seller-name array must not trap. The two arrays come from the
    /// same event list today, but an index-based API that crashes on a length
    /// mismatch is a landmine for the next caller.
    func testEventFilterToleratesAShorterSellerNameArray() {
        let indices = BuyerBrowsePresentation.matchingEventIndices(
            titles: ["Sneaker drop", "Vinyl night"],
            sellerNames: ["Ada"],
            text: "vinyl"
        )
        XCTAssertEqual(indices, [1])
    }

    // MARK: - Product cards (parity with Kotlin toProductCard)

    func testProductCardJoinsBrandAndCondition() {
        let card = BuyerBrowsePresentation.productCard(
            id: "p1",
            title: "Air Max 90",
            brand: "Nike",
            condition: "Used",
            sku: "AM90-42",
            priceCents: 12_500,
            availableQty: 3
        )
        XCTAssertEqual(card.subtitle, "Nike · Used")
        XCTAssertEqual(card.priceLabel, "$125.00")
        XCTAssertEqual(card.readyLabel, "3 ready")
        XCTAssertEqual(card.monogram, "A")
        XCTAssertFalse(card.soldOut)
    }

    /// Kotlin falls back to the SKU when neither brand nor condition is
    /// present, rather than leaving the second line blank.
    func testProductCardFallsBackToTheSkuForItsSubtitle() {
        let card = BuyerBrowsePresentation.productCard(
            id: "p2",
            title: "Mystery box",
            brand: "",
            condition: nil,
            sku: "MB-001",
            priceCents: 500,
            availableQty: 1
        )
        XCTAssertEqual(card.subtitle, "MB-001")
    }

    func testProductCardUsesOnlyTheHalfThatIsPresent() {
        let brandOnly = BuyerBrowsePresentation.productCard(
            id: "p3", title: "Tee", brand: "Adidas", condition: nil,
            sku: "T-1", priceCents: 100, availableQty: 1
        )
        XCTAssertEqual(brandOnly.subtitle, "Adidas")

        let conditionOnly = BuyerBrowsePresentation.productCard(
            id: "p4", title: "Tee", brand: "", condition: "New",
            sku: "T-2", priceCents: 100, availableQty: 1
        )
        XCTAssertEqual(conditionOnly.subtitle, "New")
    }

    /// Zero AND negative both mean sold out. A negative quantity should never
    /// reach the client, but reading it as "in stock" would offer the buyer
    /// something that cannot ship.
    func testZeroOrNegativeQuantityIsSoldOut() {
        let zero = BuyerBrowsePresentation.productCard(
            id: "p5", title: "Tee", brand: "A", condition: nil,
            sku: "T-3", priceCents: 100, availableQty: 0
        )
        XCTAssertTrue(zero.soldOut)

        let negative = BuyerBrowsePresentation.productCard(
            id: "p6", title: "Tee", brand: "A", condition: nil,
            sku: "T-4", priceCents: 100, availableQty: -2
        )
        XCTAssertTrue(negative.soldOut)
    }

    func testProductCardMonogramFallsBackToTheSkuWhenTheTitleIsBlank() {
        let card = BuyerBrowsePresentation.productCard(
            id: "p7", title: "   ", brand: "A", condition: nil,
            sku: "zeta-9", priceCents: 100, availableQty: 1
        )
        XCTAssertEqual(card.monogram, "Z")
    }

    // MARK: - Paging (parity with Kotlin hasMoreAfter)

    func testAnEmptyPageNeverOffersMore() {
        XCTAssertFalse(
            BuyerBrowsePresentation.hasMoreAfter(
                page: 1, pageSize: 24, rowsInPage: 0, total: 500, totalIsFloor: false
            )
        )
        XCTAssertFalse(
            BuyerBrowsePresentation.hasMoreAfter(
                page: 1, pageSize: 24, rowsInPage: 0, total: 500, totalIsFloor: true
            )
        )
    }

    func testExactTotalComparesConsumedRowsAgainstIt() {
        // 1 * 24 = 24 < 50 — more to come.
        XCTAssertTrue(
            BuyerBrowsePresentation.hasMoreAfter(
                page: 1, pageSize: 24, rowsInPage: 24, total: 50, totalIsFloor: false
            )
        )
        // 3 * 24 = 72 >= 50 — the buyer has seen everything.
        XCTAssertFalse(
            BuyerBrowsePresentation.hasMoreAfter(
                page: 3, pageSize: 24, rowsInPage: 2, total: 50, totalIsFloor: false
            )
        )
    }

    /// When the core reports a FLOOR, the total cannot be compared against — a
    /// full page is the only evidence more may exist. Comparing against a floor
    /// would stop paging early and hide catalog the buyer can actually buy.
    func testAFloorTotalPagesOnAFullPageInstead() {
        XCTAssertTrue(
            BuyerBrowsePresentation.hasMoreAfter(
                page: 1, pageSize: 24, rowsInPage: 24, total: 24, totalIsFloor: true
            )
        )
        XCTAssertFalse(
            BuyerBrowsePresentation.hasMoreAfter(
                page: 1, pageSize: 24, rowsInPage: 23, total: 24, totalIsFloor: true
            )
        )
    }

    // MARK: - Result count copy

    /// A floor rendered as an exact count is a quiet lie that makes the catalog
    /// look smaller than it is, so the "+" is part of the contract.
    func testResultCountMarksAFloorAsAFloor() {
        XCTAssertEqual(
            BuyerBrowsePresentation.resultCountLabel(total: 240, totalIsFloor: true),
            "240+ products"
        )
        XCTAssertEqual(
            BuyerBrowsePresentation.resultCountLabel(total: 240, totalIsFloor: false),
            "240 products"
        )
    }

    func testResultCountSingularizesExactlyOne() {
        XCTAssertEqual(
            BuyerBrowsePresentation.resultCountLabel(total: 1, totalIsFloor: false),
            "1 product"
        )
        XCTAssertEqual(
            BuyerBrowsePresentation.resultCountLabel(total: 0, totalIsFloor: false),
            "0 products"
        )
    }

    // MARK: - Empty-state copy

    /// The empty state must distinguish "the catalog is empty" from "your
    /// search found nothing" — the second is recoverable by the buyer and the
    /// first is not, so telling them apart is the whole value of the message.
    func testEmptyMessagesNameTheSearchWhenThereIsOne() {
        XCTAssertEqual(
            BuyerBrowsePresentation.emptyProductsMessage(query: "  "),
            "Nothing in the catalog yet."
        )
        XCTAssertEqual(
            BuyerBrowsePresentation.emptyProductsMessage(query: " shoes "),
            "No products match “shoes”."
        )
        XCTAssertEqual(
            BuyerBrowsePresentation.emptyEventsMessage(query: ""),
            "No shows on right now."
        )
        XCTAssertEqual(
            BuyerBrowsePresentation.emptyEventsMessage(query: "vinyl"),
            "No shows match “vinyl”."
        )
    }

    func testFailureMessageFallsBackWhenThereIsNoDetail() {
        XCTAssertEqual(
            BuyerBrowsePresentation.failureMessage(detail: nil),
            "Browsing failed. Pull to try again."
        )
        XCTAssertEqual(
            BuyerBrowsePresentation.failureMessage(detail: "   "),
            "Browsing failed. Pull to try again."
        )
        XCTAssertEqual(
            BuyerBrowsePresentation.failureMessage(detail: "timeout"),
            "Browsing failed: timeout"
        )
    }

    // MARK: - Defaults

    /// Both clients must burn the same number of core round-trips for the same
    /// typing, or "parity" is only skin deep.
    func testDebounceAndPageSizeMatchAndroidsDefaults() {
        XCTAssertEqual(BuyerBrowseDefaults.debounceMillis, 250)
        XCTAssertEqual(BuyerBrowseDefaults.pageSize, 24)
        XCTAssertEqual(BuyerBrowseDefaults.firstPage, 1)
        XCTAssertEqual(BuyerBrowseDefaults.allTypes, "all")
    }
}
