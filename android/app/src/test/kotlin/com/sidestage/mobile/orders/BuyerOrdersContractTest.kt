// SPDX-License-Identifier: MIT
package com.sidestage.mobile.orders

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BuyerOrdersContractTest {
    @Test
    fun `refresh exposes the shared core orders and exact buyer identity`() =
        runBlocking {
            val gateway = FakeOrdersGateway(listOf(order()))
            val controller = BuyerOrdersController(gateway)

            controller.refresh()

            assertEquals("buyer-ff39f82b", controller.buyerId)
            assertEquals(listOf("order-17"), controller.state.orders.map { it.id })
            assertTrue(controller.state.hasLoaded)
            assertFalse(controller.state.isRefreshing)
            assertNull(controller.state.errorMessage)
        }

    @Test
    fun `failed refresh keeps the last good order list visible`() =
        runBlocking {
            val gateway = FakeOrdersGateway(listOf(order()))
            val controller = BuyerOrdersController(gateway)
            controller.refresh()
            gateway.failure = IllegalStateException("network unavailable")

            controller.refresh()

            assertEquals(listOf("order-17"), controller.state.orders.map { it.id })
            assertEquals("network unavailable", controller.state.errorMessage)
            assertFalse(controller.state.isRefreshing)
        }

    @Test
    fun `order presentation is deterministic for statuses and quantities`() {
        val order = order(items = listOf(BuyerOrderLine("a", "Jacket", 2_000, 2), BuyerOrderLine("b", "Hat", 500, 1)))

        assertEquals("Payment pending", BuyerOrdersPresentation.statusLabel("payment-pending"))
        assertEquals("3 items", BuyerOrdersPresentation.itemCountLabel(order))
        assertEquals("No orders for buyer-1", BuyerOrdersPresentation.emptyTitle("buyer-1"))
    }

    private fun order(items: List<BuyerOrderLine> = listOf(BuyerOrderLine("product-1", "Vintage jacket", 2_000, 1))) =
        BuyerOrder(
            id = "order-17",
            buyerId = "buyer-ff39f82b",
            eventId = "sunday-drop",
            createdAt = "2026-08-14T15:00:00Z",
            status = "paid",
            subtotalCents = 2_000,
            shippingCents = 895,
            totalCents = 2_895,
            items = items,
            shippingService = "USPS Priority",
            shippingAddress = "123 Main St, Brooklyn, NY 11201",
        )
}

private class FakeOrdersGateway(
    private val result: List<BuyerOrder>,
) : BuyerOrdersGateway {
    override val buyerId = "buyer-ff39f82b"
    var failure: Exception? = null

    override suspend fun orders(): List<BuyerOrder> {
        failure?.let { throw it }
        return result
    }
}
