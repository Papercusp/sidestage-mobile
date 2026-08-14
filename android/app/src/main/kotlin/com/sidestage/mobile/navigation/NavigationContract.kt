// SPDX-License-Identifier: MIT
package com.sidestage.mobile.navigation

enum class MobileTab(
    val label: String,
) {
    BUYER("Buyer"),
    ORDERS("Orders"),
    ;

    companion object {
        val initial = BUYER
    }
}

sealed interface MobileRoute {
    data object BuyerFeed : MobileRoute

    data class LiveEvent(
        val id: String,
        val title: String,
    ) : MobileRoute

    data class Cart(
        val eventId: String,
    ) : MobileRoute

    data class Checkout(
        val eventId: String,
    ) : MobileRoute

    data object OrdersList : MobileRoute

    data class OrderDetail(
        val id: String,
    ) : MobileRoute
}

object NavigationContract {
    val topLevelTabs: List<MobileTab> = MobileTab.entries

    fun startRoute(tab: MobileTab): MobileRoute =
        when (tab) {
            MobileTab.BUYER -> MobileRoute.BuyerFeed
            MobileTab.ORDERS -> MobileRoute.OrdersList
        }

    fun tabFor(route: MobileRoute): MobileTab =
        when (route) {
            MobileRoute.BuyerFeed,
            is MobileRoute.LiveEvent,
            is MobileRoute.Cart,
            is MobileRoute.Checkout,
            -> MobileTab.BUYER

            MobileRoute.OrdersList,
            is MobileRoute.OrderDetail,
            -> MobileTab.ORDERS
        }
}
