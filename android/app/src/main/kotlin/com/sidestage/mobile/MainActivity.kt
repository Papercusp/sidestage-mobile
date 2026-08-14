// SPDX-License-Identifier: MIT
package com.sidestage.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.sidestage.mobile.buyer.SideStageClientFactory
import com.sidestage.mobile.navigation.SideStageApp
import com.sidestage.mobile.theme.SideStageTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SideStageTheme {
                SideStageApp(
                    catalogSource = SideStageClientFactory.catalogSource,
                    liveEventGateway = SideStageClientFactory.shared,
                    checkoutGateway = SideStageClientFactory.checkoutGateway,
                    ordersGateway = SideStageClientFactory.ordersGateway,
                    buyerSession = SideStageClientFactory.buyerSession,
                )
            }
        }
    }
}
