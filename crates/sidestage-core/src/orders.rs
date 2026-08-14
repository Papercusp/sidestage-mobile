// SPDX-License-Identifier: MIT

//! Unified buyer order history for the native SideStage clients.
//!
//! The API currently returns a bounded, newest-first flat list. The mobile
//! contract exposes that list as deterministic cursor pages so both native
//! shells can consume it incrementally without duplicating paging logic.

use crate::client::{ApiClient, ApiError};
use crate::models::Currency;
use reqwest::Method;
use serde::{Deserialize, Serialize};

const DEFAULT_PAGE_SIZE: usize = 20;
const MAX_PAGE_SIZE: usize = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrderSource {
    Checkout,
    Auction,
    Offer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrderStatus {
    Pending,
    Paid,
    Failed,
    Accepted,
    Expired,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderLine {
    pub product_id: String,
    pub title: String,
    pub quantity: u32,
    pub unit_price_cents: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrderEvidenceKind {
    Condition,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderVideoSnapshot {
    pub id: String,
    pub event_id: String,
    pub event_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seller_name: Option<String>,
    pub product_id: String,
    pub product_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumbnail_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence_kind: Option<OrderEvidenceKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Order {
    pub id: String,
    pub source: OrderSource,
    pub buyer_id: String,
    pub event_id: String,
    pub event_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seller_name: Option<String>,
    pub status: OrderStatus,
    pub created_at: String,
    pub subtotal_cents: i64,
    pub shipping_cents: i64,
    pub total_cents: i64,
    pub currency: Currency,
    pub items: Vec<OrderLine>,
    pub video_snapshots: Vec<OrderVideoSnapshot>,
}

/// Opaque continuation position within the API's newest-first order snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct OrderCursor(u64);

impl OrderCursor {
    pub fn offset(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderPageRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<OrderCursor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page_size: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderPage {
    pub orders: Vec<Order>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<OrderCursor>,
}

impl ApiClient {
    /// Fetch the current buyer's unified checkout, auction, and offer history.
    ///
    /// Empty history is represented by an empty successful page. The server's
    /// flat, bounded response is paged locally until it grows a native cursor.
    pub async fn order_history(&self, request: &OrderPageRequest) -> Result<OrderPage, ApiError> {
        let mut url = self.endpoint(&["checkout", "orders"])?;
        url.query_pairs_mut()
            .append_pair("buyerId", self.buyer_id()?);

        let response: OrderHistoryResponse = self.execute(self.request(Method::GET, url)).await?;
        Ok(response.page(request))
    }
}

#[derive(Debug, Deserialize)]
struct OrderHistoryResponse {
    #[serde(default)]
    orders: Vec<Order>,
}

impl OrderHistoryResponse {
    fn page(self, request: &OrderPageRequest) -> OrderPage {
        let offset = request
            .cursor
            .and_then(|cursor| usize::try_from(cursor.0).ok())
            .unwrap_or(usize::MAX);
        let offset = if request.cursor.is_none() { 0 } else { offset };
        let page_size = request
            .page_size
            .map(|value| value as usize)
            .unwrap_or(DEFAULT_PAGE_SIZE)
            .clamp(1, MAX_PAGE_SIZE);

        if offset >= self.orders.len() {
            return OrderPage {
                orders: Vec::new(),
                next_cursor: None,
            };
        }

        let end = offset.saturating_add(page_size).min(self.orders.len());
        let has_more = end < self.orders.len();
        let orders = self
            .orders
            .into_iter()
            .skip(offset)
            .take(page_size)
            .collect();

        OrderPage {
            orders,
            next_cursor: has_more.then_some(OrderCursor(end as u64)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::ApiSession;
    use serde_json::json;
    use wiremock::{
        matchers::{header, method, path, query_param},
        Mock, MockServer, ResponseTemplate,
    };

    fn order_json(id: &str, source: &str, status: &str) -> serde_json::Value {
        json!({
            "id": id,
            "source": source,
            "buyerId": "buyer-mobile",
            "eventId": "sunday-drop",
            "eventTitle": "Sunday vintage drop",
            "sellerName": "Marsh & Co Vintage",
            "status": status,
            "createdAt": "2026-08-14T12:02:00.000Z",
            "subtotalCents": 2400,
            "shippingCents": 895,
            "totalCents": 3295,
            "currency": "USD",
            "items": [{
                "productId": "mug/red",
                "title": "Red mug",
                "quantity": 1,
                "unitPriceCents": 2400,
                "imageUrl": "https://example.test/mug.png"
            }],
            "videoSnapshots": [{
                "id": "sunday-drop:mug/red:4000",
                "eventId": "sunday-drop",
                "eventTitle": "Sunday vintage drop",
                "sellerName": "Marsh & Co Vintage",
                "productId": "mug/red",
                "productTitle": "Red mug",
                "thumbnailUrl": "https://example.test/drop.png",
                "startMs": 4000,
                "endMs": 9000,
                "previewText": "Glaze shown on camera",
                "evidenceKind": "condition",
                "evidenceLabel": "Minor glaze variation"
            }]
        })
    }

    fn client(server: &MockServer) -> ApiClient {
        ApiClient::new(server.uri())
            .unwrap()
            .with_session(ApiSession {
                buyer_id: "buyer-mobile".into(),
                access_token: Some("mobile-token".into()),
            })
            .unwrap()
    }

    #[tokio::test]
    async fn fetches_a_populated_unified_order_page() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/checkout/orders"))
            .and(query_param("buyerId", "buyer-mobile"))
            .and(header("authorization", "Bearer mobile-token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "orders": [order_json("order-1", "checkout", "paid")]
            })))
            .mount(&server)
            .await;

        let page = client(&server)
            .order_history(&OrderPageRequest::default())
            .await
            .unwrap();

        assert_eq!(page.orders.len(), 1);
        assert_eq!(page.orders[0].source, OrderSource::Checkout);
        assert_eq!(page.orders[0].items[0].unit_price_cents, 2400);
        assert_eq!(
            page.orders[0].video_snapshots[0].evidence_kind,
            Some(OrderEvidenceKind::Condition)
        );
        assert_eq!(page.next_cursor, None);
    }

    #[tokio::test]
    async fn empty_history_is_a_successful_empty_page() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/checkout/orders"))
            .and(query_param("buyerId", "buyer-mobile"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .mount(&server)
            .await;

        let page = client(&server)
            .order_history(&OrderPageRequest::default())
            .await
            .unwrap();

        assert!(page.orders.is_empty());
        assert_eq!(page.next_cursor, None);
    }

    #[tokio::test]
    async fn malformed_order_payload_uses_the_shared_decode_error() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/checkout/orders"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "orders": [{ "id": "missing-required-order-fields" }]
            })))
            .mount(&server)
            .await;

        let error = client(&server)
            .order_history(&OrderPageRequest::default())
            .await
            .unwrap_err();

        assert!(matches!(error, ApiError::Decode(_)));
    }

    #[tokio::test]
    async fn continuation_cursor_returns_the_next_page() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/checkout/orders"))
            .and(query_param("buyerId", "buyer-mobile"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "orders": [
                    order_json("order-3", "offer", "accepted"),
                    order_json("order-2", "auction", "paid"),
                    order_json("order-1", "checkout", "paid")
                ]
            })))
            .expect(2)
            .mount(&server)
            .await;

        let first = client(&server)
            .order_history(&OrderPageRequest {
                cursor: None,
                page_size: Some(2),
            })
            .await
            .unwrap();
        assert_eq!(
            first
                .orders
                .iter()
                .map(|order| order.id.as_str())
                .collect::<Vec<_>>(),
            ["order-3", "order-2"]
        );
        assert_eq!(first.next_cursor.map(OrderCursor::offset), Some(2));

        let second = client(&server)
            .order_history(&OrderPageRequest {
                cursor: first.next_cursor,
                page_size: Some(2),
            })
            .await
            .unwrap();
        assert_eq!(
            second
                .orders
                .iter()
                .map(|order| order.id.as_str())
                .collect::<Vec<_>>(),
            ["order-1"]
        );
        assert_eq!(second.next_cursor, None);
    }
}
