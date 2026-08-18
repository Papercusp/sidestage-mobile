// SPDX-License-Identifier: MIT
package com.sidestage.mobile.navigation

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.sidestage.mobile.buyer.BuyerCatalogSource
import com.sidestage.mobile.buyer.UniFfiLiveEventGateway
import com.sidestage.mobile.checkout.BuyerSessionState
import com.sidestage.mobile.orders.BuyerOrder
import com.sidestage.mobile.orders.BuyerOrderLine
import com.sidestage.mobile.orders.BuyerOrdersGateway
import com.sidestage.mobile.theme.SideStageTheme
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import uniffi.sidestage.CatalogPage
import uniffi.sidestage.CatalogSearch
import uniffi.sidestage.EventStatus
import uniffi.sidestage.EventSummary
import uniffi.sidestage.SideStageClient

class SideStageAppSmokeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Before
    fun renderApp() {
        composeRule.setContent {
            SideStageTheme {
                SideStageApp(
                    catalogSource = FakeCatalogSource(),
                    liveEventGateway = null,
                    checkoutGateway = null,
                    ordersGateway = FakeOrdersGateway(),
                    buyerSession = BuyerSessionState(),
                )
            }
        }
    }

    @Test
    fun buyerTabOpensTheLiveRoom() {
        composeRule.onNode(hasText("Buyer") and isSelected()).assertExists()
        composeRule.onNode(hasText("Orders") and hasClickAction()).assertIsDisplayed()
        composeRule.onNodeWithText("Seller").assertDoesNotExist()
        composeRule.onNodeWithText("History").assertDoesNotExist()
        composeRule.onNodeWithText("Config").assertDoesNotExist()
        composeRule.onNodeWithText("Test").assertDoesNotExist()

        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithText("Sunday vintage drop").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("Sunday vintage drop").performClick()

        composeRule.onNodeWithText("Sunday vintage drop").assertIsDisplayed()
        composeRule.onNodeWithText("Connect").assertIsDisplayed()
    }

    @Test
    fun ordersTabOpensAnOrderDetail() {
        composeRule.onNode(hasText("Orders") and hasClickAction()).performClick()

        composeRule.onNode(hasText("Orders") and isSelected()).assertExists()
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithText("Order order-17").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("My orders").assertIsDisplayed()
        composeRule.onNodeWithText("buyer-ff39f82b").assertIsDisplayed()
        composeRule.onNodeWithText("Order order-17").performClick()
        composeRule.onNodeWithText("Order detail").assertIsDisplayed()
        composeRule.onNodeWithText("Vintage jacket").assertIsDisplayed()
    }

    @Test
    fun productionGatewayUsesTheSharedBidLadderWithoutRecursing() {
        val gateway =
            UniFfiLiveEventGateway(
                SideStageClient("http://127.0.0.1"),
                BuyerSessionState(),
            )

        assertEquals(2_600L, gateway.suggestedBidCents(2_400L))
        assertEquals(2_401L, gateway.minimumNextBidCents(2_400L))
    }
}

private class FakeCatalogSource : BuyerCatalogSource {
    override suspend fun events(): List<EventSummary> =
        listOf(
            EventSummary(
                eventId = "sunday-drop",
                title = "Sunday vintage drop",
                sellerId = "seller-1",
                sellerName = "Field Office",
                status = EventStatus.LIVE,
                startsAt = null,
                endedAt = null,
                thumbnailUrl = null,
                playbackUrl = null,
                viewers = 12uL,
            ),
        )

    override suspend fun catalog(search: CatalogSearch): CatalogPage =
        CatalogPage(emptyList(), search.page ?: 1u, search.pageSize ?: 24u, 0uL, false)

    override suspend fun productTypes(): List<String> = emptyList()
}

private class FakeOrdersGateway : BuyerOrdersGateway {
    override val buyerId = "buyer-ff39f82b"

    override suspend fun orders(): List<BuyerOrder> =
        listOf(
            BuyerOrder(
                id = "order-17",
                buyerId = buyerId,
                eventId = "sunday-drop",
                createdAt = "2026-08-14T15:00:00Z",
                status = "paid",
                subtotalCents = 2_000,
                shippingCents = 895,
                totalCents = 2_895,
                items = listOf(BuyerOrderLine("product-1", "Vintage jacket", 2_000, 1)),
                shippingService = "USPS Priority",
                shippingAddress = "123 Main St, Brooklyn, NY 11201",
            ),
        )
}
