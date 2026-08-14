// SPDX-License-Identifier: MIT
@file:Suppress("ktlint:standard:function-naming")

package com.sidestage.mobile.buyer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.sidestage.mobile.theme.SideStageTokens
import uniffi.sidestage.EventStatus
import uniffi.sidestage.EventSummary

/**
 * Buyer tab search + browse: the rooms you can join and the catalog behind
 * them. Tapping a room hands off to the live-event screen.
 *
 * Stateless by construction — every value comes in as [BuyerBrowseState] and
 * every gesture leaves as a callback, so the screen can be rendered from a
 * fixture without a network or a native library.
 */
@Composable
fun BuyerBrowseScreen(
    state: BuyerBrowseState,
    contentPadding: PaddingValues,
    onSearchTextChanged: (String) -> Unit,
    onProductTypeSelected: (String) -> Unit,
    onInStockOnlyChanged: (Boolean) -> Unit,
    onLoadMore: () -> Unit,
    onRetryEvents: () -> Unit,
    onRetryProducts: () -> Unit,
    onOpenEvent: (EventSummary) -> Unit,
) {
    val events = state.visibleEvents

    LazyColumn(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = contentPadding,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Column(
                modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "Browse the drops",
                    color = SideStageTokens.Accent,
                    style = MaterialTheme.typography.labelLarge,
                )
                Text("What's on", style = MaterialTheme.typography.headlineMedium)
                SearchField(text = state.query.text, onTextChanged = onSearchTextChanged)
            }
        }

        item { SectionHead(title = "Rooms", trailing = eventCountLabel(state, events.size)) }

        if (state.eventsError != null) {
            item {
                ErrorNotice(
                    message = state.eventsError,
                    actionLabel = "Try again",
                    onAction = onRetryEvents,
                )
            }
        }

        if (events.isEmpty() && !state.loadingEvents && state.eventsError == null) {
            item {
                EmptyNotice(
                    title = "No rooms match that yet.",
                    body = "Clear the search to see every drop the sellers have lined up.",
                )
            }
        }

        items(events, key = { it.eventId }) { event ->
            EventRow(event = event, onOpen = { onOpenEvent(event) })
        }

        item {
            SectionHead(
                title = "Shop the catalog",
                trailing = productCountLabel(state),
            )
        }

        item {
            CatalogFilters(
                state = state,
                onProductTypeSelected = onProductTypeSelected,
                onInStockOnlyChanged = onInStockOnlyChanged,
            )
        }

        if (state.productsError != null) {
            item {
                ErrorNotice(
                    message = state.productsError,
                    actionLabel = "Try again",
                    onAction = onRetryProducts,
                )
            }
        }

        if (state.products.isEmpty() && !state.loadingProducts && state.productsError == null) {
            item {
                EmptyNotice(
                    title = "Nothing in the catalog matches that.",
                    body = "Try fewer words, or turn off the in-stock filter to include sold-out stock.",
                )
            }
        }

        items(state.products, key = { it.id }) { product ->
            ProductRow(product = product)
        }

        if (state.loadingEvents || state.loadingProducts || state.loadingMore) {
            item { LoadingRow() }
        }

        if (state.hasMore && !state.loadingMore && !state.loadingProducts) {
            item {
                Box(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    TextButton(onClick = onLoadMore) {
                        Text("Load more", color = SideStageTokens.Accent)
                    }
                }
            }
        }

        item { Box(modifier = Modifier.size(16.dp)) }
    }
}

private fun eventCountLabel(
    state: BuyerBrowseState,
    visible: Int,
): String =
    when {
        state.loadingEvents && state.events.isEmpty() -> "loading"
        visible == 1 -> "1 room"
        else -> "$visible rooms"
    }

private fun productCountLabel(state: BuyerBrowseState): String {
    if (state.loadingProducts && state.products.isEmpty()) return "loading"
    // `totalIsFloor` means the API proved only a lower bound, so the count is
    // rendered as "1,000+ found" rather than claiming an exact catalog size.
    val suffix = if (state.totalIsFloor) "+" else ""
    return "${formatCount(state.total)}$suffix found"
}

private fun formatCount(value: Long): String =
    value
        .toString()
        .reversed()
        .chunked(3)
        .joinToString(",")
        .reversed()

@Composable
private fun SearchField(
    text: String,
    onTextChanged: (String) -> Unit,
) {
    OutlinedTextField(
        value = text,
        onValueChange = onTextChanged,
        singleLine = true,
        modifier =
            Modifier
                .fillMaxWidth()
                .sizeIn(minHeight = SideStageTokens.MinimumTouchTarget)
                .semantics { contentDescription = "Search events and products" },
        placeholder = {
            Text(
                "Search events and products",
                color = SideStageTokens.Muted,
                style = MaterialTheme.typography.bodyMedium,
            )
        },
        shape = RoundedCornerShape(14.dp),
        colors =
            OutlinedTextFieldDefaults.colors(
                focusedBorderColor = SideStageTokens.Accent,
                unfocusedBorderColor = SideStageTokens.Border,
                focusedContainerColor = SideStageTokens.Surface,
                unfocusedContainerColor = SideStageTokens.Surface,
                cursorColor = SideStageTokens.Accent,
            ),
    )
}

