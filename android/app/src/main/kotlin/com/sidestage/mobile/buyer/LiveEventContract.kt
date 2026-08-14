// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import java.math.BigDecimal
import java.math.RoundingMode
import java.text.NumberFormat
import java.time.Duration
import java.time.Instant
import java.util.Locale

data class LiveEventHeader(
    val title: String,
    val viewers: ULong,
    val thumbnailUrl: String?,
)

data class LiveProduct(
    val id: String,
    val title: String,
    val brand: String,
    val condition: String?,
    val priceCents: Long,
    val availableQuantity: Long,
    val imageUrl: String?,
)

enum class LiveAuctionStatus {
    ACTIVE,
    CLOSED,
}

data class LiveBid(
    val bidderId: String,
    val displayName: String?,
    val amountCents: Long,
)

data class LiveAuctionState(
    val id: String,
    val currentPriceCents: Long,
    val status: LiveAuctionStatus,
    val endsAt: String,
    val bids: List<LiveBid>,
)

data class LiveTranscriptEntry(
    val displayName: String,
    val text: String,
)

data class LiveRoomSnapshot(
    val transcript: List<LiveTranscriptEntry>,
    val onDeckProduct: LiveProduct?,
    val auction: LiveAuctionState?,
)

enum class LiveConnectionState {
    CONNECTING,
    LIVE,
    POLLING,
}

sealed interface LiveRoomUpdate {
    data class Status(
        val state: LiveConnectionState,
        val retryInMs: ULong? = null,
    ) : LiveRoomUpdate

    data class Snapshot(
        val value: LiveRoomSnapshot,
    ) : LiveRoomUpdate

    data class Error(
        val message: String,
    ) : LiveRoomUpdate
}

interface LiveRoomSubscription {
    suspend fun next(): LiveRoomUpdate?

    fun close()
}

data class LiveCartResult(
    val id: String,
    val itemCount: Int,
)

interface LiveEventGateway {
    val buyerId: String?

    suspend fun event(eventId: String): LiveEventHeader

    fun liveEventSync(eventId: String): LiveRoomSubscription

    suspend fun placeBid(
        auctionId: String,
        bidderId: String,
        amountCents: Long,
    ): LiveAuctionState

    suspend fun addCartItem(
        cartId: String?,
        product: LiveProduct,
    ): LiveCartResult

    fun suggestedBidCents(currentPriceCents: Long): Long

    fun minimumNextBidCents(currentPriceCents: Long): Long
}

class LiveEventGatewayException(
    val status: Int? = null,
    cause: Throwable? = null,
) : Exception(cause)

sealed interface BidAvailability {
    data class Ready(
        val amountCents: Long,
    ) : BidAvailability

    data object NoAuction : BidAvailability

    data object AuctionClosed : BidAvailability

    data object SignedOut : BidAvailability

    data object AmountNotANumber : BidAvailability

    data class BelowMinimum(
        val minimumCents: Long,
    ) : BidAvailability

    data object Submitting : BidAvailability
}

object LiveEventPresentation {
    private val bidPattern = Regex("^[0-9]+(?:\\.[0-9]{1,2})?$")
    private val eventIdPattern = Regex("^[a-z0-9][a-z0-9-]{0,63}$")

    fun formatPrice(cents: Long): String = NumberFormat.getCurrencyInstance(Locale.US).format(BigDecimal.valueOf(cents, 2))

    fun parseBidDollars(value: String): Long? {
        val normalized = value.trim()
        if (!bidPattern.matches(normalized)) return null
        return runCatching {
            normalized
                .toBigDecimal()
                .movePointRight(2)
                .setScale(0, RoundingMode.UNNECESSARY)
                .longValueExact()
                .takeIf { it > 0 }
        }.getOrNull()
    }

    fun bidFieldText(cents: Long): String = BigDecimal.valueOf(cents, 2).stripTrailingZeros().toPlainString()

    fun secondsRemaining(
        endsAt: String,
        now: Instant = Instant.now(),
    ): Long =
        runCatching {
            val millis = Duration.between(now, Instant.parse(endsAt)).toMillis()
            ((millis + 999L) / 1_000L).coerceAtLeast(0L)
        }.getOrDefault(0L)

    fun formatCountdown(seconds: Long): String {
        val safe = seconds.coerceAtLeast(0L)
        return "%d:%02d".format(Locale.US, safe / 60L, safe % 60L)
    }

    fun connectionLabel(
        state: LiveConnectionState,
        retryInMs: ULong? = null,
    ): String =
        when (state) {
            LiveConnectionState.CONNECTING -> {
                "Connecting…"
            }

            LiveConnectionState.LIVE -> {
                "Live"
            }

            LiveConnectionState.POLLING -> {
                val retrySeconds = retryInMs?.let { (it + 999uL) / 1_000uL }
                if (retrySeconds != null && retrySeconds > 0uL) {
                    "Reconnecting in ${retrySeconds}s"
                } else {
                    "Reconnecting…"
                }
            }
        }

    fun streamUrl(
        baseUrl: String,
        eventId: String,
    ): String {
        require(eventIdPattern.matches(eventId)) { "Invalid SideStage event id" }
        return "${baseUrl.trimEnd('/')}/sidestage-$eventId/index.m3u8"
    }

    fun bidAvailability(
        auction: LiveAuctionState?,
        bidText: String,
        buyerId: String?,
        isSubmitting: Boolean,
        minimumNextBid: (Long) -> Long,
    ): BidAvailability {
        if (isSubmitting) return BidAvailability.Submitting
        if (auction == null) return BidAvailability.NoAuction
        if (auction.status != LiveAuctionStatus.ACTIVE) return BidAvailability.AuctionClosed
        if (buyerId == null) return BidAvailability.SignedOut
        val amount = parseBidDollars(bidText) ?: return BidAvailability.AmountNotANumber
        val minimum = minimumNextBid(auction.currentPriceCents)
        if (amount < minimum) return BidAvailability.BelowMinimum(minimum)
        return BidAvailability.Ready(amount)
    }

    fun bidAvailabilityMessage(availability: BidAvailability): String? =
        when (availability) {
            is BidAvailability.Ready -> {
                null
            }

            BidAvailability.NoAuction -> {
                "Nothing is up for auction right now."
            }

            BidAvailability.AuctionClosed -> {
                "This auction has closed."
            }

            BidAvailability.SignedOut -> {
                "Sign in to bid."
            }

            BidAvailability.AmountNotANumber -> {
                "Enter an amount like 24.50."
            }

            is BidAvailability.BelowMinimum -> {
                "Bid at least ${formatPrice(availability.minimumCents)}."
            }

            BidAvailability.Submitting -> {
                "Placing your bid…"
            }
        }
}
