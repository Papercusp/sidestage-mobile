// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import com.sidestage.mobile.BuildConfig
import com.sidestage.mobile.checkout.BuyerCart
import com.sidestage.mobile.checkout.BuyerCartItem
import com.sidestage.mobile.checkout.BuyerCheckoutConfirmation
import com.sidestage.mobile.checkout.BuyerCheckoutGateway
import com.sidestage.mobile.checkout.BuyerCheckoutGatewayException
import com.sidestage.mobile.checkout.BuyerCheckoutOrder
import com.sidestage.mobile.checkout.BuyerCheckoutSession
import com.sidestage.mobile.checkout.BuyerSessionState
import com.sidestage.mobile.checkout.BuyerShippingRate
import com.sidestage.mobile.checkout.CheckoutAddress
import com.sidestage.mobile.orders.BuyerOrder
import com.sidestage.mobile.orders.BuyerOrderLine
import com.sidestage.mobile.orders.BuyerOrdersGateway
import uniffi.sidestage.AddCartItemRequest
import uniffi.sidestage.ApiException
import uniffi.sidestage.ApiSession
import uniffi.sidestage.AuctionStatus
import uniffi.sidestage.ConfirmCheckoutRequest
import uniffi.sidestage.CreateCheckoutSessionRequest
import uniffi.sidestage.LiveEventSync
import uniffi.sidestage.LiveEventUpdate
import uniffi.sidestage.LiveSyncStatus
import uniffi.sidestage.OrderStatus
import uniffi.sidestage.PlaceBidRequest
import uniffi.sidestage.ShippingAddress
import uniffi.sidestage.ShippingRatesRequest
import uniffi.sidestage.SideStageClient
import uniffi.sidestage.maxCartQuantity
import uniffi.sidestage.minimumNextBidCents as ffiMinimumNextBidCents
import uniffi.sidestage.suggestedBidCents as ffiSuggestedBidCents

object SideStageClientFactory {
    /**
     * The one client every Buyer surface shares. Built once so the live room
     * and search + browse hold the same session and the same connection pool
     * instead of each opening its own against the API.
     */
    private val client: SideStageClient? by lazy {
        runCatching {
            val client = SideStageClient(BuildConfig.SIDESTAGE_API_BASE_URL)
            client.setSession(
                ApiSession(
                    buyerId = BuildConfig.SIDESTAGE_BUYER_ID,
                    accessToken = null,
                ),
            )
            client
        }.getOrNull()
    }

    val buyerSession = BuyerSessionState()

    val shared: LiveEventGateway? by lazy { client?.let { UniFfiLiveEventGateway(it, buyerSession) } }

    val checkoutGateway: BuyerCheckoutGateway? by lazy { client?.let(::UniFfiBuyerCheckoutGateway) }

    /** Buyer search + browse reads events and the catalog through that client. */
    val catalogSource: BuyerCatalogSource? by lazy { client?.let(::ClientBuyerCatalogSource) }

    /** Buyer history uses the same session-bound client as checkout. */
    val ordersGateway: BuyerOrdersGateway? by lazy {
        client?.let { UniFfiBuyerOrdersGateway(it, BuildConfig.SIDESTAGE_BUYER_ID) }
    }

    fun streamUrl(eventId: String): String = LiveEventPresentation.streamUrl(BuildConfig.SIDESTAGE_MEDIA_BASE_URL, eventId)
}

internal class UniFfiLiveEventGateway(
    private val client: SideStageClient,
    private val buyerSession: BuyerSessionState,
) : LiveEventGateway {
    override val buyerId: String?
        get() = client.session()?.buyerId

    override suspend fun event(eventId: String): LiveEventHeader =
        ffiCall {
            val event = client.event(eventId)
            LiveEventHeader(
                title = event.title,
                viewers = event.viewers,
                thumbnailUrl = event.thumbnailUrl,
            )
        }

    override fun liveEventSync(eventId: String): LiveRoomSubscription =
        try {
            UniFfiLiveRoomSubscription(client.liveEventSync(eventId))
        } catch (error: ApiException) {
            throw error.asGatewayException()
        }

    override suspend fun placeBid(
        auctionId: String,
        bidderId: String,
        amountCents: Long,
    ): LiveAuctionState =
        ffiCall {
            client
                .placeBid(
                    PlaceBidRequest(
                        auctionId = auctionId,
                        bidderId = bidderId,
                        displayName = null,
                        amountCents = amountCents,
                    ),
                ).toAppModel()
        }

    override suspend fun addCartItem(
        cartId: String?,
        product: LiveProduct,
    ): LiveCartResult =
        ffiCall {
            val cart =
                client.addCartItem(
                    AddCartItemRequest(
                        cartId = cartId ?: buyerSession.cartId,
                        productId = product.id,
                        title = product.title,
                        priceCents = product.priceCents,
                        quantity = 1u,
                        imageUrl = product.imageUrl,
                    ),
                )
            buyerSession.cartId = cart.id
            LiveCartResult(
                id = cart.id,
                itemCount = cart.items.sumOf { it.quantity.toInt() },
            )
        }

    override fun suggestedBidCents(currentPriceCents: Long): Long = ffiSuggestedBidCents(currentPriceCents)

    override fun minimumNextBidCents(currentPriceCents: Long): Long = ffiMinimumNextBidCents(currentPriceCents)
}

