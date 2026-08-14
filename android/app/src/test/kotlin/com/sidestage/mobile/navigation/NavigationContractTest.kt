// SPDX-License-Identifier: MIT
package com.sidestage.mobile.navigation

import org.junit.Assert.assertEquals
import org.junit.Test

class NavigationContractTest {
    @Test
    fun `mobile tabs are Buyer and Orders only`() {
        assertEquals(listOf(MobileTab.BUYER, MobileTab.ORDERS), NavigationContract.topLevelTabs)
    }

    @Test
    fun `Buyer is the initial tab`() {
        assertEquals(MobileTab.BUYER, MobileTab.initial)
    }

    @Test
    fun `top-level tabs start at their expected routes`() {
        assertEquals(MobileRoute.BuyerFeed, NavigationContract.startRoute(MobileTab.BUYER))
        assertEquals(MobileRoute.OrdersList, NavigationContract.startRoute(MobileTab.ORDERS))
    }

    @Test
    fun `Buyer route preserves event identity`() {
        val route = MobileRoute.LiveEvent(id = "event-42", title = "Sunday vintage drop")

        assertEquals("event-42", route.id)
        assertEquals("Sunday vintage drop", route.title)
        assertEquals(MobileTab.BUYER, NavigationContract.tabFor(route))
    }

    @Test
    fun `cart and checkout preserve the live event identity`() {
        val cart = MobileRoute.Cart(eventId = "event-42")
        val checkout = MobileRoute.Checkout(eventId = "event-42")

        assertEquals("event-42", cart.eventId)
        assertEquals("event-42", checkout.eventId)
        assertEquals(MobileTab.BUYER, NavigationContract.tabFor(cart))
        assertEquals(MobileTab.BUYER, NavigationContract.tabFor(checkout))
    }

    @Test
    fun `Orders route preserves order identity`() {
        val route = MobileRoute.OrderDetail(id = "order-17")

        assertEquals("order-17", route.id)
        assertEquals(MobileTab.ORDERS, NavigationContract.tabFor(route))
    }
}
