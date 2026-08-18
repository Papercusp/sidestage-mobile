// SPDX-License-Identifier: MIT
@file:Suppress("ktlint:standard:function-naming")

package com.sidestage.mobile.buyer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.sidestage.mobile.theme.SideStageTokens
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack
import uniffi.sidestage.waitingForPublisherMessage
import java.time.Instant

data class LiveEventUiState(
    val title: String,
    val viewers: ULong = 0u,
    /** Server-computed WHEP endpoint (D-035); null keeps the stage playerless. */
    val playbackUrl: String? = null,
    val connection: LiveConnectionState = LiveConnectionState.CONNECTING,
    val retryInMs: ULong? = null,
    val snapshot: LiveRoomSnapshot? = null,
    val bidText: String = "",
    val isSubmittingBid: Boolean = false,
    val bidError: String? = null,
    val streamError: String? = null,
    val cartError: String? = null,
    val cartId: String? = null,
    val cartItemCount: Int = 0,
    val isUpdatingCart: Boolean = false,
)

class LiveEventController(
    private val eventId: String,
    initialTitle: String,
    private val gateway: LiveEventGateway?,
) {
    var state by mutableStateOf(LiveEventUiState(title = initialTitle))
        private set

    private var subscription: LiveRoomSubscription? = null
    private var seededBidKey: String? = null

    suspend fun run() {
        val activeGateway = gateway
        if (activeGateway == null) {
            state = state.copy(streamError = "The shared SideStage core is unavailable.")
            return
        }

        runCatching { activeGateway.event(eventId) }
            .onSuccess { event ->
                state =
                    state.copy(
                        title = event.title,
                        viewers = event.viewers,
                        playbackUrl = event.playbackUrl,
                    )
            }

        try {
            subscription = activeGateway.liveEventSync(eventId)
            while (true) {
                when (val update = subscription?.next() ?: break) {
                    is LiveRoomUpdate.Status -> {
                        state =
                            state.copy(
                                connection = update.state,
                                retryInMs = update.retryInMs,
                                streamError =
                                    if (update.state == LiveConnectionState.LIVE) null else state.streamError,
                            )
                    }

                    is LiveRoomUpdate.Snapshot -> {
                        state = state.copy(snapshot = update.value, streamError = null)
                        seedBidField(update.value.auction)
                    }

                    is LiveRoomUpdate.Error -> {
                        state = state.copy(streamError = update.message)
                    }
                }
            }
        } catch (error: LiveEventGatewayException) {
            state = state.copy(streamError = "Could not join the live room.")
        }
    }

    fun stop() {
        subscription?.close()
        subscription = null
    }

    fun setBidText(value: String) {
        state = state.copy(bidText = value, bidError = null)
    }

    fun bidAvailability(): BidAvailability =
        LiveEventPresentation.bidAvailability(
            auction = state.snapshot?.auction,
            bidText = state.bidText,
            buyerId = gateway?.buyerId,
            isSubmitting = state.isSubmittingBid,
            minimumNextBid = gateway?.let { active -> active::minimumNextBidCents } ?: { it + 1L },
        )

    suspend fun placeBid() {
        val activeGateway = gateway ?: return
        val auction = state.snapshot?.auction ?: return
        val availability = bidAvailability()
        if (availability !is BidAvailability.Ready) return
        val buyerId = activeGateway.buyerId ?: return

        state = state.copy(isSubmittingBid = true, bidError = null)
        try {
            val updated =
                activeGateway.placeBid(
                    auctionId = auction.id,
                    bidderId = buyerId,
                    amountCents = availability.amountCents,
                )
            val snapshot = state.snapshot ?: return
            state = state.copy(snapshot = snapshot.copy(auction = updated))
            seedBidField(updated)
        } catch (error: LiveEventGatewayException) {
            val message =
                when (error.status) {
                    409 -> "Someone outbid you — the price just moved."
                    401, 403 -> "Sign in again to bid."
                    else -> "Could not place your bid. Try again."
                }
            state = state.copy(bidError = message)
        } finally {
            state = state.copy(isSubmittingBid = false)
        }
    }

    suspend fun addOnDeckToCart(): Boolean {
        val activeGateway = gateway ?: return false
        val product = state.snapshot?.onDeckProduct ?: return false
        state = state.copy(isUpdatingCart = true, cartError = null)
        return try {
            val cart = activeGateway.addCartItem(state.cartId, product)
            state =
                state.copy(
                    cartId = cart.id,
                    cartItemCount = cart.itemCount,
                    isUpdatingCart = false,
                )
            true
        } catch (error: LiveEventGatewayException) {
            state =
                state.copy(
                    cartError = "Could not add that to your cart.",
                    isUpdatingCart = false,
                )
            false
        }
    }

    private fun seedBidField(auction: LiveAuctionState?) {
        val activeGateway = gateway ?: return
        if (auction == null) {
            seededBidKey = null
            return
        }
        val key = "${auction.id}:${auction.currentPriceCents}"
        if (key == seededBidKey) return
        seededBidKey = key
        state =
            state.copy(
                bidText =
                    LiveEventPresentation.bidFieldText(
                        activeGateway.suggestedBidCents(auction.currentPriceCents),
                    ),
            )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BuyerLiveEventScreen(
    eventId: String,
    title: String,
    gateway: LiveEventGateway?,
    contentPadding: PaddingValues,
    onOpenCart: () -> Unit,
    onOpenCheckout: () -> Unit,
) {
    val controller = remember(eventId, gateway) { LiveEventController(eventId, title, gateway) }
    val state = controller.state
    val scope = rememberCoroutineScope()
    var showChat by remember { mutableStateOf(false) }

    LaunchedEffect(controller) { controller.run() }
    DisposableEffect(controller) { onDispose(controller::stop) }

    if (showChat) {
        LiveChatSheet(
            transcript = state.snapshot?.transcript.orEmpty(),
            onDismiss = { showChat = false },
        )
    }

    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(contentPadding)
                .padding(horizontal = 16.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Join the room", color = SideStageTokens.Accent, style = MaterialTheme.typography.labelLarge)
        Text(state.title, style = MaterialTheme.typography.headlineMedium)
        Text(
            "Watch together, ask questions, and keep the good finds moving.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )

        StreamStage(eventId = eventId, playbackUrl = state.playbackUrl)
        RoomStats(viewers = state.viewers)
        RoomBar(
            activeCount =
                maxOf(
                    state.viewers.toLong(),
                    state.snapshot
                        ?.transcript
                        ?.distinctBy { it.displayName }
                        ?.size
                        ?.toLong() ?: 0L,
                ),
            onOpenChat = { showChat = true },
        )
        AuctionCard(controller = controller, state = state)
        OnDeckCard(
            state = state,
            onAddToCart = { scope.launch { controller.addOnDeckToCart() } },
            onBuyNow = {
                scope.launch {
                    if (controller.addOnDeckToCart()) onOpenCheckout()
                }
            },
        )

        if (state.cartItemCount > 0) {
            OutlinedButton(
                modifier = Modifier.fillMaxWidth().sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
                onClick = onOpenCart,
            ) {
                Text("View cart (${state.cartItemCount})")
            }
        }
        state.streamError?.let { InlineError(it) }
    }
}

/**
 * The live stage: a WHEP viewer driven by the SERVER's playback URL (D-035,
 * WI-39800). All reconnect policy comes from the shared core through
 * [WhepPlayerController]; a null [playbackUrl] (old API / unconfigured media
 * plane) honestly renders no player at all instead of guessing an address.
 */
@Composable
private fun StreamStage(
    eventId: String,
    playbackUrl: String?,
) {
    var playback by remember(eventId, playbackUrl) { mutableStateOf<WhepPlayback>(WhepPlayback.Idle) }
    var videoTrack by remember(eventId, playbackUrl) { mutableStateOf<VideoTrack?>(null) }
    var renderer by remember(eventId, playbackUrl) { mutableStateOf<SurfaceViewRenderer?>(null) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val controller =
        remember(eventId, playbackUrl) {
            playbackUrl?.let { url ->
                WhepPlayerController(
                    context = context,
                    playbackUrl = url,
                    scope = scope,
                    onPlayback = { current -> playback = current },
                    onVideoTrack = { track -> videoTrack = track },
                )
            }
        }

    DisposableEffect(controller) {
        onDispose { controller?.release() }
    }

    // The remote track and the renderer arrive independently (native callback
    // vs composition); attach whenever both exist, detach when either goes.
    DisposableEffect(videoTrack, renderer) {
        val track = videoTrack
        val view = renderer
        if (track != null && view != null) track.addSink(view)
        onDispose {
            if (track != null && view != null) runCatching { track.removeSink(view) }
        }
    }

    val active = playback is WhepPlayback.Connecting || playback is WhepPlayback.Live
    Box(
        modifier =
            Modifier
                .fillMaxWidth()
                .height(210.dp)
                .background(SideStageTokens.Stage, RoundedCornerShape(16.dp)),
    ) {
        if (active) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { viewContext ->
                    SurfaceViewRenderer(viewContext).also { view ->
                        view.init(WebRtcEngine.eglBase.eglBaseContext, null)
                        view.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
                        renderer = view
                    }
                },
                onRelease = { view ->
                    renderer = null
                    view.release()
                },
            )
        }

        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(eventId, color = SideStageTokens.StageInk, style = MaterialTheme.typography.labelLarge)
                    Text(
                        when (val current = playback) {
                            WhepPlayback.Idle ->
                                if (playbackUrl == null) {
                                    "Live playback isn't available for this room yet."
                                } else {
                                    "The seller stream appears here when the room is live."
                                }
                            is WhepPlayback.Connecting ->
                                if (current.waitingForPublisher) waitingForPublisherMessage() else "Connecting…"
                            WhepPlayback.Live -> "Live"
                            is WhepPlayback.Failed -> current.message
                        },
                        color = SideStageTokens.StageInk.copy(alpha = 0.75f),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                if (controller != null) {
                    Button(
                        onClick = {
                            if (active) controller.disconnect() else controller.connect()
                        },
                        shape = RoundedCornerShape(SideStageTokens.PrimaryButtonRadius),
                        colors =
                            ButtonDefaults.buttonColors(
                                containerColor = SideStageTokens.Accent,
                                contentColor = SideStageTokens.OnAccent,
                            ),
                    ) {
                        Text(
                            when {
                                active -> "Disconnect"
                                playback is WhepPlayback.Failed -> "Retry"
                                else -> "Connect"
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun RoomStats(viewers: ULong) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Stat("$viewers", "watching", Modifier.weight(1f))
        Stat("0", "items sold", Modifier.weight(1f))
        Stat("$0.00", "raised", Modifier.weight(1f))
    }
}

@Composable
private fun Stat(
    value: String,
    label: String,
    modifier: Modifier,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        color = SideStageTokens.Surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, SideStageTokens.Border),
    ) {
        Column(modifier = Modifier.padding(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(value, fontWeight = FontWeight.Bold)
            Text(label, color = SideStageTokens.Muted, style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable
private fun RoomBar(
    activeCount: Long,
    onOpenChat: () -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = SideStageTokens.Surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, SideStageTokens.Border),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(8.dp).background(SideStageTokens.Success, CircleShape))
            Text(
                "In the room · $activeCount active",
                modifier = Modifier.padding(start = 8.dp).weight(1f),
                style = MaterialTheme.typography.labelMedium,
            )
            TextButton(onClick = onOpenChat) { Text("Live chat") }
        }
    }
}

@Composable
private fun AuctionCard(
    controller: LiveEventController,
    state: LiveEventUiState,
) {
    val auction = state.snapshot?.auction
    val scope = rememberCoroutineScope()
    var now by remember(auction?.id) { mutableStateOf(Instant.now()) }
    LaunchedEffect(auction?.id) {
        while (auction != null) {
            delay(1_000)
            now = Instant.now()
        }
    }
    val connectionLabel = LiveEventPresentation.connectionLabel(state.connection, state.retryInMs)

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = SideStageTokens.Surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, SideStageTokens.Border),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Live auction", color = SideStageTokens.Accent, style = MaterialTheme.typography.labelLarge)
                    Text("Bid from the room", fontWeight = FontWeight.Bold)
                }
                StatusPill(connectionLabel)
            }
            if (auction == null) {
                Surface(shape = RoundedCornerShape(12.dp), color = SideStageTokens.BackgroundWash) {
                    Column(modifier = Modifier.padding(14.dp)) {
                        Text("No auction is live yet.", fontWeight = FontWeight.Bold)
                        Text(
                            "Stay here—the panel updates as soon as the seller starts one.",
                            color = SideStageTokens.Muted,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            } else {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column {
                        Text("Current bid", color = SideStageTokens.Muted, style = MaterialTheme.typography.labelMedium)
                        Text(LiveEventPresentation.formatPrice(auction.currentPriceCents), fontWeight = FontWeight.Bold)
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text("Time left", color = SideStageTokens.Muted, style = MaterialTheme.typography.labelMedium)
                        Text(
                            LiveEventPresentation.formatCountdown(
                                LiveEventPresentation.secondsRemaining(auction.endsAt, now),
                            ),
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
                auction.bids.firstOrNull()?.let { bid ->
                    Text(
                        "Leading: ${bid.displayName ?: bid.bidderId} · ${LiveEventPresentation.formatPrice(bid.amountCents)}",
                        color = SideStageTokens.Muted,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                OutlinedTextField(
                    modifier = Modifier.fillMaxWidth(),
                    value = state.bidText,
                    onValueChange = controller::setBidText,
                    label = { Text("Your bid (USD)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                )
                val availability = controller.bidAvailability()
                LiveEventPresentation.bidAvailabilityMessage(availability)?.let { message ->
                    Text(message, color = SideStageTokens.Muted, style = MaterialTheme.typography.labelMedium)
                }
                PrimaryLiveAction(
                    label = if (state.isSubmittingBid) "Placing bid…" else "Place bid",
                    enabled = availability is BidAvailability.Ready,
                    onClick = { scope.launch { controller.placeBid() } },
                )
                state.bidError?.let { InlineError(it) }
            }
        }
    }
}

@Composable
private fun OnDeckCard(
    state: LiveEventUiState,
    onAddToCart: () -> Unit,
    onBuyNow: () -> Unit,
) {
    val product = state.snapshot?.onDeckProduct
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("On stage now", color = SideStageTokens.Accent, style = MaterialTheme.typography.labelLarge)
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Shop the drop", fontWeight = FontWeight.Bold)
            Text(
                "${product?.availableQuantity ?: 0} available",
                color = SideStageTokens.Muted,
                style = MaterialTheme.typography.labelMedium,
            )
        }
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(14.dp),
            color = SideStageTokens.Surface,
            border = androidx.compose.foundation.BorderStroke(1.dp, SideStageTokens.Border),
        ) {
            if (product == null) {
                Text(
                    "No product is on deck yet.",
                    modifier = Modifier.padding(16.dp),
                    color = SideStageTokens.Muted,
                )
            } else {
                Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier =
                                Modifier
                                    .size(44.dp)
                                    .background(SideStageTokens.BackgroundWash, RoundedCornerShape(10.dp)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(product.title.firstOrNull()?.uppercase() ?: "•", fontWeight = FontWeight.Bold)
                        }
                        Column(modifier = Modifier.padding(start = 10.dp).weight(1f)) {
                            Text(product.title, fontWeight = FontWeight.Bold)
                            Text(
                                listOfNotNull(product.brand, product.condition).joinToString(" · "),
                                color = SideStageTokens.Muted,
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text(LiveEventPresentation.formatPrice(product.priceCents), fontWeight = FontWeight.Bold)
                            Text(
                                "${product.availableQuantity} ready",
                                color = SideStageTokens.Success,
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            modifier = Modifier.weight(1f).sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
                            enabled = !state.isUpdatingCart && product.availableQuantity > 0,
                            onClick = onAddToCart,
                        ) {
                            Text("Add to cart")
                        }
                        Button(
                            modifier = Modifier.weight(1f).sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
                            enabled = !state.isUpdatingCart && product.availableQuantity > 0,
                            onClick = onBuyNow,
                            shape = RoundedCornerShape(SideStageTokens.PrimaryButtonRadius),
                            colors =
                                ButtonDefaults.buttonColors(
                                    containerColor = SideStageTokens.Accent,
                                    contentColor = SideStageTokens.OnAccent,
                                ),
                        ) {
                            Text("Buy now")
                        }
                    }
                    state.cartError?.let { InlineError(it) }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LiveChatSheet(
    transcript: List<LiveTranscriptEntry>,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Live chat", style = MaterialTheme.typography.titleLarge)
            if (transcript.isEmpty()) {
                Text("Chat is quiet right now.", color = SideStageTokens.Muted)
            } else {
                transcript.takeLast(20).forEachIndexed { index, entry ->
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(entry.displayName, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                        Text(entry.text, style = MaterialTheme.typography.bodyMedium)
                    }
                    if (index < transcript.takeLast(20).lastIndex) HorizontalDivider(color = SideStageTokens.Border)
                }
            }
        }
    }
}

@Composable
private fun StatusPill(label: String) {
    Surface(shape = CircleShape, color = SideStageTokens.SuccessWash) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            color = SideStageTokens.Success,
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

@Composable
private fun PrimaryLiveAction(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Button(
        modifier = Modifier.fillMaxWidth().sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
        enabled = enabled,
        onClick = onClick,
        shape = RoundedCornerShape(SideStageTokens.PrimaryButtonRadius),
        colors =
            ButtonDefaults.buttonColors(
                containerColor = SideStageTokens.Accent,
                contentColor = SideStageTokens.OnAccent,
            ),
    ) {
        Text(label)
    }
}

@Composable
private fun InlineError(message: String) {
    Text(message, color = Color(0xFF9F1D16), style = MaterialTheme.typography.labelMedium)
}
