// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.sidestage.CatalogAvailability
import uniffi.sidestage.CatalogPage
import uniffi.sidestage.CatalogSearch
import uniffi.sidestage.CatalogVariant
import uniffi.sidestage.EventStatus
import uniffi.sidestage.EventSummary

private fun event(
    id: String,
    title: String = id,
    status: EventStatus = EventStatus.SCHEDULED,
    sellerName: String = "Field Office",
): EventSummary =
    EventSummary(
        eventId = id,
        title = title,
        sellerId = "seller-1",
        sellerName = sellerName,
        status = status,
        startsAt = null,
        endedAt = null,
        thumbnailUrl = null,
        viewers = 3uL,
    )

private fun variant(
    id: String = "demo-espresso-matte-black",
    title: String = "Barista Pro Espresso Machine",
    brand: String = "BrewHaus",
    condition: String? = "NEW",
    priceCents: Long = 49999,
    availableQty: Long = 12,
    sku: String = "BH-ESP-200-BLK",
): CatalogVariant =
    CatalogVariant(
        id = id,
        groupId = null,
        title = title,
        brand = brand,
        productType = "KITCHEN_APPLIANCE",
        sku = sku,
        condition = condition,
        handlingDays = 2,
        priceCents = priceCents,
        availableQty = availableQty,
        imageUrl = null,
        description = null,
    )

private class FakeCatalogSource(
    var events: List<EventSummary> = emptyList(),
    var rows: List<CatalogVariant> = emptyList(),
    var total: ULong = 0uL,
    var totalIsFloor: Boolean = false,
    var types: List<String> = emptyList(),
) : BuyerCatalogSource {
    val catalogCalls = mutableListOf<CatalogSearch>()
    var eventCalls = 0
    var eventsFailure: Exception? = null
    var catalogFailure: Exception? = null
    var eventsFailuresRemaining = 0
    var catalogFailuresRemaining = 0

    override suspend fun events(): List<EventSummary> {
        eventCalls += 1
        if (eventsFailuresRemaining > 0) {
            eventsFailuresRemaining -= 1
            throw IllegalStateException("events temporarily unreachable")
        }
        eventsFailure?.let { throw it }
        return events
    }

    override suspend fun catalog(search: CatalogSearch): CatalogPage {
        catalogCalls += search
        if (catalogFailuresRemaining > 0) {
            catalogFailuresRemaining -= 1
            throw IllegalStateException("catalog temporarily unreachable")
        }
        catalogFailure?.let { throw it }
        return CatalogPage(
            rows = rows,
            page = search.page ?: 1u,
            pageSize = search.pageSize ?: 24u,
            total = total,
            totalIsFloor = totalIsFloor,
        )
    }

    override suspend fun productTypes(): List<String> = types
}

class BuyerBrowseQueryTest {
    @Test
    fun `search text reaches the API verbatim so Typesense can do the typo tolerance`() {
        // The whole point of the API-proxied search: a misspelling must survive
        // the client untouched. Any lowercasing or stripping here would defeat
        // the server-side matching the web buyer relies on.
        val search = BuyerBrowseQuery(text = "  Esspreso Machne  ").toCatalogSearch()

        assertEquals("Esspreso Machne", search.q)
    }

    @Test
    fun `an empty search sends no q at all`() {
        assertNull(BuyerBrowseQuery(text = "   ").toCatalogSearch().q)
    }

    @Test
    fun `the all-types sentinel is a filter absence, not a filter value`() {
        assertNull(BuyerBrowseQuery(productType = BuyerBrowseDefaults.ALL_TYPES).toCatalogSearch().productType)
        assertEquals(
            "KITCHEN_APPLIANCE",
            BuyerBrowseQuery(productType = "KITCHEN_APPLIANCE").toCatalogSearch().productType,
        )
    }

    @Test
    fun `in-stock parity with the web buyer rail`() {
        assertEquals(
            CatalogAvailability.IN_STOCK,
            BuyerBrowseQuery(inStockOnly = true).toCatalogSearch().availability,
        )
        assertEquals(
            CatalogAvailability.ALL,
            BuyerBrowseQuery(inStockOnly = false).toCatalogSearch().availability,
        )
    }

    @Test
    fun `paging defaults match the web catalog client`() {
        val search = BuyerBrowseQuery().toCatalogSearch()

        assertEquals(1u, search.page)
        assertEquals(24u, search.pageSize)
        assertEquals(250L, BuyerBrowseDefaults.DEBOUNCE_MILLIS)
    }

    @Test
    fun `a nonsense page never becomes a negative unsigned request`() {
        val search = BuyerBrowseQuery(page = 0, pageSize = 0).toCatalogSearch()

        assertEquals(1u, search.page)
        assertEquals(1u, search.pageSize)
    }
}

