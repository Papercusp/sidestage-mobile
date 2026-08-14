// SPDX-License-Identifier: MIT
@file:Suppress("ktlint:standard:function-naming")

package com.sidestage.mobile.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Home
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.sidestage.mobile.buyer.BuyerBrowseHost
import com.sidestage.mobile.buyer.BuyerCatalogSource
import com.sidestage.mobile.buyer.BuyerLiveEventScreen
import com.sidestage.mobile.buyer.LiveEventGateway
import com.sidestage.mobile.checkout.BuyerCheckoutGateway
import com.sidestage.mobile.checkout.BuyerCheckoutScreen
import com.sidestage.mobile.checkout.BuyerSessionState
import com.sidestage.mobile.checkout.CheckoutStep
import com.sidestage.mobile.orders.BuyerOrderDetailScreen
import com.sidestage.mobile.orders.BuyerOrdersController
import com.sidestage.mobile.orders.BuyerOrdersGateway
import com.sidestage.mobile.orders.BuyerOrdersScreen
import com.sidestage.mobile.theme.SideStageTokens

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SideStageApp(
    catalogSource: BuyerCatalogSource? = null,
    liveEventGateway: LiveEventGateway? = null,
    checkoutGateway: BuyerCheckoutGateway? = null,
    ordersGateway: BuyerOrdersGateway? = null,
    buyerSession: BuyerSessionState? = null,
) {
    val activeBuyerSession = buyerSession ?: remember { BuyerSessionState() }
    val ordersController = remember(ordersGateway) { BuyerOrdersController(ordersGateway) }
    var selectedTab by remember { mutableStateOf(MobileTab.initial) }
    val buyerStack =
        remember {
            mutableStateListOf<MobileRoute>(NavigationContract.startRoute(MobileTab.BUYER))
        }
    val ordersStack =
        remember {
            mutableStateListOf<MobileRoute>(NavigationContract.startRoute(MobileTab.ORDERS))
        }
    val activeStack =
        when (selectedTab) {
            MobileTab.BUYER -> buyerStack
            MobileTab.ORDERS -> ordersStack
        }
    val route = activeStack.last()

    // D4: Android's system gesture/button unwinds the active tab explicitly.
    BackHandler(enabled = activeStack.size > 1) {
        activeStack.removeAt(activeStack.lastIndex)
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("SideStage", style = MaterialTheme.typography.titleLarge)
                        Text(
                            text = selectedTab.label,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                },
                colors =
                    TopAppBarDefaults.topAppBarColors(
                        containerColor = SideStageTokens.Surface,
                        titleContentColor = MaterialTheme.colorScheme.onSurface,
                    ),
            )
        },
        bottomBar = {
            SideStageNavigationBar(
                selectedTab = selectedTab,
                onSelect = { selectedTab = it },
            )
        },
    ) { innerPadding ->
        when (route) {
            MobileRoute.BuyerFeed -> {
                BuyerBrowseHost(
                    contentPadding = innerPadding,
                    source = catalogSource,
                    onOpenEvent = { event ->
                        buyerStack +=
                            MobileRoute.LiveEvent(
                                id = event.eventId,
                                title = event.title,
                            )
                    },
                )
            }

            is MobileRoute.LiveEvent -> {
                BuyerLiveEventScreen(
                    eventId = route.id,
                    title = route.title,
                    gateway = liveEventGateway,
                    contentPadding = innerPadding,
                    onOpenCart = { buyerStack += MobileRoute.Cart(eventId = route.id) },
                    onOpenCheckout = { buyerStack += MobileRoute.Checkout(eventId = route.id) },
                )
            }

            is MobileRoute.Cart -> {
                BuyerCheckoutScreen(
                    eventId = route.eventId,
                    initialStep = CheckoutStep.CART,
                    gateway = checkoutGateway,
                    session = activeBuyerSession,
                    contentPadding = innerPadding,
                )
            }

            is MobileRoute.Checkout -> {
                BuyerCheckoutScreen(
                    eventId = route.eventId,
                    initialStep = CheckoutStep.ADDRESS,
                    gateway = checkoutGateway,
                    session = activeBuyerSession,
                    contentPadding = innerPadding,
                )
            }

            MobileRoute.OrdersList -> {
                BuyerOrdersScreen(
                    controller = ordersController,
                    contentPadding = innerPadding,
                    onOpenOrder = { ordersStack += MobileRoute.OrderDetail(id = it.id) },
                )
            }

            is MobileRoute.OrderDetail -> {
                BuyerOrderDetailScreen(
                    controller = ordersController,
                    orderId = route.id,
                    contentPadding = innerPadding,
                    onBack = { ordersStack.removeAt(ordersStack.lastIndex) },
                )
            }
        }
    }
}

@Composable
private fun SideStageNavigationBar(
    selectedTab: MobileTab,
    onSelect: (MobileTab) -> Unit,
) {
    NavigationBar(
        modifier = Modifier.padding(bottom = SideStageTokens.BottomGestureInset),
        containerColor = SideStageTokens.Surface,
        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
    ) {
        NavigationContract.topLevelTabs.forEach { tab ->
            val icon: ImageVector =
                when (tab) {
                    MobileTab.BUYER -> Icons.Filled.Home
                    MobileTab.ORDERS -> Icons.AutoMirrored.Filled.List
                }
            NavigationBarItem(
                selected = tab == selectedTab,
                onClick = { onSelect(tab) },
                icon = { Icon(icon, contentDescription = tab.label) },
                label = { Text(tab.label) },
                colors =
                    NavigationBarItemDefaults.colors(
                        selectedIconColor = SideStageTokens.Accent,
                        selectedTextColor = SideStageTokens.Accent,
                        indicatorColor = SideStageTokens.AccentWash,
                        unselectedIconColor = SideStageTokens.Muted,
                        unselectedTextColor = SideStageTokens.Muted,
                    ),
            )
        }
    }
}
