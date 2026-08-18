// SPDX-License-Identifier: MIT

//! Typed SideStage API wire models shared by every native shell.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiSession {
    pub buyer_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
}

impl ApiSession {
    pub fn anonymous(buyer_id: impl Into<String>) -> Self {
        Self {
            buyer_id: buyer_id.into(),
            access_token: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EventStatus {
    Live,
    Scheduled,
    Ended,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventSummary {
    pub event_id: String,
    pub title: String,
    pub seller_id: String,
    pub seller_name: String,
    pub status: EventStatus,
    pub starts_at: Option<String>,
    pub ended_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumbnail_url: Option<String>,
    /// Full WHEP endpoint, server-computed (D-035). None on an API too old to
    /// serve it, or a deployment with no media plane — never derived here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playback_url: Option<String>,
    pub viewers: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogSearch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub q: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub product_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub availability: Option<CatalogAvailability>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page_size: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CatalogAvailability {
    #[serde(rename = "all")]
    All,
    #[serde(rename = "in-stock")]
    InStock,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogVariant {
    pub id: String,
    pub group_id: Option<String>,
    pub title: String,
    pub brand: String,
    pub product_type: String,
    pub sku: String,
    pub condition: Option<String>,
    pub handling_days: Option<i32>,
    pub price_cents: i64,
    pub available_qty: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogPage {
    pub rows: Vec<CatalogVariant>,
    pub page: u32,
    pub page_size: u32,
    pub total: u64,
    pub total_is_floor: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Currency {
    #[serde(rename = "USD")]
    Usd,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CartItem {
    pub product_id: String,
    pub title: String,
    pub price_cents: i64,
    pub quantity: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cart {
    pub id: String,
    pub currency: Currency,
    pub items: Vec<CartItem>,
    pub subtotal_cents: i64,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddCartItemRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cart_id: Option<String>,
    pub product_id: String,
    pub title: String,
    pub price_cents: i64,
    #[serde(default = "default_quantity")]
    pub quantity: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
}

const fn default_quantity() -> u32 {
    1
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShippingAddress {
    pub name: String,
    pub line1: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line2: Option<String>,
    pub city: String,
    pub state: String,
    pub postal_code: String,
    pub country: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phone: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShippingRatesRequest {
    pub cart_id: String,
    pub address: ShippingAddress,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShippingRate {
    pub id: String,
    pub carrier: String,
    pub service: String,
    pub total_cents: i64,
    pub delivery_days: Option<u32>,
    pub parcel_count: u32,
    pub quoted_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShippingRateSnapshot {
    pub id: String,
    pub carrier: String,
    pub service: String,
    pub total_cents: i64,
    pub delivery_days: Option<u32>,
    pub parcel_count: u32,
    pub quoted_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PaymentSessionStatus {
    Ready,
    NeedsConfiguration,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaymentSession {
    pub provider: PaymentProvider,
    pub mode: PaymentMode,
    pub status: PaymentSessionStatus,
    pub app_id: Option<String>,
    pub location_id: Option<String>,
    pub order_id: String,
    pub amount_cents: i64,
    pub currency: Currency,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PaymentProvider {
    Square,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PaymentMode {
    Sandbox,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CheckoutOrderStatus {
    Pending,
    Paid,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckoutOrder {
    pub id: String,
    pub cart_id: String,
    pub buyer_id: String,
    pub event_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    pub subtotal_cents: i64,
    pub shipping_cents: i64,
    pub total_cents: i64,
    pub currency: Currency,
    pub status: CheckoutOrderStatus,
    pub created_at: String,
    pub items: Vec<CartItem>,
    pub payment_session: PaymentSession,
    #[serde(default, alias = "address", skip_serializing_if = "Option::is_none")]
    pub shipping_address: Option<ShippingAddress>,
    #[serde(
        default,
        alias = "shippingRate",
        skip_serializing_if = "Option::is_none"
    )]
    pub selected_shipping_rate: Option<ShippingRateSnapshot>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateCheckoutSessionRequest {
    pub cart_id: String,
    pub event_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub shipping_address: ShippingAddress,
    pub shipping_rate_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckoutSessionResponse {
    pub order: CheckoutOrder,
    pub session: PaymentSession,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmCheckoutRequest {
    pub order_id: String,
    pub source_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PaymentResultStatus {
    Paid,
    Failed,
    NeedsConfiguration,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaymentResult {
    pub status: PaymentResultStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transaction_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckoutConfirmation {
    pub order: CheckoutOrder,
    pub payment: PaymentResult,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{de::DeserializeOwned, Serialize};
    use serde_json::{json, Value};
    use std::fmt::Debug;

    const EVENTS_FIXTURE: &str = include_str!("../testdata/events-2026-08-14.json");
    const CATALOG_FIXTURE: &str = include_str!("../testdata/catalog-page-2026-08-14.json");
    const CART_FIXTURE: &str = include_str!("../testdata/cart-2026-08-14.json");
    const SHIPPING_FIXTURE: &str = include_str!("../testdata/shipping-rates-2026-08-14.json");
    const CHECKOUT_FIXTURE: &str = include_str!("../testdata/checkout-contracts-2026-08-14.json");

    fn fixture(name: &str, input: &str) -> Value {
        serde_json::from_str(input)
            .unwrap_or_else(|error| panic!("{name} fixture must remain valid JSON: {error}"))
    }

    fn assert_fixture_comment(value: &Value, endpoint: &str) {
        let comment = value["_fixture"]["comment"]
            .as_str()
            .unwrap_or_else(|| panic!("fixture for {endpoint} must carry a source comment"));
        assert!(
            comment.contains(endpoint),
            "fixture comment must name {endpoint}"
        );
        assert!(
            comment.contains("2026-08-14"),
            "fixture comment must name its capture date"
        );
    }

    fn round_trip<T>(value: Value, name: &str) -> T
    where
        T: Debug + PartialEq + Serialize + DeserializeOwned,
    {
        let decoded: T = serde_json::from_value(value)
            .unwrap_or_else(|error| panic!("{name} fixture must decode: {error}"));
        let encoded = serde_json::to_value(&decoded)
            .unwrap_or_else(|error| panic!("{name} must encode after decoding: {error}"));
        let decoded_again: T = serde_json::from_value(encoded)
            .unwrap_or_else(|error| panic!("encoded {name} must decode again: {error}"));
        assert_eq!(decoded_again, decoded, "{name} changed across round-trip");
        decoded
    }

    #[test]
    fn real_api_fixtures_keep_source_metadata_and_decode() {
        let events = fixture("events", EVENTS_FIXTURE);
        let catalog = fixture("catalog", CATALOG_FIXTURE);
        let cart = fixture("cart", CART_FIXTURE);
        let shipping = fixture("shipping rates", SHIPPING_FIXTURE);
        let checkout = fixture("checkout contracts", CHECKOUT_FIXTURE);

        assert_fixture_comment(&events, "GET /events");
        assert_fixture_comment(&catalog, "GET /catalog?pageSize=1");
        assert_fixture_comment(&cart, "POST /cart/items");
        assert_fixture_comment(&shipping, "POST /shipping/rates");
        assert_fixture_comment(&checkout, "POST /checkout/sessions");

        round_trip::<EventSummary>(events["events"][0].clone(), "EventSummary");
        round_trip::<CatalogPage>(catalog, "CatalogPage");
        round_trip::<Cart>(cart, "Cart");
        let rates: Vec<ShippingRate> = serde_json::from_value(shipping["rates"].clone())
            .expect("live POST /shipping/rates fixture must decode");
        assert!(rates.is_empty(), "captured unconfigured response was empty");
    }

    #[test]
    fn every_public_model_round_trips() {
        let events = fixture("events", EVENTS_FIXTURE);
        let catalog = fixture("catalog", CATALOG_FIXTURE);
        let cart = fixture("cart", CART_FIXTURE);
        let shipping = fixture("shipping rates", SHIPPING_FIXTURE);
        let contracts = fixture("checkout contracts", CHECKOUT_FIXTURE);

        round_trip::<ApiSession>(contracts["apiSession"].clone(), "ApiSession");
        round_trip::<EventStatus>(json!("live"), "EventStatus");
        round_trip::<EventSummary>(events["events"][0].clone(), "EventSummary");
        round_trip::<CatalogSearch>(contracts["catalogSearch"].clone(), "CatalogSearch");
        round_trip::<CatalogAvailability>(json!("in-stock"), "CatalogAvailability");
        round_trip::<CatalogVariant>(catalog["rows"][0].clone(), "CatalogVariant");
        round_trip::<CatalogPage>(catalog, "CatalogPage");
        round_trip::<Currency>(json!("USD"), "Currency");
        round_trip::<CartItem>(cart["items"][0].clone(), "CartItem");
        round_trip::<Cart>(cart, "Cart");
        round_trip::<AddCartItemRequest>(
            contracts["addCartItemRequest"].clone(),
            "AddCartItemRequest",
        );
        round_trip::<ShippingAddress>(
            contracts["shippingRatesRequest"]["address"].clone(),
            "ShippingAddress",
        );
        round_trip::<ShippingRatesRequest>(
            contracts["shippingRatesRequest"].clone(),
            "ShippingRatesRequest",
        );
        round_trip::<ShippingRate>(shipping["representativeRate"].clone(), "ShippingRate");
        round_trip::<ShippingRateSnapshot>(
            shipping["representativeRate"].clone(),
            "ShippingRateSnapshot",
        );
        round_trip::<PaymentSessionStatus>(json!("needs-configuration"), "PaymentSessionStatus");
        round_trip::<PaymentSession>(contracts["paymentSession"].clone(), "PaymentSession");
        round_trip::<PaymentProvider>(json!("square"), "PaymentProvider");
        round_trip::<PaymentMode>(json!("sandbox"), "PaymentMode");
        round_trip::<CheckoutOrderStatus>(json!("pending"), "CheckoutOrderStatus");
        round_trip::<CheckoutOrder>(contracts["checkoutOrder"].clone(), "CheckoutOrder");
        round_trip::<CreateCheckoutSessionRequest>(
            contracts["createCheckoutSessionRequest"].clone(),
            "CreateCheckoutSessionRequest",
        );
        round_trip::<CheckoutSessionResponse>(
            json!({
                "order": contracts["checkoutOrder"].clone(),
                "session": contracts["paymentSession"].clone(),
            }),
            "CheckoutSessionResponse",
        );
        round_trip::<ConfirmCheckoutRequest>(
            contracts["confirmCheckoutRequest"].clone(),
            "ConfirmCheckoutRequest",
        );
        round_trip::<PaymentResultStatus>(json!("needs-configuration"), "PaymentResultStatus");
        round_trip::<PaymentResult>(contracts["paymentResult"].clone(), "PaymentResult");
        round_trip::<CheckoutConfirmation>(
            json!({
                "order": contracts["checkoutOrder"].clone(),
                "payment": contracts["paymentResult"].clone(),
            }),
            "CheckoutConfirmation",
        );
    }

    #[test]
    fn absent_optional_fields_decode_to_none_and_quantity_defaults() {
        let event: EventSummary = serde_json::from_value(json!({
            "eventId": "event-minimal",
            "title": "Minimal event",
            "sellerId": "seller-1",
            "sellerName": "Seller",
            "status": "scheduled",
            "viewers": 0
        }))
        .expect("optional event fields may be absent");
        assert_eq!(event.starts_at, None);
        assert_eq!(event.ended_at, None);
        assert_eq!(event.thumbnail_url, None);
        // An API predating D-035 serves no playbackUrl; that must stay decodable.
        assert_eq!(event.playback_url, None);

        let variant: CatalogVariant = serde_json::from_value(json!({
            "id": "product-minimal",
            "title": "Minimal product",
            "brand": "SideStage",
            "productType": "OTHER",
            "sku": "MIN-1",
            "priceCents": 100,
            "availableQty": 1
        }))
        .expect("optional catalog fields may be absent");
        assert_eq!(variant.group_id, None);
        assert_eq!(variant.image_url, None);

        let request: AddCartItemRequest = serde_json::from_value(json!({
            "productId": "product-minimal",
            "title": "Minimal product",
            "priceCents": 100
        }))
        .expect("cart request defaults may be absent");
        assert_eq!(request.cart_id, None);
        assert_eq!(request.quantity, 1);
        assert_eq!(request.image_url, None);

        let payment: PaymentResult = serde_json::from_value(json!({ "status": "paid" }))
            .expect("optional payment result fields may be absent");
        assert_eq!(payment.transaction_id, None);
        assert_eq!(payment.error_message, None);
    }

    #[test]
    fn rejects_server_shapes_that_would_silently_break_mobile_decoding() {
        let unknown_status = serde_json::from_value::<EventStatus>(json!("paused"));
        assert!(
            unknown_status.is_err(),
            "unknown enum variants must not decode"
        );

        let mut catalog = fixture("catalog", CATALOG_FIXTURE);
        catalog["page"] = Value::Null;
        assert!(
            serde_json::from_value::<CatalogPage>(catalog).is_err(),
            "null in a required field must not decode"
        );

        let mut row = fixture("catalog", CATALOG_FIXTURE)["rows"][0].clone();
        row["priceCents"] = json!("4999");
        assert!(
            serde_json::from_value::<CatalogVariant>(row).is_err(),
            "numeric strings must not decode as numbers"
        );
    }
}
