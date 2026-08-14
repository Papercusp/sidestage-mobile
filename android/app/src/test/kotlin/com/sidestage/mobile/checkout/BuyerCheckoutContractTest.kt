// SPDX-License-Identifier: MIT
package com.sidestage.mobile.checkout

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BuyerCheckoutContractTest {
    @Test
    fun `address validation mirrors the Buyer web contract`() {
        val missing = BuyerCheckoutPresentation.missingAddressFields(CheckoutAddressDraft(email = "buyer@example.com"))

        assertEquals(
            setOf(
                CheckoutAddressField.NAME,
                CheckoutAddressField.LINE1,
                CheckoutAddressField.CITY,
                CheckoutAddressField.STATE,
                CheckoutAddressField.POSTAL_CODE,
            ),
            missing,
        )
    }

    @Test
    fun `address normalization trims fields and collapses blank optionals`() {
        val normalized =
            BuyerCheckoutPresentation.normalize(
                completeAddress().copy(
                    email = " buyer@example.com ",
                    line2 = "  ",
                    country = " ",
                    phone = "  ",
                ),
            )

        assertEquals("buyer@example.com", normalized?.email)
        assertEquals("US", normalized?.country)
        assertNull(normalized?.line2)
        assertNull(normalized?.phone)
    }

    @Test
    fun `shipping preview is local but payment receipt uses the server order total`() =
        runBlocking {
            val gateway = FakeCheckoutGateway()
            val session = BuyerSessionState().apply { cartId = "cart-1" }
            val controller = BuyerCheckoutController("event-1", CheckoutStep.CART, gateway, session)

            controller.loadCart()
            controller.continueFromCart()
            controller.updateDraft(completeAddress())
            controller.findShippingRates()

            assertEquals(2_895L, controller.previewTotalCents)
            assertEquals(CheckoutStep.SHIPPING, controller.state.step)

            controller.startCheckout()
            assertEquals(3_000L, controller.orderTotalCents)
            assertEquals(CheckoutStep.PAYMENT, controller.state.step)

            controller.confirmPayment()
            assertEquals(3_000L, controller.orderTotalCents)
            assertEquals(CheckoutStep.SUCCESS, controller.state.step)
            assertNull(session.cartId)
        }

    @Test
    fun `payment remains incomplete unless both Square and the order are paid`() =
        runBlocking {
            val gateway = FakeCheckoutGateway(paymentStatus = "paid", orderStatus = "pending")
            val session = BuyerSessionState().apply { cartId = "cart-1" }
            val controller = checkoutReadyController(gateway, session)

            controller.confirmPayment()

            assertEquals(CheckoutStep.PAYMENT, controller.state.step)
            assertEquals(BuyerCheckoutPresentation.PAYMENT_DID_NOT_COMPLETE_MESSAGE, controller.state.errorMessage)
            assertEquals("cart-1", session.cartId)
        }

    @Test
    fun `one-day delivery is singular and unknown estimates are explicit`() {
        assertEquals("1 day delivery", BuyerCheckoutPresentation.deliveryEstimate(1))
        assertEquals("2 day delivery", BuyerCheckoutPresentation.deliveryEstimate(2))
        assertEquals("Delivery estimate unavailable", BuyerCheckoutPresentation.deliveryEstimate(null))
    }

    @Test
    fun `conflict errors tell the buyer to review the cart`() {
        val message = BuyerCheckoutPresentation.errorMessage(BuyerCheckoutGatewayException(status = 409), "fallback")

        assertTrue(message.contains("cart changed"))
    }

    @Test
    fun `expired cart hold is cleared after the server confirms the cart is empty`() =
        runBlocking {
            val gateway = FakeCheckoutGateway(expireBeforeShippingRates = true)
            val session = BuyerSessionState().apply { cartId = "cart-1" }
            val controller = BuyerCheckoutController("event-1", CheckoutStep.CART, gateway, session)

            controller.loadCart()
            controller.continueFromCart()
            controller.updateDraft(completeAddress())
            controller.findShippingRates()

            assertEquals(CheckoutStep.CART, controller.state.step)
            assertNull(controller.state.cart)
            assertNull(session.cartId)
            assertEquals(BuyerCheckoutPresentation.CART_HOLD_EXPIRED_MESSAGE, controller.state.errorMessage)
        }

    @Test
    fun `a different shipping validation error does not discard a live cart`() =
        runBlocking {
            val gateway = FakeCheckoutGateway(rejectShippingRates = true)
            val session = BuyerSessionState().apply { cartId = "cart-1" }
            val controller = BuyerCheckoutController("event-1", CheckoutStep.CART, gateway, session)

            controller.loadCart()
            controller.continueFromCart()
            controller.updateDraft(completeAddress())
            controller.findShippingRates()

            assertEquals(CheckoutStep.ADDRESS, controller.state.step)
            assertEquals("cart-1", controller.state.cart?.id)
            assertEquals("cart-1", session.cartId)
            assertEquals("Checkout could not be completed.", controller.state.errorMessage)
        }

    private fun completeAddress() =
        CheckoutAddressDraft(
            email = "buyer@example.com",
            name = "Avi Buyer",
            line1 = "123 Main St",
            city = "Brooklyn",
            state = "NY",
            postalCode = "11201",
        )

    private suspend fun checkoutReadyController(
        gateway: FakeCheckoutGateway,
        session: BuyerSessionState,
    ): BuyerCheckoutController =
        BuyerCheckoutController("event-1", CheckoutStep.CART, gateway, session).apply {
            loadCart()
            continueFromCart()
            updateDraft(completeAddress())
            findShippingRates()
            startCheckout()
        }
}

