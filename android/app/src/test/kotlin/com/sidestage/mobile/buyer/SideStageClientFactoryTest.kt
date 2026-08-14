// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.sidestage.Currency
import uniffi.sidestage.Order
import uniffi.sidestage.OrderLine
import uniffi.sidestage.OrderSource
import uniffi.sidestage.OrderStatus

class SideStageClientFactoryTest {
    @Test
    fun `unified order maps into the Android Buyer history contract`() {
        val order =
            Order(
                id = "order_a48d06cf-6c67-4375-8f25-7664243597b0",
                source = OrderSource.CHECKOUT,
                buyerId = "buyer-ff39f82b",
                eventId = "sunday-drop",
                eventTitle = "Sunday vintage drop",
                sellerName = "Marsh & Co Vintage",
                status = OrderStatus.PAID,
                createdAt = "2026-08-14T21:50:00.000Z",
                subtotalCents = 19_900,
                shippingCents = 1_005,
                totalCents = 20_905,
                currency = Currency.USD,
                items =
                    listOf(
                        OrderLine(
                            productId = "cloud-anc-headphones",
                            title = "Cloud ANC Headphones",
                            quantity = 1u,
                            unitPriceCents = 19_900,
                            imageUrl = null,
                        ),
                    ),
                videoSnapshots = emptyList(),
            ).toBuyerHistoryOrder()

        assertEquals("order_a48d06cf-6c67-4375-8f25-7664243597b0", order.id)
        assertEquals("buyer-ff39f82b", order.buyerId)
        assertEquals("paid", order.status)
        assertEquals(19_900, order.items.single().priceCents)
        assertEquals(20_905, order.totalCents)
        assertNull(order.shippingService)
        assertNull(order.shippingAddress)
    }
}