class BuyerBrowsePresentationTest {
    @Test
    fun `live rooms sort first and keep API order inside each band`() {
        val sorted =
            sortEventsForBrowse(
                listOf(
                    event("ended-1", status = EventStatus.ENDED),
                    event("sched-1"),
                    event("live-1", status = EventStatus.LIVE),
                    event("sched-2"),
                    event("live-2", status = EventStatus.LIVE),
                ),
            )

        assertEquals(
            listOf("live-1", "live-2", "sched-1", "sched-2", "ended-1"),
            sorted.map { it.eventId },
        )
    }

    @Test
    fun `event filtering matches title or seller, case-insensitively`() {
        val events =
            listOf(
                event("a", title = "Sunday vintage drop", sellerName = "Field Office"),
                event("b", title = "Camera clearance", sellerName = "FrameForge"),
            )

        assertEquals(listOf("a"), filterEventsForBrowse(events, "VINTAGE").map { it.eventId })
        assertEquals(listOf("b"), filterEventsForBrowse(events, "frameforge").map { it.eventId })
        assertEquals(2, filterEventsForBrowse(events, "   ").size)
        assertTrue(filterEventsForBrowse(events, "nothing here").isEmpty())
    }

    @Test
    fun `a product row carries brand, condition, price and its ready count`() {
        val card = variant().toProductCard()

        assertEquals("Barista Pro Espresso Machine", card.title)
        assertEquals("BrewHaus · NEW", card.subtitle)
        assertEquals("$499.99", card.priceLabel)
        assertEquals("12 ready", card.readyLabel)
        assertEquals("B", card.monogram)
        assertFalse(card.soldOut)
    }

    @Test
    fun `an unbranded row falls back to its SKU rather than an empty subtitle`() {
        val card = variant(brand = "", condition = null, sku = "FO-LIFT-OAK").toProductCard()

        assertEquals("FO-LIFT-OAK", card.subtitle)
    }

    @Test
    fun `no stock reads as sold out`() {
        assertTrue(variant(availableQty = 0).toProductCard().soldOut)
    }

    @Test
    fun `money is formatted from cents with no floating point in the path`() {
        assertEquals("$49.99", formatPriceCents(4999))
        assertEquals("$6,230.57", formatPriceCents(623057))
        assertEquals("$0.00", formatPriceCents(0))
        assertEquals("$0.05", formatPriceCents(5))
        assertEquals("$1,000,000.00", formatPriceCents(100_000_000))
        assertEquals("-$12.34", formatPriceCents(-1234))
    }

    @Test
    fun `product type chips read as prose without changing the wire value`() {
        assertEquals("All types", productTypeLabel(BuyerBrowseDefaults.ALL_TYPES))
        assertEquals("Kitchen appliance", productTypeLabel("KITCHEN_APPLIANCE"))
        assertEquals("Audio", productTypeLabel("AUDIO"))
    }

    @Test
    fun `a floor total treats a full page as proof that more rows exist`() {
        // Without this the buyer is told a 1.1M-row catalog ended at row 24.
        assertTrue(hasMoreAfter(page = 1, pageSize = 24, rowsInPage = 24, total = 24, totalIsFloor = true))
        assertFalse(hasMoreAfter(page = 1, pageSize = 24, rowsInPage = 9, total = 9, totalIsFloor = true))
    }

    @Test
    fun `an exact total pages by arithmetic`() {
        assertTrue(hasMoreAfter(page = 1, pageSize = 24, rowsInPage = 24, total = 50, totalIsFloor = false))
        assertFalse(hasMoreAfter(page = 2, pageSize = 24, rowsInPage = 24, total = 48, totalIsFloor = false))
        assertFalse(hasMoreAfter(page = 1, pageSize = 24, rowsInPage = 0, total = 0, totalIsFloor = false))
    }
}

class BuyerBrowseStateHolderTest {
    @Test
    fun `initial load recovers when the API restarts under it`() =
        runBlocking {
            val source =
                FakeCatalogSource(
                    events = listOf(event("live", status = EventStatus.LIVE)),
                    rows = listOf(variant()),
                    total = 1uL,
                ).apply {
                    eventsFailuresRemaining = 1
                    catalogFailuresRemaining = 1
                }
            val holder =
                BuyerBrowseStateHolder(
                    source = source,
                    scope = this,
                    initialRetryDelaysMillis = listOf(0L),
                )

            holder.start()
            delay(50)

            assertEquals(2, source.eventCalls)
            assertEquals(2, source.catalogCalls.size)
            assertNull(holder.state.value.eventsError)
            assertNull(holder.state.value.productsError)
            assertEquals(listOf("live"), holder.state.value.events.map { it.eventId })
            assertEquals(listOf("Barista Pro Espresso Machine"), holder.state.value.products.map { it.title })
        }