private class FakeCheckoutGateway(
    private val paymentStatus: String = "paid",
    private val orderStatus: String = "paid",
    private val expireBeforeShippingRates: Boolean = false,
    private val rejectShippingRates: Boolean = false,
) : BuyerCheckoutGateway {
    override val maxCartQuantity = 99
    private var cart =
        BuyerCart(
            id = "cart-1",
            items = listOf(BuyerCartItem("product-1", "Vintage jacket", 2_000L, 1, null)),
            subtotalCents = 2_000L,
        )

    override suspend fun cart(cartId: String): BuyerCart =
        if (expireBeforeShippingRates && shippingRatesRequested) {
            cart.copy(items = emptyList(), subtotalCents = 0L)
        } else {
            cart
        }

    override suspend fun setCartQuantity(
        cartId: String,
        productId: String,
        quantity: Int,
    ): BuyerCart {
        cart = cart.copy(items = cart.items.map { it.copy(quantity = quantity) }, subtotalCents = 2_000L * quantity)
        return cart
    }

    override suspend fun removeCartItem(
        cartId: String,
        productId: String,
    ): BuyerCart {
        cart = cart.copy(items = emptyList(), subtotalCents = 0L)
        return cart
    }

    override suspend fun shippingRates(
        cartId: String,
        address: CheckoutAddress,
    ): List<BuyerShippingRate> {
        shippingRatesRequested = true
        if (expireBeforeShippingRates || rejectShippingRates) throw BuyerCheckoutGatewayException(status = 400)
        return listOf(BuyerShippingRate("rate-1", "USPS", "Priority", 895L, 2))
    }

    override suspend fun createCheckoutSession(
        cartId: String,
        eventId: String,
        address: CheckoutAddress,
        shippingRateId: String,
    ): BuyerCheckoutSession = BuyerCheckoutSession(serverOrder("pending"), status = "ready")

    override suspend fun confirmCheckout(
        orderId: String,
        sourceId: String,
    ): BuyerCheckoutConfirmation = BuyerCheckoutConfirmation(serverOrder(orderStatus), paymentStatus = paymentStatus, paymentError = null)

    private fun serverOrder(status: String) =
        BuyerCheckoutOrder(
            id = "order-1",
            subtotalCents = 2_000L,
            shippingCents = 1_000L,
            totalCents = 3_000L,
            status = status,
        )

    private var shippingRatesRequested = false
}