private class UniFfiBuyerCheckoutGateway(
    private val client: SideStageClient,
) : BuyerCheckoutGateway {
    override val maxCartQuantity: Int = maxCartQuantity().toInt()

    override suspend fun cart(cartId: String): BuyerCart? = checkoutCall { client.cart(cartId)?.toBuyerCart() }

    override suspend fun setCartQuantity(
        cartId: String,
        productId: String,
        quantity: Int,
    ): BuyerCart = checkoutCall { client.setCartQuantity(cartId, productId, quantity.toUInt()).toBuyerCart() }

    override suspend fun removeCartItem(
        cartId: String,
        productId: String,
    ): BuyerCart = checkoutCall { client.removeCartItem(cartId, productId).toBuyerCart() }

    override suspend fun shippingRates(
        cartId: String,
        address: CheckoutAddress,
    ): List<BuyerShippingRate> =
        checkoutCall {
            client
                .shippingRates(
                    ShippingRatesRequest(
                        cartId = cartId,
                        address = address.toFfiAddress(),
                    ),
                ).map { it.toBuyerRate() }
        }

    override suspend fun createCheckoutSession(
        cartId: String,
        eventId: String,
        address: CheckoutAddress,
        shippingRateId: String,
    ): BuyerCheckoutSession =
        checkoutCall {
            client
                .createCheckoutSession(
                    CreateCheckoutSessionRequest(
                        cartId = cartId,
                        eventId = eventId,
                        email = address.email,
                        name = address.name,
                        shippingAddress = address.toFfiAddress(),
                        shippingRateId = shippingRateId,
                    ),
                ).let { BuyerCheckoutSession(order = it.order.toBuyerCheckoutOrder(), status = it.session.status) }
        }

    override suspend fun confirmCheckout(
        orderId: String,
        sourceId: String,
    ): BuyerCheckoutConfirmation =
        checkoutCall {
            client
                .confirmCheckout(ConfirmCheckoutRequest(orderId = orderId, sourceId = sourceId))
                .let {
                    BuyerCheckoutConfirmation(
                        order = it.order.toBuyerCheckoutOrder(),
                        paymentStatus = it.payment.status,
                        paymentError = it.payment.errorMessage,
                    )
                }
        }
}

private fun uniffi.sidestage.Cart.toBuyerCart(): BuyerCart =
    BuyerCart(
        id = id,
        items =
            items.map {
                BuyerCartItem(
                    productId = it.productId,
                    title = it.title,
                    priceCents = it.priceCents,
                    quantity = it.quantity.toInt(),
                    imageUrl = it.imageUrl,
                )
            },
        subtotalCents = subtotalCents,
    )

private fun CheckoutAddress.toFfiAddress(): ShippingAddress =
    ShippingAddress(
        name = name,
        line1 = line1,
        line2 = line2,
        city = city,
        state = state,
        postalCode = postalCode,
        country = country,
        phone = phone,
    )

private fun uniffi.sidestage.ShippingRate.toBuyerRate(): BuyerShippingRate =
    BuyerShippingRate(
        id = id,
        carrier = carrier,
        service = service,
        totalCents = totalCents,
        deliveryDays = deliveryDays?.toInt(),
    )

private class UniFfiBuyerOrdersGateway(
    private val client: SideStageClient,
    override val buyerId: String,
) : BuyerOrdersGateway {
    override suspend fun orders(): List<BuyerOrder> =
        try {
            client.orderHistory().map { it.toBuyerHistoryOrder() }
        } catch (error: ApiException) {
            throw IllegalStateException("Orders are unavailable right now.", error)
        }
}