    @Test
    fun `the first load fills rooms, catalog and the type filter`() =
        runBlocking {
            val source =
                FakeCatalogSource(
                    events = listOf(event("sched"), event("live", status = EventStatus.LIVE)),
                    rows = listOf(variant()),
                    total = 1uL,
                    types = listOf("KITCHEN_APPLIANCE", "AUDIO"),
                )
            val holder = BuyerBrowseStateHolder(source, this)

            holder.loadEvents()
            holder.loadProductTypes()
            holder.loadProducts(page = 1, append = false)
            val state = holder.state.value

            assertEquals(listOf("live", "sched"), state.events.map { it.eventId })
            assertEquals(listOf("Barista Pro Espresso Machine"), state.products.map { it.title })
            assertEquals(listOf("all", "KITCHEN_APPLIANCE", "AUDIO"), state.productTypes)
            assertFalse(state.loadingProducts)
        }

    @Test
    fun `typing debounces into a single catalog read that carries the final text`() =
        runBlocking {
            val source = FakeCatalogSource(rows = listOf(variant()), total = 1uL)
            val holder = BuyerBrowseStateHolder(source, this, debounceMillis = 20)

            holder.onSearchTextChanged("e")
            holder.onSearchTextChanged("es")
            holder.onSearchTextChanged("esspreso machne")
            delay(200)

            assertEquals(1, source.catalogCalls.size)
            assertEquals("esspreso machne", source.catalogCalls.single().q)
        }

    @Test
    fun `a new search restarts at page one`() =
        runBlocking {
            val source = FakeCatalogSource(rows = List(24) { variant(id = "v$it") }, total = 100uL)
            val holder = BuyerBrowseStateHolder(source, this, debounceMillis = 0)

            holder.loadProducts(page = 1, append = false)
            holder.loadProducts(page = 2, append = true)
            assertEquals(2, holder.state.value.query.page)

            holder.onSearchTextChanged("desk")
            delay(120)

            assertEquals(1, holder.state.value.query.page)
            assertEquals(1u, source.catalogCalls.last().page)
        }

    @Test
    fun `load more appends the next page instead of replacing the list`() =
        runBlocking {
            val source = FakeCatalogSource(rows = listOf(variant(id = "a")), total = 4uL)
            val holder = BuyerBrowseStateHolder(source, this)

            holder.loadProducts(page = 1, append = false)
            source.rows = listOf(variant(id = "b"))
            holder.loadProducts(page = 2, append = true)

            assertEquals(
                listOf("a", "b"),
                holder.state.value.products
                    .map { it.id },
            )
            assertEquals(2, holder.state.value.query.page)
        }

    @Test
    fun `a failed load-more keeps the rows on screen and rewinds the cursor`() =
        runBlocking {
            // Advancing the cursor past a page that never arrived would skip it
            // permanently — the buyer would lose 24 products to one timeout.
            val source = FakeCatalogSource(rows = listOf(variant(id = "a")), total = 4uL)
            val holder = BuyerBrowseStateHolder(source, this)

            holder.loadProducts(page = 1, append = false)
            source.catalogFailure = IllegalStateException("connection reset")
            holder.loadProducts(page = 2, append = true)
            val state = holder.state.value

            assertEquals(listOf("a"), state.products.map { it.id })
            assertEquals(1, state.query.page)
            assertEquals("connection reset", state.productsError)
            assertFalse(state.loadingMore)
        }

    @Test
    fun `an event failure is reported and cleared by a retry`() =
        runBlocking {
            val source = FakeCatalogSource()
            source.eventsFailure = IllegalStateException("events unreachable")
            val holder = BuyerBrowseStateHolder(source, this)

            holder.loadEvents()
            assertEquals("events unreachable", holder.state.value.eventsError)

            source.eventsFailure = null
            source.events = listOf(event("live", status = EventStatus.LIVE))
            holder.loadEvents()

            assertNull(holder.state.value.eventsError)
            assertEquals(
                listOf("live"),
                holder.state.value.events
                    .map { it.eventId },
            )
        }

    @Test
    fun `visible rooms narrow as the buyer types, before the catalog read fires`() =
        runBlocking {
            val source =
                FakeCatalogSource(
                    events =
                        listOf(
                            event("a", title = "Sunday vintage drop"),
                            event("b", title = "Camera clearance"),
                        ),
                )
            val holder = BuyerBrowseStateHolder(source, this, debounceMillis = 5_000)

            holder.loadEvents()
            holder.onSearchTextChanged("vintage")

            // Local filtering is immediate; only the network read waits.
            assertEquals(
                listOf("a"),
                holder.state.value.visibleEvents
                    .map { it.eventId },
            )
            assertTrue(source.catalogCalls.isEmpty())

            // Drop the still-pending debounce rather than waiting out its five
            // seconds — the point of this test is that it had not fired yet.
            coroutineContext.cancelChildren()
        }
}
