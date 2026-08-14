// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import uniffi.sidestage.CatalogAvailability
import uniffi.sidestage.CatalogSearch
import uniffi.sidestage.CatalogVariant
import uniffi.sidestage.EventStatus
import uniffi.sidestage.EventSummary
import kotlin.math.abs

/**
 * Buyer-tab search + browse, kept deliberately free of Compose and of the
 * native boundary so every rule below is unit-testable off-device.
 *
 * Parity target is the web Buyer flow (`apps/web/src/catalog.ts` and
 * `apps/web/src/events/ChannelGuide.tsx`), not the Seller inventory picker —
 * Seller/History/Config/Test surfaces are out of scope per D-008.
 */
object BuyerBrowseDefaults {
    /** `useCatalog`'s debounce in apps/web/src/catalog.ts. */
    const val DEBOUNCE_MILLIS: Long = 250

    /** `useCatalog`'s default page size. */
    const val PAGE_SIZE: Int = 24

    /** The API pages from 1, and so does the web client. */
    const val FIRST_PAGE: Int = 1

    /** The web filter's "no product-type filter" sentinel. */
    const val ALL_TYPES: String = "all"
}

/**
 * One catalog request as the Buyer tab expresses it.
 *
 * `inStockOnly` defaults to true because the web Buyer product rail reads the
 * catalog with `availability: 'in-stock'` — a buyer browsing a drop is never
 * shown stock they cannot hold.
 */
data class BuyerBrowseQuery(
    val text: String = "",
    val productType: String = BuyerBrowseDefaults.ALL_TYPES,
    val inStockOnly: Boolean = true,
    val page: Int = BuyerBrowseDefaults.FIRST_PAGE,
    val pageSize: Int = BuyerBrowseDefaults.PAGE_SIZE,
)

/**
 * Build the core's catalog request.
 *
 * TYPO TOLERANCE LIVES ON THE SERVER. The API proxies `q` to Typesense, which
 * is what makes "esspreso machne" find the espresso machine. So the search text
 * is passed through VERBATIM apart from trimming the surrounding whitespace —
 * no lowercasing, no punctuation stripping, no local pre-filtering. Any client
 * normalisation here would be a silent parity break with the web buyer, whose
 * `fetchCatalog` sets `q` straight from the input.
 */
fun BuyerBrowseQuery.toCatalogSearch(): CatalogSearch =
    CatalogSearch(
        q = text.trim().ifEmpty { null },
        productType =
            productType
                .takeIf { it.isNotBlank() && it != BuyerBrowseDefaults.ALL_TYPES },
        // The core appends `availability=in-stock` only for IN_STOCK, so ALL
        // sends no parameter at all — exactly what the web client does.
        availability = if (inStockOnly) CatalogAvailability.IN_STOCK else CatalogAvailability.ALL,
        page = page.coerceAtLeast(BuyerBrowseDefaults.FIRST_PAGE).toUInt(),
        pageSize = pageSize.coerceAtLeast(1).toUInt(),
    )

/**
 * Live rooms first, then scheduled, then ended.
 *
 * `sortedBy` is stable, so events keep the API's own order inside each band —
 * the web Channel Guide renders the collection in API order and this adds only
 * the one departure a phone earns: what is live now is what you can join now.
 */
fun sortEventsForBrowse(events: List<EventSummary>): List<EventSummary> =
    events.sortedBy { event ->
        when (event.status) {
            EventStatus.LIVE -> 0
            EventStatus.SCHEDULED -> 1
            EventStatus.ENDED -> 2
        }
    }

/**
 * Narrow the event list as the buyer types.
 *
 * This is a plain case-insensitive substring match and is NOT typo-tolerant,
 * because SideStage exposes no server-side event search to be typo-tolerant
 * with — `GET /events` takes no query at all. Products get the real Typesense
 * behaviour; events get honest local filtering over an already-loaded list.
 */
fun filterEventsForBrowse(
    events: List<EventSummary>,
    text: String,
): List<EventSummary> {
    val needle = text.trim().lowercase()
    if (needle.isEmpty()) return events
    return events.filter { event ->
        event.title.lowercase().contains(needle) || event.sellerName.lowercase().contains(needle)
    }
}

/** A product row, shaped for the approved mockup's stacked catalog row. */
data class ProductCard(
    val id: String,
    val title: String,
    val subtitle: String,
    val priceLabel: String,
    val readyLabel: String,
    val soldOut: Boolean,
    val monogram: String,
)

/**
 * Mirror of the web's `variantToBuyerProduct`, stacked for a phone: thumbnail,
 * title and brand, then price with its ready-count.
 *
 * The subtitle is brand · condition. The web adds the colour axis ahead of
 * condition, but the mobile `CatalogVariant` carries no colour field, so this
 * renders what the boundary actually publishes rather than inventing an axis.
 */
fun CatalogVariant.toProductCard(): ProductCard {
    val subtitle =
        listOfNotNull(brand.takeIf { it.isNotBlank() }, condition?.takeIf { it.isNotBlank() })
            .joinToString(" · ")
            .ifEmpty { sku }
    return ProductCard(
        id = id,
        title = title,
        subtitle = subtitle,
        priceLabel = formatPriceCents(priceCents),
        readyLabel = "$availableQty ready",
        soldOut = availableQty <= 0,
        monogram = monogramFor(title.ifBlank { sku }),
    )
}

/**
 * `KITCHEN_APPLIANCE` reads as "Kitchen appliance" on a buyer-facing chip.
 *
 * The API's product types are import-time constants, so this is presentation
 * only — the unmodified value is what goes back over the wire as `type`.
 */
fun productTypeLabel(productType: String): String {
    if (productType == BuyerBrowseDefaults.ALL_TYPES) return "All types"
    val words = productType.split('_', '-').filter { it.isNotBlank() }
    if (words.isEmpty()) return productType
    return words
        .joinToString(" ") { it.lowercase() }
        .replaceFirstChar { it.uppercaseChar() }
}

/** The mockup's thumbnail letter, standing in until a product image loads. */
fun monogramFor(source: String): String =
    source
        .trim()
        .firstOrNull()
        ?.uppercaseChar()
        ?.toString() ?: "?"

/**
 * Integer-exact money formatting: "$49.99", "$6,230.57".
 *
 * Deliberately not `NumberFormat` or a double divide — prices are cents on the
 * wire and stay cents here, so no rounding or locale grouping can drift the
 * price a buyer is about to be charged.
 */
fun formatPriceCents(cents: Long): String {
    val magnitude = abs(cents)
    val grouped =
        (magnitude / 100)
            .toString()
            .reversed()
            .chunked(3)
            .joinToString(",")
            .reversed()
    val fraction = (magnitude % 100).toString().padStart(2, '0')
    return buildString {
        if (cents < 0) append('-')
        append('$')
        append(grouped)
        append('.')
        append(fraction)
    }
}

/**
 * Whether another catalog page exists.
 *
 * `totalIsFloor` means the API could only prove a lower bound on the total, so
 * a full page is itself the evidence that more rows exist — without this the
 * buyer would be told a 1.1M-row catalog had ended at row 24.
 */
fun hasMoreAfter(
    page: Int,
    pageSize: Int,
    rowsInPage: Int,
    total: Long,
    totalIsFloor: Boolean,
): Boolean {
    if (rowsInPage == 0) return false
    if (totalIsFloor) return rowsInPage >= pageSize
    return page.toLong() * pageSize.toLong() < total
}
