// SPDX-License-Identifier: MIT

//! Square-sandbox checkout orchestration shared by the native buyer shells.
//!
//! Shipping money is derived only from a server-issued rate. The client sends
//! the rate identity back to checkout so the server can revalidate the cart,
//! quote, and total instead of trusting a client-provided shipping amount.

use crate::client::{ApiClient, ApiError};
use crate::models::{
    CheckoutConfirmation, CheckoutOrder, CheckoutSessionResponse, ConfirmCheckoutRequest,
    CreateCheckoutSessionRequest, PaymentResultStatus, PaymentSessionStatus, ShippingAddress,
    ShippingRate, ShippingRatesRequest,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone)]
pub struct CheckoutFlow {
    client: ApiClient,
}

impl CheckoutFlow {
    pub fn new(client: &ApiClient) -> Self {
        Self {
            client: client.clone(),
        }
    }

    /// Request server-authoritative shipping choices for the current cart.
    pub async fn quote_shipping(
        &self,
        cart_id: &str,
        address: &ShippingAddress,
    ) -> Result<Vec<ShippingRate>, ApiError> {
        self.client
            .shipping_rates(&ShippingRatesRequest {
                cart_id: cart_id.to_owned(),
                address: address.clone(),
            })
            .await
    }

    /// Create the typed Square-sandbox payment session.
    ///
    /// `CreateCheckoutSessionRequest` deliberately contains a shipping-rate
    /// id but no shipping-cent field; the server recalculates the final total.
    pub async fn start(
        &self,
        input: &CreateCheckoutSessionRequest,
    ) -> Result<CheckoutSessionResponse, ApiError> {
        self.client.create_checkout_session(input).await
    }

    pub async fn confirm(
        &self,
        input: &ConfirmCheckoutRequest,
    ) -> Result<CheckoutOutcome, ApiError> {
        let confirmation = self.client.confirm_checkout(input).await?;
        Ok(CheckoutOutcome::from_confirmation(confirmation))
    }

