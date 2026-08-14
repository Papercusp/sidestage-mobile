// SPDX-License-Identifier: MIT
@file:Suppress("ktlint:standard:function-naming")

package com.sidestage.mobile.checkout

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.sidestage.mobile.theme.SideStageTokens
import kotlinx.coroutines.launch

@Composable
fun BuyerCheckoutScreen(
    eventId: String,
    initialStep: CheckoutStep,
    gateway: BuyerCheckoutGateway?,
    session: BuyerSessionState,
    contentPadding: PaddingValues,
) {
    val controller =
        remember(eventId, initialStep, gateway, session) {
            BuyerCheckoutController(eventId, initialStep, gateway, session)
        }
    val state = controller.state
    val scope = rememberCoroutineScope()
    val launch: (suspend () -> Unit) -> Unit = { block -> scope.launch { block() } }

    LaunchedEffect(controller) { controller.loadCart() }
    BackHandler(enabled = state.step.previous != null) { controller.goBack() }

    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(contentPadding)
                .padding(horizontal = 20.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Buyer checkout", color = SideStageTokens.Accent, style = MaterialTheme.typography.labelLarge)
        Text(state.step.title, style = MaterialTheme.typography.headlineMedium)
        CheckoutProgress(state.step)

        when (state.step) {
            CheckoutStep.CART -> CartStep(state, controller, launch)
            CheckoutStep.ADDRESS -> AddressStep(state, controller, launch)
            CheckoutStep.SHIPPING -> ShippingStep(state, controller, launch)
            CheckoutStep.PAYMENT -> PaymentStep(state, controller, launch)
            CheckoutStep.SUCCESS -> SuccessStep(state, controller.orderTotalCents)
        }

        state.errorMessage?.let { CheckoutError(it) }
    }
}