@Composable
private fun SectionHead(
    title: String,
    trailing: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(
            trailing,
            color = SideStageTokens.Muted,
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

@Composable
private fun CatalogFilters(
    state: BuyerBrowseState,
    onProductTypeSelected: (String) -> Unit,
    onInStockOnlyChanged: (Boolean) -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FilterChip(
            selected = state.query.inStockOnly,
            onClick = { onInStockOnlyChanged(!state.query.inStockOnly) },
            label = { Text("In stock only") },
            colors =
                FilterChipDefaults.filterChipColors(
                    selectedContainerColor = SideStageTokens.AccentWash,
                    selectedLabelColor = SideStageTokens.Accent,
                ),
        )
        // The type list is short and buyer-facing; a wrapping row of chips beats
        // a dropdown on a phone because every option stays one tap away.
        state.productTypes.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { productType ->
                    FilterChip(
                        selected = state.query.productType == productType,
                        onClick = { onProductTypeSelected(productType) },
                        label = {
                            Text(
                                productTypeLabel(productType),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        colors =
                            FilterChipDefaults.filterChipColors(
                                selectedContainerColor = SideStageTokens.AccentWash,
                                selectedLabelColor = SideStageTokens.Accent,
                            ),
                    )
                }
            }
        }
    }
}

@Composable
private fun EventRow(
    event: EventSummary,
    onOpen: () -> Unit,
) {
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .border(1.dp, SideStageTokens.Border, RoundedCornerShape(14.dp))
                .background(SideStageTokens.Surface, RoundedCornerShape(14.dp))
                .clickable(onClick = onOpen)
                .padding(12.dp)
                .sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Thumbnail(monogram = monogramFor(event.title))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                event.title,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                event.sellerName,
                color = SideStageTokens.Muted,
                style = MaterialTheme.typography.labelMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            StatusPill(status = event.status)
            Text(
                "${event.viewers} watching",
                color = SideStageTokens.Muted,
                style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}

@Composable
private fun StatusPill(status: EventStatus) {
    val label =
        when (status) {
            EventStatus.LIVE -> "Live"
            EventStatus.SCHEDULED -> "Scheduled"
            EventStatus.ENDED -> "Ended"
        }
    val background = if (status == EventStatus.LIVE) SideStageTokens.SuccessWash else SideStageTokens.BackgroundWash
    val foreground = if (status == EventStatus.LIVE) SideStageTokens.Success else SideStageTokens.Muted
    Text(
        label,
        color = foreground,
        style = MaterialTheme.typography.labelSmall,
        modifier =
            Modifier
                .background(background, RoundedCornerShape(999.dp))
                .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

@Composable
private fun ProductRow(product: ProductCard) {
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .border(1.dp, SideStageTokens.Border, RoundedCornerShape(14.dp))
                .background(SideStageTokens.Surface, RoundedCornerShape(14.dp))
                .padding(12.dp)
                .sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Thumbnail(monogram = product.monogram)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                product.title,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                product.subtitle,
                color = SideStageTokens.Muted,
                style = MaterialTheme.typography.labelMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(product.priceLabel, style = MaterialTheme.typography.bodyMedium)
            Text(
                if (product.soldOut) "Sold out" else product.readyLabel,
                color = if (product.soldOut) SideStageTokens.Accent else SideStageTokens.Muted,
                style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}

@Composable
private fun Thumbnail(monogram: String) {
    Box(
        modifier =
            Modifier
                .size(44.dp)
                .background(SideStageTokens.BackgroundWash, RoundedCornerShape(12.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Text(monogram, color = SideStageTokens.Muted, style = MaterialTheme.typography.titleMedium)
    }
}

@Composable
private fun LoadingRow() {
    Box(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(modifier = Modifier.size(22.dp), color = SideStageTokens.Accent)
    }
}

@Composable
private fun EmptyNotice(
    title: String,
    body: String,
) {
    Column(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .border(1.dp, SideStageTokens.Border, RoundedCornerShape(14.dp))
                .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(title, style = MaterialTheme.typography.bodyLarge)
        Text(body, color = SideStageTokens.Muted, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun ErrorNotice(
    message: String,
    actionLabel: String?,
    onAction: (() -> Unit)?,
) {
    Column(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .border(1.dp, SideStageTokens.AccentWash, RoundedCornerShape(14.dp))
                .background(SideStageTokens.AccentWash, RoundedCornerShape(14.dp))
                .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(message, color = SideStageTokens.Ink, style = MaterialTheme.typography.bodyMedium)
        if (actionLabel != null && onAction != null) {
            Button(
                onClick = onAction,
                shape = RoundedCornerShape(SideStageTokens.PrimaryButtonRadius),
                colors =
                    ButtonDefaults.buttonColors(
                        containerColor = SideStageTokens.Accent,
                        contentColor = SideStageTokens.OnAccent,
                    ),
            ) {
                Text(actionLabel)
            }
        }
    }
}