    /// Run session creation and payment confirmation as one buyer operation.
    ///
    /// Transport, HTTP, and decode failures remain the original `ApiError` so
    /// native shells apply the same retry and user-message policy everywhere.
    pub async fn complete(
        &self,
        input: &CreateCheckoutSessionRequest,
        source_id: &str,
    ) -> Result<CheckoutOutcome, ApiError> {
        let checkout = self.start(input).await?;
        if checkout.session.status == PaymentSessionStatus::NeedsConfiguration {
            return Ok(CheckoutOutcome::NeedsConfiguration {
                order: checkout.order,
                message: None,
            });
        }

        self.confirm(&ConfirmCheckoutRequest {
            order_id: checkout.order.id,
            source_id: source_id.to_owned(),
        })
        .await
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "kebab-case")]
pub enum CheckoutOutcome {
    Paid {
        order: CheckoutOrder,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        transaction_id: Option<String>,
    },
    Declined {
        order: CheckoutOrder,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    NeedsConfiguration {
        order: CheckoutOrder,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
}

impl CheckoutOutcome {
    pub fn order(&self) -> &CheckoutOrder {
        match self {
            Self::Paid { order, .. }
            | Self::Declined { order, .. }
            | Self::NeedsConfiguration { order, .. } => order,
        }
    }

    fn from_confirmation(confirmation: CheckoutConfirmation) -> Self {
        let CheckoutConfirmation { order, payment } = confirmation;
        match payment.status {
            PaymentResultStatus::Paid => Self::Paid {
                order,
                transaction_id: payment.transaction_id,
            },
            PaymentResultStatus::Failed => Self::Declined {
                order,
                message: payment.error_message,
            },
            PaymentResultStatus::NeedsConfiguration => Self::NeedsConfiguration {
                order,
                message: payment.error_message,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckoutTotals {
    pub subtotal_cents: i64,
    pub shipping_cents: i64,
    pub total_cents: i64,
}

impl CheckoutTotals {
    /// Build a display estimate from a server-issued shipping quote.
    /// Checkout still revalidates this total server-side before payment.
    pub fn from_shipping_rate(
        subtotal_cents: i64,
        rate: &ShippingRate,
    ) -> Result<Self, CheckoutMathError> {
        if subtotal_cents < 0 {
            return Err(CheckoutMathError::NegativeAmount("subtotal"));
        }
        if rate.total_cents < 0 {
            return Err(CheckoutMathError::NegativeAmount("shipping"));
        }
        let total_cents = subtotal_cents
            .checked_add(rate.total_cents)
            .ok_or(CheckoutMathError::MoneyOverflow)?;
        Ok(Self {
            subtotal_cents,
            shipping_cents: rate.total_cents,
            total_cents,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CheckoutMathError {
    #[error("checkout {0} amount cannot be negative")]
    NegativeAmount(&'static str),
    #[error("checkout money arithmetic overflowed integer minor units")]
    MoneyOverflow,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::ApiSession;
    use serde_json::json;
    use std::net::TcpListener;
    use wiremock::{
        matchers::{body_json, method, path},
        Mock, MockServer, ResponseTemplate,
    };

    fn address() -> ShippingAddress {
        ShippingAddress {
            name: "Avi Buyer".into(),
            line1: "123 Stage St".into(),
            line2: None,
            city: "Brooklyn".into(),
            state: "NY".into(),
            postal_code: "11201".into(),
            country: "US".into(),
            phone: None,
        }
    }

    fn order_json(status: &str, session_status: &str) -> serde_json::Value {
        json!({
            "id": "order-1",
            "cartId": "cart-1",
            "buyerId": "buyer-mobile",
            "eventId": "sunday-drop",
            "email": "buyer@example.test",
            "subtotalCents": 914137,
            "shippingCents": 895,
            "totalCents": 915032,
            "currency": "USD",
            "status": status,
            "createdAt": "2026-08-14T12:02:00.000Z",
            "items": [{
                "productId": "rare/watch",
                "title": "Rare watch",
                "priceCents": 914137,
                "quantity": 1
            }],
            "paymentSession": {
                "provider": "square",
                "mode": "sandbox",
                "status": session_status,
                "appId": "sandbox-app",
                "locationId": "sandbox-location",
                "orderId": "order-1",
                "amountCents": 915032,
                "currency": "USD"
            }
        })
    }

    fn session_request() -> CreateCheckoutSessionRequest {
        CreateCheckoutSessionRequest {
            cart_id: "cart-1".into(),
            event_id: "sunday-drop".into(),
            email: Some("buyer@example.test".into()),
            name: Some("Avi Buyer".into()),
            shipping_address: address(),
            shipping_rate_id: "USPS:Priority".into(),
        }
    }

    fn client(base_url: &str) -> ApiClient {
        ApiClient::new(base_url)
            .unwrap()
            .with_session(ApiSession::anonymous("buyer-mobile"))
            .unwrap()
    }

    #[test]
    fn totals_include_only_the_server_quoted_shipping_amount() {
        let rate = ShippingRate {
            id: "USPS:Priority".into(),
            carrier: "USPS".into(),
            service: "Priority".into(),
            total_cents: 895,
            delivery_days: Some(3),
            parcel_count: 1,
            quoted_at: "2026-08-14T12:01:30.000Z".into(),
        };

        let totals = CheckoutTotals::from_shipping_rate(914_137, &rate).unwrap();
        assert_eq!(
            totals,
            CheckoutTotals {
                subtotal_cents: 914_137,
                shipping_cents: 895,
                total_cents: 915_032,
            }
        );
        let _: i64 = totals.total_cents;
    }

    #[tokio::test]
    async fn declined_square_sandbox_payment_is_an_explicit_outcome() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/checkout/confirm"))
            .and(body_json(json!({
                "orderId": "order-1",
                "sourceId": "cnon:card-declined"
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "order": order_json("failed", "ready"),
                "payment": {
                    "status": "failed",
                    "errorMessage": "Card declined in Square sandbox"
                }
            })))
            .mount(&server)
            .await;

        let outcome = CheckoutFlow::new(&client(&server.uri()))
            .confirm(&ConfirmCheckoutRequest {
                order_id: "order-1".into(),
                source_id: "cnon:card-declined".into(),
            })
            .await
            .unwrap();

        assert!(matches!(
            outcome,
            CheckoutOutcome::Declined {
                ref order,
                message: Some(ref message),
            } if order.status == crate::models::CheckoutOrderStatus::Failed
                && message == "Card declined in Square sandbox"
        ));
    }

    #[tokio::test]
    async fn missing_square_configuration_does_not_attempt_confirmation() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/checkout/sessions"))
            .and(body_json(json!({
                "cartId": "cart-1",
                "buyerId": "buyer-mobile",
                "eventId": "sunday-drop",
                "email": "buyer@example.test",
                "name": "Avi Buyer",
                "shippingAddress": address(),
                "shippingRateId": "USPS:Priority"
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "order": order_json("pending", "needs-configuration"),
                "session": order_json("pending", "needs-configuration")["paymentSession"]
            })))
            .mount(&server)
            .await;

        let outcome = CheckoutFlow::new(&client(&server.uri()))
            .complete(&session_request(), "unused-source")
            .await
            .unwrap();

        assert!(matches!(
            outcome,
            CheckoutOutcome::NeedsConfiguration { .. }
        ));
    }

    #[tokio::test]
    async fn network_failure_during_payment_confirmation_remains_an_api_error() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let unreachable_url = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);

        let error = CheckoutFlow::new(&client(&unreachable_url))
            .confirm(&ConfirmCheckoutRequest {
                order_id: "order-1".into(),
                source_id: "cnon:card-ok".into(),
            })
            .await
            .unwrap_err();

        assert!(matches!(error, ApiError::Transport(_)));
    }
}
