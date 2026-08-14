// SPDX-License-Identifier: MIT
package com.sidestage.mobile.orders

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.sidestage.mobile.BuildConfig
import kotlinx.coroutines.CancellationException

data class BuyerOrderLine(
    val productId: String,
    val title: String,
    val priceCents: Long,
    val quantity: Int,
)

data class BuyerOrder(
    val id: String,
    val buyerId: String,
    val eventId: String,
    val createdAt: String,
    val status: String,
    val subtotalCents: Long,
    val shippingCents: Long,
    val totalCents: Long,
    val items: List<BuyerOrderLine>,
    val shippingService: String?,
    val shippingAddress: String?,
)

interface BuyerOrdersGateway {
    val buyerId: String

    suspend fun orders(): List<BuyerOrder>
}

data class BuyerOrdersUiState(
    val orders: List<BuyerOrder> = emptyList(),
    val isRefreshing: Boolean = false,
    val hasLoaded: Boolean = false,
    val errorMessage: String? = null,
)

/** Compose-owned controller around the shared core's Buyer order-history read. */
class BuyerOrdersController(
    private val gateway: BuyerOrdersGateway?,
) {
    val buyerId: String = gateway?.buyerId ?: BuildConfig.SIDESTAGE_BUYER_ID

    var state by mutableStateOf(BuyerOrdersUiState())
        private set

    suspend fun refresh() {
        if (gateway == null) {
            state =
                state.copy(
                    isRefreshing = false,
                    hasLoaded = true,
                    errorMessage = "The shared SideStage core is unavailable.",
                )
            return
        }

        state = state.copy(isRefreshing = true, errorMessage = null)
        try {
            state =
                state.copy(
                    orders = gateway.orders(),
                    isRefreshing = false,
                    hasLoaded = true,
                )
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            state =
                state.copy(
                    isRefreshing = false,
                    hasLoaded = true,
                    errorMessage = error.message ?: "Orders are unavailable right now.",
                )
        }
    }

    fun order(id: String): BuyerOrder? = state.orders.firstOrNull { it.id == id }
}

object BuyerOrdersPresentation {
    const val SUBTITLE =
        "Every checkout, auction win, and private offer for this demo identity—plus the live moments behind each purchase."
    const val EMPTY_DETAIL =
        "Buy from a live, win an auction, or accept a private offer and it will show up here."

    fun emptyTitle(buyerId: String): String = "No orders for $buyerId"

    fun statusLabel(status: String): String =
        status
            .trim()
            .split('-', '_', ' ')
            .filter(String::isNotBlank)
            .joinToString(" ") { it.lowercase() }
            .replaceFirstChar { it.uppercaseChar() }
            .ifEmpty { "Unknown" }

    fun itemCountLabel(order: BuyerOrder): String {
        val count = order.items.sumOf { it.quantity }
        return if (count == 1) "1 item" else "$count items"
    }
}
