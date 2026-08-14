// SPDX-License-Identifier: MIT
package com.sidestage.mobile.checkout

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.sidestage.mobile.buyer.LiveEventPresentation

data class BuyerCartItem(
    val productId: String,
    val title: String,
    val priceCents: Long,
    val quantity: Int,
    val imageUrl: String?,
)

data class BuyerCart(
    val id: String,
    val items: List<BuyerCartItem>,
    val subtotalCents: Long,
)

data class CheckoutAddressDraft(
    val email: String = "",
    val name: String = "",
    val line1: String = "",
    val line2: String = "",
    val city: String = "",
    val state: String = "",
    val postalCode: String = "",
    val country: String = "US",
    val phone: String = "",
)

enum class CheckoutAddressField {
    EMAIL,
    NAME,
    LINE1,
    CITY,
    STATE,
    POSTAL_CODE,
}

data class CheckoutAddress(
    val email: String,
    val name: String,
    val line1: String,
    val line2: String?,
    val city: String,
    val state: String,
    val postalCode: String,
    val country: String,
    val phone: String?,
)

data class BuyerShippingRate(
    val id: String,
    val carrier: String,
    val service: String,
    val totalCents: Long,
    val deliveryDays: Int?,
)

data class BuyerCheckoutOrder(
    val id: String,
    val subtotalCents: Long,
    val shippingCents: Long,
    val totalCents: Long,
    val status: String,
)

data class BuyerCheckoutSession(
    val order: BuyerCheckoutOrder,
    val status: String,
)

data class BuyerCheckoutConfirmation(
    val order: BuyerCheckoutOrder,
    val paymentStatus: String,
    val paymentError: String?,
)

interface BuyerCheckoutGateway {
    val maxCartQuantity: Int

    suspend fun cart(cartId: String): BuyerCart?

    suspend fun setCartQuantity(
        cartId: String,
        productId: String,
        quantity: Int,
    ): BuyerCart

    suspend fun removeCartItem(
        cartId: String,
        productId: String,
    ): BuyerCart

    suspend fun shippingRates(
        cartId: String,
        address: CheckoutAddress,
    ): List<BuyerShippingRate>

    suspend fun createCheckoutSession(
        cartId: String,
        eventId: String,
        address: CheckoutAddress,
        shippingRateId: String,
    ): BuyerCheckoutSession

    suspend fun confirmCheckout(
        orderId: String,
        sourceId: String,
    ): BuyerCheckoutConfirmation
}

class BuyerCheckoutGatewayException(
    val status: Int? = null,
    cause: Throwable? = null,
) : Exception(cause)

class BuyerSessionState {
    var cartId by mutableStateOf<String?>(null)
}

enum class CheckoutStep {
    CART,
    ADDRESS,
    SHIPPING,
    PAYMENT,
    SUCCESS,
    ;

    val title: String
        get() =
            when (this) {
                CART -> "Your cart"
                ADDRESS -> "Where should it go?"
                SHIPPING -> "Choose shipping"
                PAYMENT -> "Square sandbox"
                SUCCESS -> "Order confirmed"
            }

    val previous: CheckoutStep?
        get() =
            when (this) {
                CART -> null
                ADDRESS -> CART
                SHIPPING -> ADDRESS
                PAYMENT -> SHIPPING
                SUCCESS -> null
            }
}

data class BuyerCheckoutUiState(
    val step: CheckoutStep,
    val cart: BuyerCart? = null,
    val draft: CheckoutAddressDraft = CheckoutAddressDraft(),
    val missingFields: Set<CheckoutAddressField> = emptySet(),
    val rates: List<BuyerShippingRate> = emptyList(),
    val selectedRateId: String? = null,
    val checkout: BuyerCheckoutSession? = null,
    val completedOrder: BuyerCheckoutOrder? = null,
    val isBusy: Boolean = false,
    val errorMessage: String? = null,
)

object BuyerCheckoutPresentation {
    const val INCOMPLETE_ADDRESS_MESSAGE = "Email, name, and a complete shipping address are required."
    const val CART_HOLD_EXPIRED_MESSAGE = "Your cart hold expired. Add the item again to continue checkout."
    const val NO_RATES_MESSAGE = "No live shipping rates are available for this address."
    const val SQUARE_NEEDS_CONFIGURATION_TITLE = "Square sandbox needs configuration."
    const val SQUARE_NEEDS_CONFIGURATION_DETAIL =
        "Set the server-side Square sandbox credentials to enable tokenized card checkout."
    const val PAYMENT_DID_NOT_COMPLETE_MESSAGE = "Square did not complete the payment."