private fun uniffi.sidestage.CheckoutOrder.toBuyerCheckoutOrder(): BuyerCheckoutOrder =
    BuyerCheckoutOrder(
        id = id,
        subtotalCents = subtotalCents,
        shippingCents = shippingCents,
        totalCents = totalCents,
        status = status,
    )

internal fun uniffi.sidestage.Order.toBuyerHistoryOrder(): BuyerOrder =
    BuyerOrder(
        id = id,
        buyerId = buyerId,
        eventId = eventId,
        createdAt = createdAt,
        status = status.toApiValue(),
        subtotalCents = subtotalCents,
        shippingCents = shippingCents,
        totalCents = totalCents,
        items =
            items.map {
                BuyerOrderLine(
                    productId = it.productId,
                    title = it.title,
                    priceCents = it.unitPriceCents,
                    quantity = it.quantity.toInt(),
                )
            },
        shippingService = null,
        shippingAddress = null,
    )

private fun OrderStatus.toApiValue(): String =
    when (this) {
        OrderStatus.PENDING -> "pending"
        OrderStatus.PAID -> "paid"
        OrderStatus.FAILED -> "failed"
        OrderStatus.ACCEPTED -> "accepted"
        OrderStatus.EXPIRED -> "expired"
        OrderStatus.CANCELLED -> "cancelled"
    }

private suspend fun <T> checkoutCall(block: suspend () -> T): T =
    try {
        block()
    } catch (error: ApiException) {
        throw BuyerCheckoutGatewayException(
            status = (error as? ApiException.Http)?.status?.toInt(),
            cause = error,
        )
    }

private class UniFfiLiveRoomSubscription(
    private val sync: LiveEventSync,
) : LiveRoomSubscription {
    override suspend fun next(): LiveRoomUpdate? =
        try {
            when (val update = sync.nextEvent()) {
                null -> {
                    null
                }

                is LiveEventUpdate.Status -> {
                    when (val status = update.status) {
                        LiveSyncStatus.Connecting -> {
                            LiveRoomUpdate.Status(LiveConnectionState.CONNECTING)
                        }

                        LiveSyncStatus.Live -> {
                            LiveRoomUpdate.Status(LiveConnectionState.LIVE)
                        }

                        is LiveSyncStatus.Polling -> {
                            LiveRoomUpdate.Status(
                                state = LiveConnectionState.POLLING,
                                retryInMs = status.retryInMs,
                            )
                        }
                    }
                }

                is LiveEventUpdate.Snapshot -> {
                    LiveRoomUpdate.Snapshot(update.snapshot.toAppModel())
                }

                is LiveEventUpdate.Error -> {
                    LiveRoomUpdate.Error(update.message)
                }
            }
        } catch (error: ApiException) {
            throw error.asGatewayException()
        }

    override fun close() {
        sync.stop()
        sync.destroy()
    }
}

private fun uniffi.sidestage.LiveEventSnapshot.toAppModel(): LiveRoomSnapshot =
    LiveRoomSnapshot(
        transcript =
            transcript.map {
                LiveTranscriptEntry(
                    displayName = it.displayName,
                    text = it.text,
                )
            },
        onDeckProduct = onDeckProduct?.toAppModel(),
        auction = auction?.toAppModel(),
    )

private fun uniffi.sidestage.CatalogVariant.toAppModel(): LiveProduct =
    LiveProduct(
        id = id,
        title = title,
        brand = brand,
        condition = condition,
        priceCents = priceCents,
        availableQuantity = availableQty,
        imageUrl = imageUrl,
    )

private fun uniffi.sidestage.LiveAuction.toAppModel(): LiveAuctionState =
    LiveAuctionState(
        id = id,
        currentPriceCents = currentPriceCents,
        status =
            when (status) {
                AuctionStatus.ACTIVE -> LiveAuctionStatus.ACTIVE
                AuctionStatus.CLOSED -> LiveAuctionStatus.CLOSED
            },
        endsAt = endsAt,
        bids =
            bids.map {
                LiveBid(
                    bidderId = it.bidderId,
                    displayName = it.displayName,
                    amountCents = it.amountCents,
                )
            },
    )

private suspend fun <T> ffiCall(block: suspend () -> T): T =
    try {
        block()
    } catch (error: ApiException) {
        throw error.asGatewayException()
    }

private fun ApiException.asGatewayException(): LiveEventGatewayException =
    LiveEventGatewayException(
        status = (this as? ApiException.Http)?.status?.toInt(),
        cause = this,
    )
