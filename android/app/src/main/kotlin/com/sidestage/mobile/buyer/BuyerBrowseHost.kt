// SPDX-License-Identifier: MIT
@file:Suppress("ktlint:standard:function-naming")

package com.sidestage.mobile.buyer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sidestage.mobile.BuildConfig
import com.sidestage.mobile.theme.SideStageTokens
import uniffi.sidestage.EventSummary

/**
 * Binds the Buyer browse screen to the shared core.
 *
 * `source` is injectable so a preview or an instrumented test can render the
 * screen against a fixture; production gets the same client the live room uses,
 * through [SideStageClientFactory].
 */
@Composable
fun BuyerBrowseHost(
    contentPadding: PaddingValues,
    onOpenEvent: (EventSummary) -> Unit,
    source: BuyerCatalogSource? = SideStageClientFactory.catalogSource,
) {
    val scope = rememberCoroutineScope()

    // A null source means the client could not be built at all — a bad API base
    // URL is a configuration fault, not a transient network error, so it is
    // reported as itself instead of as an empty catalog.
    val holder = remember(source) { source?.let { BuyerBrowseStateHolder(it, scope) } }

    if (holder == null) {
        Column(
            modifier = Modifier.fillMaxSize().padding(contentPadding).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("SideStage cannot reach its API.", style = MaterialTheme.typography.titleMedium)
            Text(
                "The configured API address (${BuildConfig.SIDESTAGE_API_BASE_URL}) is not a usable URL.",
                color = SideStageTokens.Muted,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        return
    }

    LaunchedEffect(holder) { holder.start() }
    val state by holder.state.collectAsState()

    BuyerBrowseScreen(
        state = state,
        contentPadding = contentPadding,
        onSearchTextChanged = holder::onSearchTextChanged,
        onProductTypeSelected = holder::onProductTypeSelected,
        onInStockOnlyChanged = holder::onInStockOnlyChanged,
        onLoadMore = holder::onLoadMore,
        onRetryEvents = holder::onRetryEvents,
        onRetryProducts = holder::onRetryProducts,
        onOpenEvent = onOpenEvent,
    )
}
