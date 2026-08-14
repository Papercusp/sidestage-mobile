// SPDX-License-Identifier: MIT
@file:Suppress("ktlint:standard:function-naming")

package com.sidestage.mobile.orders

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.sidestage.mobile.buyer.formatPriceCents
import com.sidestage.mobile.theme.SideStageTokens
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BuyerOrdersScreen(
    controller: BuyerOrdersController,
    contentPadding: PaddingValues,
    onOpenOrder: (BuyerOrder) -> Unit,
) {
    val state = controller.state
    val scope = rememberCoroutineScope()
    val refresh: () -> Unit = { scope.launch { controller.refresh() } }

    LaunchedEffect(controller) {
        if (!controller.state.hasLoaded) controller.refresh()
    }

    PullToRefreshBox(
        isRefreshing = state.isRefreshing,
        onRefresh = refresh,
        modifier = Modifier.fillMaxSize().padding(contentPadding),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Buyer history", color = SideStageTokens.Accent, style = MaterialTheme.typography.labelLarge)
                    Text(
                        "My orders",
                        style = MaterialTheme.typography.headlineLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        BuyerOrdersPresentation.SUBTITLE,
                        color = SideStageTokens.Muted,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }

            item {
                OrdersCard {
                    Text("Showing orders for", color = SideStageTokens.Muted, style = MaterialTheme.typography.labelMedium)
                    Text(controller.buyerId, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    OutlinedButton(
                        modifier = Modifier.sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
                        enabled = !state.isRefreshing,
                        onClick = refresh,
                    ) {
                        Text(if (state.isRefreshing) "Refreshing…" else "Refresh")
                    }
                }
            }

            if (state.isRefreshing && !state.hasLoaded) {
                item {
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                        CircularProgressIndicator(color = SideStageTokens.Accent)
                    }
                }
            } else if (state.orders.isEmpty() && state.errorMessage == null) {
                item { OrdersEmptyState(controller.buyerId) }
            }

            state.errorMessage?.let { message ->
                item {
                    OrdersCard {
                        Text("Orders could not be loaded.", fontWeight = FontWeight.Bold)
                        Text(message, color = SideStageTokens.Muted)
                        TextButton(onClick = refresh) { Text("Try again", color = SideStageTokens.Accent) }
                    }
                }
            }

            items(state.orders, key = { it.id }) { order ->
                OrderRow(order = order, onClick = { onOpenOrder(order) })
            }
        }
    }
}

@Composable
fun BuyerOrderDetailScreen(
    controller: BuyerOrdersController,
    orderId: String,
    contentPadding: PaddingValues,
    onBack: () -> Unit,
) {
    val state = controller.state
    val order = controller.order(orderId)

    LaunchedEffect(controller) {
        if (!controller.state.hasLoaded) controller.refresh()
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(contentPadding),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            TextButton(onClick = onBack) { Text("← Back to orders", color = SideStageTokens.Accent) }
        }

        if (order == null) {
            item {
                OrdersCard {
                    Text(
                        if (state.isRefreshing) "Loading order…" else "Order $orderId is not available.",
                        fontWeight = FontWeight.Bold,
                    )
                    state.errorMessage?.let { Text(it, color = SideStageTokens.Muted) }
                }
            }
            return@LazyColumn
        }

        item {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Buyer history", color = SideStageTokens.Accent, style = MaterialTheme.typography.labelLarge)
                Text("Order detail", style = MaterialTheme.typography.headlineLarge)
                Text(order.id, color = SideStageTokens.Muted, style = MaterialTheme.typography.bodyMedium)
            }
        }

        item {
            OrdersCard {
                OrderFact("Status", BuyerOrdersPresentation.statusLabel(order.status))
                OrderFact("Live event", order.eventId)
                OrderFact("Placed", order.createdAt)
                order.shippingService?.let { OrderFact("Shipping", it) }
                order.shippingAddress?.let { OrderFact("Ship to", it) }
            }
        }

        item {
            OrdersCard {
                Text("Items", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                order.items.forEachIndexed { index, line ->
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(line.title, fontWeight = FontWeight.Bold)
                            Text("Quantity ${line.quantity}", color = SideStageTokens.Muted)
                        }
                        Text(formatPriceCents(line.priceCents * line.quantity), fontWeight = FontWeight.Bold)
                    }
                    if (index < order.items.lastIndex) HorizontalDivider(color = SideStageTokens.Border)
                }
            }
        }

        item {
            OrdersCard {
                OrderTotal("Subtotal", order.subtotalCents)
                OrderTotal("Shipping", order.shippingCents)
                HorizontalDivider(color = SideStageTokens.Border)
                OrderTotal("Total", order.totalCents, emphasized = true)
            }
        }
    }
}

@Composable
private fun OrdersEmptyState(buyerId: String) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = SideStageTokens.Background,
        border = BorderStroke(1.dp, SideStageTokens.Border),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("◉", color = SideStageTokens.Accent, style = MaterialTheme.typography.headlineMedium)
            Text(BuyerOrdersPresentation.emptyTitle(buyerId), fontWeight = FontWeight.Bold)
            Text(
                BuyerOrdersPresentation.EMPTY_DETAIL,
                color = SideStageTokens.Muted,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
private fun OrderRow(
    order: BuyerOrder,
    onClick: () -> Unit,
) {
    Surface(
        modifier =
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
        shape = RoundedCornerShape(16.dp),
        color = SideStageTokens.Surface,
        border = BorderStroke(1.dp, SideStageTokens.Border),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Order ${order.id}", modifier = Modifier.weight(1f), fontWeight = FontWeight.Bold)
                Text(
                    BuyerOrdersPresentation.statusLabel(order.status),
                    color = SideStageTokens.Success,
                    style = MaterialTheme.typography.labelMedium,
                )
            }
            Text(
                "${BuyerOrdersPresentation.itemCountLabel(order)} · Live ${order.eventId}",
                color = SideStageTokens.Muted,
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(formatPriceCents(order.totalCents), style = MaterialTheme.typography.titleMedium)
        }
    }
}

@Composable
private fun OrdersCard(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = SideStageTokens.Surface,
        border = BorderStroke(1.dp, SideStageTokens.Border),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = content,
        )
    }
}

@Composable
private fun OrderFact(
    label: String,
    value: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, color = SideStageTokens.Muted, style = MaterialTheme.typography.labelMedium)
        Text(value, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun OrderTotal(
    label: String,
    cents: Long,
    emphasized: Boolean = false,
) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = if (emphasized) MaterialTheme.colorScheme.onSurface else SideStageTokens.Muted)
        Text(formatPriceCents(cents), fontWeight = if (emphasized) FontWeight.Bold else null)
    }
}
