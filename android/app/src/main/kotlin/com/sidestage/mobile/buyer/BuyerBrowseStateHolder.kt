// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import uniffi.sidestage.EventSummary

/** Everything the Buyer browse screen renders, as one immutable snapshot. */
data class BuyerBrowseState(
    val query: BuyerBrowseQuery = BuyerBrowseQuery(),
    val events: List<EventSummary> = emptyList(),
    val products: List<ProductCard> = emptyList(),
    val productTypes: List<String> = listOf(BuyerBrowseDefaults.ALL_TYPES),
    val total: Long = 0,
    val totalIsFloor: Boolean = false,
    val hasMore: Boolean = false,
    val loadingEvents: Boolean = false,
    val loadingProducts: Boolean = false,
    val loadingMore: Boolean = false,
    val eventsError: String? = null,
    val productsError: String? = null,
) {
    /** Events after the local text filter — what the screen actually lists. */
    val visibleEvents: List<EventSummary>
        get() = filterEventsForBrowse(events, query.text)
}

/**
 * Drives Buyer-tab search + browse.
 *
 * Compose-free on purpose: it exposes a `StateFlow` the screen collects, so the
 * debounce, paging and error rules below are exercised by plain JVM tests
 * rather than by an instrumented device run.
 */
class BuyerBrowseStateHolder(
    private val source: BuyerCatalogSource,
    private val scope: CoroutineScope,
    private val debounceMillis: Long = BuyerBrowseDefaults.DEBOUNCE_MILLIS,
) {
    private val backing = MutableStateFlow(BuyerBrowseState())
    val state: StateFlow<BuyerBrowseState> = backing.asStateFlow()

    private var searchJob: Job? = null

    /** Initial load: the event list, the product-type filter, page one. */
    fun start() {
        scope.launch { loadEvents() }
        scope.launch { loadProductTypes() }
        scope.launch { loadProducts(page = BuyerBrowseDefaults.FIRST_PAGE, append = false) }
    }

    fun onSearchTextChanged(text: String) {
        // The field must stay responsive, so the text lands immediately and only
        // the network read waits out the debounce. Event filtering is local and
        // therefore also immediate — typing narrows the room list at once.
        backing.value = backing.value.copy(query = backing.value.query.copy(text = text))
        scheduleProductReload()
    }

    fun onProductTypeSelected(productType: String) {
        backing.value = backing.value.copy(query = backing.value.query.copy(productType = productType))
        scheduleProductReload()
    }

    fun onInStockOnlyChanged(inStockOnly: Boolean) {
        backing.value = backing.value.copy(query = backing.value.query.copy(inStockOnly = inStockOnly))
        scheduleProductReload()
    }

    fun onRetryEvents() {
        scope.launch { loadEvents() }
    }

    fun onLoadMore() {
        val current = backing.value
        if (!current.hasMore || current.loadingProducts || current.loadingMore) return
        scope.launch { loadProducts(page = current.query.page + 1, append = true) }
    }

    /**
     * Restart the debounce window. Cancelling the previous job is what keeps a
     * fast typist from firing a request per keystroke — and, because each new
     * search resets to page one, from paging into a result set that no longer
     * matches what is on screen.
     */
    private fun scheduleProductReload() {
        searchJob?.cancel()
        searchJob =
            scope.launch {
                delay(debounceMillis)
                loadProducts(page = BuyerBrowseDefaults.FIRST_PAGE, append = false)
            }
    }

    suspend fun loadEvents() {
        backing.value = backing.value.copy(loadingEvents = true, eventsError = null)
        try {
            val events = sortEventsForBrowse(source.events())
            backing.value = backing.value.copy(events = events, loadingEvents = false)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            backing.value =
                backing.value.copy(
                    loadingEvents = false,
                    eventsError = error.message ?: "The event list is unavailable right now.",
                )
        }
    }

    suspend fun loadProductTypes() {
        try {
            val types = source.productTypes()
            backing.value =
                backing.value.copy(
                    productTypes = listOf(BuyerBrowseDefaults.ALL_TYPES) + types,
                )
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            // A missing filter list is not worth an error banner: the buyer can
            // still search and browse everything, which is the default anyway.
            backing.value = backing.value.copy(productTypes = listOf(BuyerBrowseDefaults.ALL_TYPES))
        }
    }

    suspend fun loadProducts(
        page: Int,
        append: Boolean,
    ) {
        val requested = backing.value.query.copy(page = page)
        backing.value =
            backing.value.copy(
                query = requested,
                loadingProducts = !append,
                loadingMore = append,
                productsError = null,
            )
        try {
            val result = source.catalog(requested.toCatalogSearch())
            val page1 = result.rows.map { it.toProductCard() }
            backing.value =
                backing.value.copy(
                    products = if (append) backing.value.products + page1 else page1,
                    total = result.total.toLong(),
                    totalIsFloor = result.totalIsFloor,
                    hasMore =
                        hasMoreAfter(
                            page = page,
                            pageSize = requested.pageSize,
                            rowsInPage = result.rows.size,
                            total = result.total.toLong(),
                            totalIsFloor = result.totalIsFloor,
                        ),
                    loadingProducts = false,
                    loadingMore = false,
                )
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            backing.value =
                backing.value.copy(
                    // A failed "load more" keeps the rows already on screen, and
                    // keeps the page cursor where it was, so a retry re-asks for
                    // the page that failed instead of skipping it.
                    query = if (append) requested.copy(page = page - 1) else requested,
                    loadingProducts = false,
                    loadingMore = false,
                    productsError = error.message ?: "The catalog is unavailable right now.",
                )
        }
    }
}