@Composable
private fun CheckoutProgress(step: CheckoutStep) {
    val steps = CheckoutStep.entries.filter { it != CheckoutStep.SUCCESS }
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        steps.forEachIndexed { index, value ->
            Surface(
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(999.dp),
                color = if (value.ordinal <= step.ordinal) SideStageTokens.Accent else SideStageTokens.Border,
            ) {
                Text(
                    text = "${index + 1}",
                    modifier = Modifier.padding(vertical = 4.dp),
                    color = if (value.ordinal <= step.ordinal) SideStageTokens.OnAccent else SideStageTokens.Muted,
                    style = MaterialTheme.typography.labelSmall,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun CartStep(
    state: BuyerCheckoutUiState,
    controller: BuyerCheckoutController,
    launch: (suspend () -> Unit) -> Unit,
) {
    val cart = state.cart
    if (cart == null || cart.items.isEmpty()) {
        CheckoutCard {
            Text("Your cart is empty.", fontWeight = FontWeight.Bold)
            Text("Add something from the live room to begin checkout.", color = SideStageTokens.Muted)
        }
        return
    }

    CheckoutCard {
        cart.items.forEachIndexed { index, item ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(item.title, fontWeight = FontWeight.Bold)
                        Text(
                            BuyerCheckoutPresentation.formatPrice(item.priceCents),
                            color = SideStageTokens.Muted,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                    Text(
                        BuyerCheckoutPresentation.formatPrice(item.priceCents * item.quantity),
                        fontWeight = FontWeight.Bold,
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedButton(
                        enabled = !state.isBusy && item.quantity > 1,
                        onClick = { launch { controller.setQuantity(item, item.quantity - 1) } },
                    ) {
                        Text("−")
                    }
                    Text("${item.quantity}", modifier = Modifier.padding(horizontal = 16.dp), fontWeight = FontWeight.Bold)
                    OutlinedButton(
                        enabled = !state.isBusy,
                        onClick = { launch { controller.setQuantity(item, item.quantity + 1) } },
                    ) {
                        Text("+")
                    }
                    Spacer(Modifier.weight(1f))
                    TextButton(
                        enabled = !state.isBusy,
                        onClick = { launch { controller.removeItem(item) } },
                    ) {
                        Text("Remove")
                    }
                }
            }
            if (index < cart.items.lastIndex) HorizontalDivider(color = SideStageTokens.Border)
        }
        TotalRow("Subtotal", cart.subtotalCents)
    }

    PrimaryCheckoutAction(
        label = if (state.isBusy) "Updating cart…" else "Continue to shipping",
        enabled = !state.isBusy,
        onClick = controller::continueFromCart,
    )
}

@Composable
private fun AddressStep(
    state: BuyerCheckoutUiState,
    controller: BuyerCheckoutController,
    launch: (suspend () -> Unit) -> Unit,
) {
    val draft = state.draft
    CheckoutCard {
        CheckoutField(
            label = "Email",
            value = draft.email,
            isError = CheckoutAddressField.EMAIL in state.missingFields,
            keyboardType = KeyboardType.Email,
            onValueChange = { controller.updateDraft(draft.copy(email = it)) },
        )
        CheckoutField(
            label = "Full name",
            value = draft.name,
            isError = CheckoutAddressField.NAME in state.missingFields,
            onValueChange = { controller.updateDraft(draft.copy(name = it)) },
        )
        CheckoutField(
            label = "Address",
            value = draft.line1,
            isError = CheckoutAddressField.LINE1 in state.missingFields,
            onValueChange = { controller.updateDraft(draft.copy(line1 = it)) },
        )
        CheckoutField(
            label = "Apartment, suite, etc. (optional)",
            value = draft.line2,
            onValueChange = { controller.updateDraft(draft.copy(line2 = it)) },
        )
        CheckoutField(
            label = "City",
            value = draft.city,
            isError = CheckoutAddressField.CITY in state.missingFields,
            onValueChange = { controller.updateDraft(draft.copy(city = it)) },
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CheckoutField(
                label = "State",
                value = draft.state,
                modifier = Modifier.weight(1f),
                isError = CheckoutAddressField.STATE in state.missingFields,
                onValueChange = { controller.updateDraft(draft.copy(state = it)) },
            )
            CheckoutField(
                label = "ZIP code",
                value = draft.postalCode,
                modifier = Modifier.weight(1f),
                isError = CheckoutAddressField.POSTAL_CODE in state.missingFields,
                keyboardType = KeyboardType.Number,
                onValueChange = { controller.updateDraft(draft.copy(postalCode = it)) },
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CheckoutField(
                label = "Country",
                value = draft.country,
                modifier = Modifier.weight(1f),
                onValueChange = { controller.updateDraft(draft.copy(country = it)) },
            )
            CheckoutField(
                label = "Phone (optional)",
                value = draft.phone,
                modifier = Modifier.weight(1f),
                keyboardType = KeyboardType.Phone,
                onValueChange = { controller.updateDraft(draft.copy(phone = it)) },
            )
        }
    }
    PrimaryCheckoutAction(
        label = if (state.isBusy) "Finding rates…" else "Find shipping rates",
        enabled = !state.isBusy,
        onClick = { launch { controller.findShippingRates() } },
    )
}

@Composable
private fun ShippingStep(
    state: BuyerCheckoutUiState,
    controller: BuyerCheckoutController,
    launch: (suspend () -> Unit) -> Unit,
) {
    if (state.rates.isEmpty()) {
        CheckoutCard { Text(BuyerCheckoutPresentation.NO_RATES_MESSAGE, color = SideStageTokens.Muted) }
    } else {
        CheckoutCard {
            state.rates.forEachIndexed { index, rate ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(selected = rate.id == state.selectedRateId, onClick = { controller.selectRate(rate.id) })
                    Column(modifier = Modifier.weight(1f)) {
                        Text(BuyerCheckoutPresentation.rateTitle(rate), fontWeight = FontWeight.Bold)
                        Text(
                            BuyerCheckoutPresentation.deliveryEstimate(rate.deliveryDays),
                            color = SideStageTokens.Muted,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                    Text(BuyerCheckoutPresentation.formatPrice(rate.totalCents), fontWeight = FontWeight.Bold)
                }
                if (index < state.rates.lastIndex) HorizontalDivider(color = SideStageTokens.Border)
            }
        }
    }
    CheckoutCard {
        TotalRow("Subtotal", state.cart?.subtotalCents ?: 0L)
        TotalRow("Shipping", controller.selectedRate?.totalCents ?: 0L)
        HorizontalDivider(color = SideStageTokens.Border)
        TotalRow("Estimated total", controller.previewTotalCents, emphasized = true)
    }
    PrimaryCheckoutAction(
        label = if (state.isBusy) "Starting checkout…" else "Continue to Square",
        enabled = !state.isBusy && controller.selectedRate != null,
        onClick = { launch { controller.startCheckout() } },
    )
}

@Composable
private fun PaymentStep(
    state: BuyerCheckoutUiState,
    controller: BuyerCheckoutController,
    launch: (suspend () -> Unit) -> Unit,
) {
    CheckoutCard {
        if (controller.needsSquareConfiguration) {
            Text(BuyerCheckoutPresentation.SQUARE_NEEDS_CONFIGURATION_TITLE, fontWeight = FontWeight.Bold)
            Text(BuyerCheckoutPresentation.SQUARE_NEEDS_CONFIGURATION_DETAIL, color = SideStageTokens.Muted)
        } else {
            Text("Sandbox payment", color = SideStageTokens.Accent, style = MaterialTheme.typography.labelLarge)
            Text(
                "Square's documented sandbox card nonce will be used. No real card is charged.",
                color = SideStageTokens.Muted,
            )
            TotalRow("Order total", controller.orderTotalCents ?: 0L, emphasized = true)
        }
    }
    if (!controller.needsSquareConfiguration) {
        PrimaryCheckoutAction(
            label = if (state.isBusy) "Paying…" else "Pay with Square sandbox",
            enabled = !state.isBusy,
            onClick = { launch { controller.confirmPayment() } },
        )
    }
}

@Composable
private fun SuccessStep(
    state: BuyerCheckoutUiState,
    totalCents: Long?,
) {
    val order = state.completedOrder ?: return
    CheckoutCard {
        Text("Payment complete", color = SideStageTokens.Success, style = MaterialTheme.typography.labelLarge)
        Text(BuyerCheckoutPresentation.receiptMessage(order.id), fontWeight = FontWeight.Bold)
        TotalRow("Paid", totalCents ?: order.totalCents, emphasized = true)
    }
}

@Composable
private fun CheckoutField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier.fillMaxWidth(),
    isError: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
) {
    OutlinedTextField(
        modifier = modifier,
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        isError = isError,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        singleLine = true,
    )
}

@Composable
private fun CheckoutCard(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = SideStageTokens.Surface,
        border = BorderStroke(1.dp, SideStageTokens.Border),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = content,
        )
    }
}

@Composable
private fun TotalRow(
    label: String,
    cents: Long,
    emphasized: Boolean = false,
) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = if (emphasized) MaterialTheme.colorScheme.onSurface else SideStageTokens.Muted)
        Text(BuyerCheckoutPresentation.formatPrice(cents), fontWeight = if (emphasized) FontWeight.Bold else null)
    }
}

@Composable
private fun PrimaryCheckoutAction(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Button(
        modifier = Modifier.fillMaxWidth().sizeIn(minHeight = SideStageTokens.MinimumTouchTarget),
        enabled = enabled,
        onClick = onClick,
        shape = RoundedCornerShape(SideStageTokens.PrimaryButtonRadius),
        colors = ButtonDefaults.buttonColors(containerColor = SideStageTokens.Accent, contentColor = SideStageTokens.OnAccent),
    ) {
        Text(label)
    }
}

@Composable
private fun CheckoutError(message: String) {
    Text(message, color = Color(0xFF9F1D16), style = MaterialTheme.typography.labelMedium)
}