    fun missingAddressFields(draft: CheckoutAddressDraft): Set<CheckoutAddressField> =
        buildSet {
            if (draft.email.isBlank()) add(CheckoutAddressField.EMAIL)
            if (draft.name.isBlank()) add(CheckoutAddressField.NAME)
            if (draft.line1.isBlank()) add(CheckoutAddressField.LINE1)
            if (draft.city.isBlank()) add(CheckoutAddressField.CITY)
            if (draft.state.isBlank()) add(CheckoutAddressField.STATE)
            if (draft.postalCode.isBlank()) add(CheckoutAddressField.POSTAL_CODE)
        }

    fun normalize(draft: CheckoutAddressDraft): CheckoutAddress? {
        if (missingAddressFields(draft).isNotEmpty()) return null
        return CheckoutAddress(
            email = draft.email.trim(),
            name = draft.name.trim(),
            line1 = draft.line1.trim(),
            line2 = draft.line2.trim().ifEmpty { null },
            city = draft.city.trim(),
            state = draft.state.trim(),
            postalCode = draft.postalCode.trim(),
            country = draft.country.trim().ifEmpty { "US" },
            phone = draft.phone.trim().ifEmpty { null },
        )
    }

    fun formatPrice(cents: Long): String = LiveEventPresentation.formatPrice(cents)

    fun previewTotalCents(
        subtotalCents: Long,
        selectedRateCents: Long?,
    ): Long = subtotalCents + (selectedRateCents ?: 0L)

    fun rateTitle(rate: BuyerShippingRate): String =
        listOf(rate.carrier.trim(), rate.service.trim()).filter(String::isNotEmpty).joinToString(" ").ifEmpty { "Shipping" }

    fun deliveryEstimate(days: Int?): String =
        when (days) {
            null -> "Delivery estimate unavailable"
            1 -> "1 day delivery"
            else -> "$days day delivery"
        }

    fun receiptMessage(orderId: String): String = "Order $orderId is paid and ready for fulfillment."

    fun errorMessage(
        error: Throwable,
        fallback: String,
    ): String =
        when ((error as? BuyerCheckoutGatewayException)?.status) {
            409 -> "Something in your cart changed. Review it and try again."
            401, 403 -> "Sign in again to complete checkout."
            null -> if (error is BuyerCheckoutGatewayException) "You're offline. Nothing was charged." else fallback
            else -> fallback
        }
}

