// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class LiveEventContractTest {
    private val activeAuction =
        LiveAuctionState(
            id = "auction-1",
            currentPriceCents = 2_500,
            status = LiveAuctionStatus.ACTIVE,
            endsAt = "2026-08-14T15:02:03Z",
            bids = emptyList(),
        )

    @Test
    fun `bid parser accepts the same strict dollar shape as web`() {
        assertEquals(2_450L, LiveEventPresentation.parseBidDollars("24.50"))
        assertEquals(2_400L, LiveEventPresentation.parseBidDollars(" 24 "))
        assertNull(LiveEventPresentation.parseBidDollars("$24.50"))
        assertNull(LiveEventPresentation.parseBidDollars("24.500"))
    }

    @Test
    fun `bid availability uses the minimum supplied by shared core`() {
        val result =
            LiveEventPresentation.bidAvailability(
                auction = activeAuction,
                bidText = "25.00",
                buyerId = "buyer-1",
                isSubmitting = false,
                minimumNextBid = { 2_501L },
            )

        assertEquals(BidAvailability.BelowMinimum(2_501L), result)
    }

    @Test
    fun `bid becomes ready only after clearing the core minimum`() {
        val result =
            LiveEventPresentation.bidAvailability(
                auction = activeAuction,
                bidText = "26.00",
                buyerId = "buyer-1",
                isSubmitting = false,
                minimumNextBid = { 2_501L },
            )

        assertEquals(BidAvailability.Ready(2_600L), result)
    }

    @Test
    fun `closed auction never accepts a bid`() {
        val result =
            LiveEventPresentation.bidAvailability(
                auction = activeAuction.copy(status = LiveAuctionStatus.CLOSED),
                bidText = "26.00",
                buyerId = "buyer-1",
                isSubmitting = false,
                minimumNextBid = { 2_501L },
            )

        assertEquals(BidAvailability.AuctionClosed, result)
    }

    @Test
    fun `countdown rounds a partial second up like web`() {
        assertEquals(
            63L,
            LiveEventPresentation.secondsRemaining(
                endsAt = "2026-08-14T15:01:02.001Z",
                now = Instant.parse("2026-08-14T15:00:00Z"),
            ),
        )
        assertEquals("1:03", LiveEventPresentation.formatCountdown(63L))
    }

    @Test
    fun `polling status tells the buyer the core is still reconnecting`() {
        assertEquals(
            "Reconnecting in 2s",
            LiveEventPresentation.connectionLabel(LiveConnectionState.POLLING, 1_001uL),
        )
    }

    @Test
    fun `price formatting remains cents exact`() {
        assertEquals("$6,230.57", LiveEventPresentation.formatPrice(623_057L))
        assertTrue(LiveEventPresentation.bidFieldText(2_600L) == "26")
    }
}
