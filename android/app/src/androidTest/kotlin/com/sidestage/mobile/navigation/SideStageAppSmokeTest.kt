// SPDX-License-Identifier: MIT
package com.sidestage.mobile.navigation

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.sidestage.mobile.checkout.BuyerSessionState
import com.sidestage.mobile.theme.SideStageTheme
import org.junit.Before
import org.junit.Rule
import org.junit.Test

class SideStageAppSmokeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Before
    fun renderApp() {
        composeRule.setContent {
            SideStageTheme {
                SideStageApp(
                    liveEventGateway = null,
                    checkoutGateway = null,
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

        composeRule.onNodeWithText("Enter live room").performClick()

        composeRule.onNodeWithText("Sunday vintage drop").assertIsDisplayed()
        composeRule.onNodeWithText("Connect").assertIsDisplayed()
    }

    @Test
    fun ordersTabOpensAnOrderDetail() {
        composeRule.onNode(hasText("Orders") and hasClickAction()).performClick()

        composeRule.onNode(hasText("Orders") and isSelected()).assertExists()
        composeRule
            .onNodeWithText("Track payment, shipping, and delivery status.")
            .assertIsDisplayed()
        composeRule.onNodeWithText("Open sample order").performClick()
        composeRule.onNodeWithText("Order detail").assertIsDisplayed()
    }
}