class BuyerCheckoutController(
    private val eventId: String,
    initialStep: CheckoutStep,
    private val gateway: BuyerCheckoutGateway?,
    private val session: BuyerSessionState,
) {
    var state by mutableStateOf(BuyerCheckoutUiState(step = initialStep))
        private set

    val selectedRate: BuyerShippingRate?
        get() = state.rates.firstOrNull { it.id == state.selectedRateId }

    val previewTotalCents: Long
        get() =
            BuyerCheckoutPresentation.previewTotalCents(
                subtotalCents = state.cart?.subtotalCents ?: 0L,
                selectedRateCents = selectedRate?.totalCents,
            )

    val orderTotalCents: Long?
        get() = state.completedOrder?.totalCents ?: state.checkout?.order?.totalCents

    val needsSquareConfiguration: Boolean
        get() = state.checkout?.status == "needs-configuration"

    suspend fun loadCart() {
        val activeGateway = gateway ?: return fail("The shared SideStage core is unavailable.")
        val cartId = session.cartId ?: return stateUpdate(cart = null)
        busy {
            val cart = activeGateway.cart(cartId)
            if (cart == null) session.cartId = null
            stateUpdate(cart = cart)
            if (cart == null || cart.items.isEmpty()) goTo(CheckoutStep.CART)
        }
    }

    fun updateDraft(draft: CheckoutAddressDraft) {
        val missing = BuyerCheckoutPresentation.missingAddressFields(draft)
        state = state.copy(draft = draft, missingFields = state.missingFields.intersect(missing), errorMessage = null)
    }

    fun selectRate(rateId: String) {
        state = state.copy(selectedRateId = rateId, errorMessage = null)
    }

    fun continueFromCart() {
        if (state.cart?.items.isNullOrEmpty()) {
            fail("Your cart is empty.")
        } else {
            goTo(CheckoutStep.ADDRESS)
        }
    }

    fun goBack(): Boolean {
        val previous = state.step.previous ?: return false
        goTo(previous)
        return true
    }

    suspend fun setQuantity(
        item: BuyerCartItem,
        quantity: Int,
    ) {
        val activeGateway = gateway ?: return fail("The shared SideStage core is unavailable.")
        val cartId = state.cart?.id ?: return
        if (quantity !in 1..activeGateway.maxCartQuantity) return
        busy { stateUpdate(cart = activeGateway.setCartQuantity(cartId, item.productId, quantity)) }
    }

    suspend fun removeItem(item: BuyerCartItem) {
        val activeGateway = gateway ?: return fail("The shared SideStage core is unavailable.")
        val cartId = state.cart?.id ?: return
        busy { stateUpdate(cart = activeGateway.removeCartItem(cartId, item.productId)) }
    }

    suspend fun findShippingRates() {
        val activeGateway = gateway ?: return fail("The shared SideStage core is unavailable.")
        val missing = BuyerCheckoutPresentation.missingAddressFields(state.draft)
        val address = BuyerCheckoutPresentation.normalize(state.draft)
        if (address == null) {
            state = state.copy(missingFields = missing, errorMessage = BuyerCheckoutPresentation.INCOMPLETE_ADDRESS_MESSAGE)
            return
        }
        val cart = state.cart
        if (cart == null || cart.items.isEmpty()) return fail("Your cart is empty.")
        busy {
            val rates =
                try {
                    activeGateway.shippingRates(cart.id, address)
                } catch (error: BuyerCheckoutGatewayException) {
                    if (recoverExpiredCart(activeGateway, cart, error)) return@busy
                    throw error
                }
            val prior = state.selectedRateId?.takeIf { id -> rates.any { it.id == id } }
            state = state.copy(rates = rates, selectedRateId = prior ?: rates.firstOrNull()?.id)
            goTo(CheckoutStep.SHIPPING)
        }
    }

    suspend fun startCheckout() {
        val activeGateway = gateway ?: return fail("The shared SideStage core is unavailable.")
        val cart = state.cart ?: return fail("Your cart is empty.")
        val address =
            BuyerCheckoutPresentation.normalize(state.draft)
                ?: return fail(BuyerCheckoutPresentation.INCOMPLETE_ADDRESS_MESSAGE)
        val rate = selectedRate ?: return fail("Choose a shipping rate.")
        busy {
            val checkout = activeGateway.createCheckoutSession(cart.id, eventId, address, rate.id)
            state = state.copy(checkout = checkout, completedOrder = null)
            goTo(CheckoutStep.PAYMENT)
        }
    }

    suspend fun confirmPayment() {
        val activeGateway = gateway ?: return fail("The shared SideStage core is unavailable.")
        val orderId = state.checkout?.order?.id ?: return
        busy {
            val confirmation = activeGateway.confirmCheckout(orderId, SANDBOX_SOURCE_ID)
            if (confirmation.paymentStatus != "paid" || confirmation.order.status != "paid") {
                fail(confirmation.paymentError ?: BuyerCheckoutPresentation.PAYMENT_DID_NOT_COMPLETE_MESSAGE)
                return@busy
            }
            session.cartId = null
            state = state.copy(completedOrder = confirmation.order, cart = null)
            goTo(CheckoutStep.SUCCESS)
        }
    }

    private fun goTo(step: CheckoutStep) {
        state = state.copy(step = step, errorMessage = null)
    }

    private suspend fun busy(block: suspend () -> Unit) {
        state = state.copy(isBusy = true, errorMessage = null)
        try {
            block()
        } catch (error: Exception) {
            fail(BuyerCheckoutPresentation.errorMessage(error, "Checkout could not be completed."))
        } finally {
            state = state.copy(isBusy = false)
        }
    }

    private fun stateUpdate(cart: BuyerCart?) {
        state = state.copy(cart = cart, errorMessage = null)
    }

    private suspend fun recoverExpiredCart(
        activeGateway: BuyerCheckoutGateway,
        cart: BuyerCart,
        error: BuyerCheckoutGatewayException,
    ): Boolean {
        if (error.status != 400) return false
        val refreshed =
            try {
                activeGateway.cart(cart.id)
            } catch (_: Exception) {
                return false
            }
        if (refreshed != null && refreshed.items.isNotEmpty()) return false

        session.cartId = null
        state =
            state.copy(
                step = CheckoutStep.CART,
                cart = null,
                rates = emptyList(),
                selectedRateId = null,
                checkout = null,
                completedOrder = null,
                errorMessage = BuyerCheckoutPresentation.CART_HOLD_EXPIRED_MESSAGE,
            )
        return true
    }

    private fun fail(message: String) {
        state = state.copy(errorMessage = message)
    }

    companion object {
        const val SANDBOX_SOURCE_ID = "cnon:card-nonce-ok"
    }
}
