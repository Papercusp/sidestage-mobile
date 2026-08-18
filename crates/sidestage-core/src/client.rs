// SPDX-License-Identifier: MIT

//! HTTP client for the SideStage API trust boundary.

use crate::models::*;
use reqwest::{Client, Method, Request, RequestBuilder, StatusCode, Url};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("invalid SideStage API base URL: {0}")]
    InvalidBaseUrl(String),
    #[error("the current buyer session is missing or invalid")]
    InvalidSession,
    #[error("event {0} was not found in the buyer-visible feed")]
    EventNotFound(String),
    #[error("SideStage API request failed")]
    Transport(#[from] reqwest::Error),
    #[error("SideStage API returned HTTP {status}: {message}")]
    Http { status: u16, message: String },
    #[error("SideStage API returned an invalid response")]
    Decode(#[from] serde_json::Error),
}

impl ApiError {
    fn is_retryable_get_failure(&self) -> bool {
        match self {
            Self::Transport(_) => true,
            Self::Http { status, .. } => {
                matches!(*status, 408 | 429) || (500..=599).contains(status)
            }
            Self::InvalidBaseUrl(_)
            | Self::InvalidSession
            | Self::EventNotFound(_)
            | Self::Decode(_) => false,
        }
    }
}

/// Retry behavior for explicit resilient GET reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryPolicy {
    /// Total requests, including the first attempt. Values below one are treated as one.
    pub max_attempts: u32,
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            initial_backoff: Duration::from_millis(150),
            max_backoff: Duration::from_secs(2),
        }
    }
}

/// Cache and retry behavior for explicit resilient reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResiliencePolicy {
    /// A cached read younger than this is returned without touching the network.
    pub fresh_cache_for: Duration,
    pub retry: RetryPolicy,
}

impl Default for ResiliencePolicy {
    fn default() -> Self {
        Self {
            fresh_cache_for: Duration::from_secs(15),
            retry: RetryPolicy::default(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadSource {
    Network,
    Cache,
}

/// Provenance attached to every resilient read so cached data is never passed off as live.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadFreshness {
    pub source: ReadSource,
    pub stale: bool,
    pub cached_at_unix_ms: u64,
    pub age_ms: u64,
    /// Network attempts made for this read. A fresh cache hit has zero attempts.
    pub attempts: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResilientRead<T> {
    pub value: T,
    pub freshness: ReadFreshness,
}

#[derive(Debug, Clone)]
struct CacheEntry {
    body: Vec<u8>,
    cached_at_unix_ms: u64,
}

#[derive(Debug)]
struct TransportResponse {
    status: StatusCode,
    body: Vec<u8>,
}

type TransportFuture =
    Pin<Box<dyn Future<Output = Result<TransportResponse, ApiError>> + Send + 'static>>;

trait HttpTransport: Send + Sync {
    fn send(&self, request: Request) -> TransportFuture;
}

#[derive(Clone)]
struct ReqwestTransport {
    client: Client,
}

impl HttpTransport for ReqwestTransport {
    fn send(&self, request: Request) -> TransportFuture {
        let client = self.client.clone();
        Box::pin(async move {
            let response = client.execute(request).await?;
            let status = response.status();
            let body = response.bytes().await?.to_vec();
            Ok(TransportResponse { status, body })
        })
    }
}

type SleepFuture<'a> = Pin<Box<dyn Future<Output = ()> + Send + 'a>>;

trait Runtime: Send + Sync {
    fn now_unix_ms(&self) -> u64;
    fn sleep(&self, duration: Duration) -> SleepFuture<'_>;
}

#[derive(Debug, Default)]
struct TokioRuntime;

impl Runtime for TokioRuntime {
    fn now_unix_ms(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64
    }

    fn sleep(&self, duration: Duration) -> SleepFuture<'_> {
        Box::pin(tokio::time::sleep(duration))
    }
}

#[derive(Clone)]
pub struct ApiClient {
    base_url: Url,
    http: Client,
    session: Option<ApiSession>,
    resilience: ResiliencePolicy,
    cache: Arc<Mutex<HashMap<String, CacheEntry>>>,
    transport: Arc<dyn HttpTransport>,
    runtime: Arc<dyn Runtime>,
}

impl std::fmt::Debug for ApiClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ApiClient")
            .field("base_url", &self.base_url)
            .field("session", &self.session)
            .field("resilience", &self.resilience)
            .finish_non_exhaustive()
    }
}

impl ApiClient {
    pub fn new(base_url: impl AsRef<str>) -> Result<Self, ApiError> {
        let raw = base_url.as_ref();
        let mut base_url = Url::parse(raw).map_err(|_| ApiError::InvalidBaseUrl(raw.into()))?;
        if base_url.cannot_be_a_base() || !matches!(base_url.scheme(), "http" | "https") {
            return Err(ApiError::InvalidBaseUrl(raw.into()));
        }
        if !base_url.path().ends_with('/') {
            let path = format!("{}/", base_url.path());
            base_url.set_path(&path);
        }
        let http = Client::new();
        Ok(Self {
            base_url,
            transport: Arc::new(ReqwestTransport {
                client: http.clone(),
            }),
            http,
            session: None,
            resilience: ResiliencePolicy::default(),
            cache: Arc::new(Mutex::new(HashMap::new())),
            runtime: Arc::new(TokioRuntime),
        })
    }

    pub fn with_resilience_policy(mut self, policy: ResiliencePolicy) -> Self {
        self.resilience = policy;
        self
    }

    pub fn clear_resilient_cache(&self) {
        self.cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clear();
    }

    pub fn with_session(mut self, session: ApiSession) -> Result<Self, ApiError> {
        validate_session(&session)?;
        self.session = Some(session);
        Ok(self)
    }

    pub fn set_session(&mut self, session: Option<ApiSession>) -> Result<(), ApiError> {
        if let Some(session) = &session {
            validate_session(session)?;
        }
        self.session = session;
        Ok(())
    }

    pub fn session(&self) -> Option<&ApiSession> {
        self.session.as_ref()
    }

    pub async fn events(&self) -> Result<Vec<EventSummary>, ApiError> {
        let response: EventListResponse = self.get(&["events"]).await?;
        Ok(response.events)
    }

    /// Read the event feed with a fresh-cache fast path, bounded GET retry, and stale fallback.
    pub async fn resilient_events(&self) -> Result<ResilientRead<Vec<EventSummary>>, ApiError> {
        let response: ResilientRead<EventListResponse> =
            self.resilient_get(self.endpoint(&["events"])?).await?;
        Ok(response.map(|value| value.events))
    }

    /// Resolve a buyer-visible event from the authoritative collection read.
    /// SideStage intentionally exposes no separate `GET /events/:id` route.
    pub async fn event(&self, event_id: &str) -> Result<EventSummary, ApiError> {
        self.events()
            .await?
            .into_iter()
            .find(|event| event.event_id == event_id)
            .ok_or_else(|| ApiError::EventNotFound(event_id.to_owned()))
    }

    pub async fn catalog(&self, search: &CatalogSearch) -> Result<CatalogPage, ApiError> {
        let url = self.catalog_url(search)?;
        self.execute(self.request(Method::GET, url)).await
    }

    /// Read the product catalog with explicit freshness metadata.
    pub async fn resilient_catalog(
        &self,
        search: &CatalogSearch,
    ) -> Result<ResilientRead<CatalogPage>, ApiError> {
        self.resilient_get(self.catalog_url(search)?).await
    }

    pub async fn product_types(&self) -> Result<Vec<String>, ApiError> {
        self.get(&["catalog", "types"]).await
    }

    pub async fn product(&self, product_id: &str) -> Result<CatalogVariant, ApiError> {
        self.get(&["catalog", "variants", product_id]).await
    }

    pub async fn cart(&self, cart_id: &str) -> Result<Option<Cart>, ApiError> {
        self.get(&["cart", cart_id]).await
    }

    pub async fn add_cart_item(&self, input: &AddCartItemRequest) -> Result<Cart, ApiError> {
        self.send_json(Method::POST, &["cart", "items"], input)
            .await
    }

    pub async fn set_cart_quantity(
        &self,
        cart_id: &str,
        product_id: &str,
        quantity: u32,
    ) -> Result<Cart, ApiError> {
        self.send_json(
            Method::PATCH,
            &["cart", cart_id, "items", product_id],
            &QuantityBody { quantity },
        )
        .await
    }

    pub async fn remove_cart_item(
        &self,
        cart_id: &str,
        product_id: &str,
    ) -> Result<Cart, ApiError> {
        let url = self.endpoint(&["cart", cart_id, "items", product_id])?;
        self.execute(self.request(Method::DELETE, url)).await
    }

    pub async fn shipping_rates(
        &self,
        input: &ShippingRatesRequest,
    ) -> Result<Vec<ShippingRate>, ApiError> {
        self.send_json(Method::POST, &["shipping", "rates"], input)
            .await
    }

    pub async fn create_checkout_session(
        &self,
        input: &CreateCheckoutSessionRequest,
    ) -> Result<CheckoutSessionResponse, ApiError> {
        let buyer_id = self.buyer_id()?;
        let body = CreateCheckoutSessionBody {
            cart_id: &input.cart_id,
            buyer_id,
            event_id: &input.event_id,
            email: input.email.as_deref(),
            name: input.name.as_deref(),
            shipping_address: &input.shipping_address,
            shipping_rate_id: &input.shipping_rate_id,
        };
        self.send_json(Method::POST, &["checkout", "sessions"], &body)
            .await
    }

    pub async fn confirm_checkout(
        &self,
        input: &ConfirmCheckoutRequest,
    ) -> Result<CheckoutConfirmation, ApiError> {
        self.send_json(Method::POST, &["checkout", "confirm"], input)
            .await
    }

    pub async fn orders(&self) -> Result<Vec<CheckoutOrder>, ApiError> {
        let response: CheckoutOrdersResponse = self
            .execute(self.request(Method::GET, self.orders_url()?))
            .await?;
        Ok(response.orders)
    }

    /// Read order history with explicit freshness metadata.
    pub async fn resilient_orders(&self) -> Result<ResilientRead<Vec<CheckoutOrder>>, ApiError> {
        let response: ResilientRead<CheckoutOrdersResponse> =
            self.resilient_get(self.orders_url()?).await?;
        Ok(response.map(|value| value.orders))
    }

    pub(crate) fn buyer_id(&self) -> Result<&str, ApiError> {
        self.session
            .as_ref()
            .map(|session| session.buyer_id.as_str())
            .ok_or(ApiError::InvalidSession)
    }

    async fn get<T>(&self, segments: &[&str]) -> Result<T, ApiError>
    where
        T: DeserializeOwned,
    {
        let url = self.endpoint(segments)?;
        self.execute(self.request(Method::GET, url)).await
    }

    fn catalog_url(&self, search: &CatalogSearch) -> Result<Url, ApiError> {
        let mut url = self.endpoint(&["catalog"])?;
        {
            let mut query = url.query_pairs_mut();
            if let Some(value) = search.q.as_deref().filter(|value| !value.is_empty()) {
                query.append_pair("q", value);
            }
            if let Some(value) = search
                .product_type
                .as_deref()
                .filter(|value| !value.is_empty())
            {
                query.append_pair("type", value);
            }
            if search.availability == Some(CatalogAvailability::InStock) {
                query.append_pair("availability", "in-stock");
            }
            if let Some(value) = search.page {
                query.append_pair("page", &value.to_string());
            }
            if let Some(value) = search.page_size {
                query.append_pair("pageSize", &value.to_string());
            }
        }
        Ok(url)
    }

    fn orders_url(&self) -> Result<Url, ApiError> {
        let mut url = self.endpoint(&["checkout", "orders"])?;
        url.query_pairs_mut()
            .append_pair("buyerId", self.buyer_id()?);
        Ok(url)
    }

    async fn send_json<T, B>(
        &self,
        method: Method,
        segments: &[&str],
        body: &B,
    ) -> Result<T, ApiError>
    where
        T: DeserializeOwned,
        B: Serialize + ?Sized,
    {
        let url = self.endpoint(segments)?;
        self.execute(self.request(method, url).json(body)).await
    }

    pub(crate) fn request(&self, method: Method, url: Url) -> RequestBuilder {
        let mut request = self.http.request(method, url);
        if let Some(session) = &self.session {
            request = request.header("x-demo-principal", session.buyer_id.as_str());
            if let Some(token) = session.access_token.as_deref() {
                request = request.bearer_auth(token);
            }
        }
        request
    }

    pub(crate) fn endpoint(&self, segments: &[&str]) -> Result<Url, ApiError> {
        let mut url = self.base_url.clone();
        let mut path = url
            .path_segments_mut()
            .map_err(|_| ApiError::InvalidBaseUrl(self.base_url.to_string()))?;
        path.pop_if_empty();
        path.extend(segments);
        drop(path);
        Ok(url)
    }

    pub(crate) async fn execute<T>(&self, request: RequestBuilder) -> Result<T, ApiError>
    where
        T: DeserializeOwned,
    {
        let body = self.execute_raw(request).await?;
        Ok(serde_json::from_slice(&body)?)
    }

    async fn resilient_get<T>(&self, url: Url) -> Result<ResilientRead<T>, ApiError>
    where
        T: DeserializeOwned,
    {
        let cache_key = self.cache_key(&url);
        let now = self.runtime.now_unix_ms();
        if let Some(entry) = self.cached_entry(&cache_key) {
            let age_ms = now.saturating_sub(entry.cached_at_unix_ms);
            if age_ms <= duration_ms(self.resilience.fresh_cache_for) {
                if let Ok(value) = serde_json::from_slice(&entry.body) {
                    return Ok(ResilientRead {
                        value,
                        freshness: ReadFreshness {
                            source: ReadSource::Cache,
                            stale: false,
                            cached_at_unix_ms: entry.cached_at_unix_ms,
                            age_ms,
                            attempts: 0,
                        },
                    });
                }
                self.remove_cached_entry(&cache_key);
            }
        }

        let max_attempts = self.resilience.retry.max_attempts.max(1);
        let mut backoff = self.resilience.retry.initial_backoff;
        let mut last_error = None;
        for attempt in 1..=max_attempts {
            match self
                .execute_raw(self.request(Method::GET, url.clone()))
                .await
            {
                Ok(body) => {
                    let value = serde_json::from_slice(&body)?;
                    let cached_at_unix_ms = self.runtime.now_unix_ms();
                    self.store_cached_entry(
                        cache_key.clone(),
                        CacheEntry {
                            body,
                            cached_at_unix_ms,
                        },
                    );
                    return Ok(ResilientRead {
                        value,
                        freshness: ReadFreshness {
                            source: ReadSource::Network,
                            stale: false,
                            cached_at_unix_ms,
                            age_ms: 0,
                            attempts: attempt,
                        },
                    });
                }
                Err(error) if error.is_retryable_get_failure() => {
                    last_error = Some(error);
                    if attempt < max_attempts {
                        self.runtime.sleep(backoff).await;
                        backoff = backoff
                            .saturating_mul(2)
                            .min(self.resilience.retry.max_backoff);
                    }
                }
                Err(error) => return Err(error),
            }
        }

        let error = last_error.expect("resilient GET always performs at least one attempt");
        if let Some(entry) = self.cached_entry(&cache_key) {
            if let Ok(value) = serde_json::from_slice(&entry.body) {
                let now = self.runtime.now_unix_ms();
                return Ok(ResilientRead {
                    value,
                    freshness: ReadFreshness {
                        source: ReadSource::Cache,
                        stale: true,
                        cached_at_unix_ms: entry.cached_at_unix_ms,
                        age_ms: now.saturating_sub(entry.cached_at_unix_ms),
                        attempts: max_attempts,
                    },
                });
            }
            self.remove_cached_entry(&cache_key);
        }
        Err(error)
    }

    async fn execute_raw(&self, request: RequestBuilder) -> Result<Vec<u8>, ApiError> {
        let response = self.transport.send(request.build()?).await?;
        if !response.status.is_success() {
            return Err(ApiError::Http {
                status: response.status.as_u16(),
                message: response_error_message(response.status, &response.body),
            });
        }
        Ok(response.body)
    }

    fn cache_key(&self, url: &Url) -> String {
        let buyer = self
            .session
            .as_ref()
            .map(|session| session.buyer_id.as_str())
            .unwrap_or("anonymous");
        format!("{buyer}|{url}")
    }

    fn cached_entry(&self, key: &str) -> Option<CacheEntry> {
        self.cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(key)
            .cloned()
    }

    fn store_cached_entry(&self, key: String, entry: CacheEntry) {
        self.cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(key, entry);
    }

    fn remove_cached_entry(&self, key: &str) {
        self.cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(key);
    }
}

impl<T> ResilientRead<T> {
    fn map<U>(self, mapper: impl FnOnce(T) -> U) -> ResilientRead<U> {
        ResilientRead {
            value: mapper(self.value),
            freshness: self.freshness,
        }
    }
}

fn duration_ms(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}

fn validate_session(session: &ApiSession) -> Result<(), ApiError> {
    let buyer_id = session.buyer_id.trim();
    let token_is_valid = match session.access_token.as_deref() {
        Some(token) => !token.trim().is_empty(),
        None => true,
    };
    if buyer_id.is_empty() || buyer_id.len() > 120 || !token_is_valid {
        return Err(ApiError::InvalidSession);
    }
    Ok(())
}

fn response_error_message(status: StatusCode, body: &[u8]) -> String {
    #[derive(Deserialize)]
    struct ErrorEnvelope {
        message: Option<serde_json::Value>,
        error: Option<String>,
    }

    if let Ok(envelope) = serde_json::from_slice::<ErrorEnvelope>(body) {
        if let Some(message) = envelope.message {
            let rendered = match message {
                serde_json::Value::String(value) => value,
                serde_json::Value::Array(values) => values
                    .into_iter()
                    .filter_map(|value| value.as_str().map(ToOwned::to_owned))
                    .collect::<Vec<_>>()
                    .join(", "),
                _ => String::new(),
            };
            if !rendered.is_empty() {
                return rendered;
            }
        }
        if let Some(error) = envelope.error.filter(|value| !value.is_empty()) {
            return error;
        }
    }

    let text = String::from_utf8_lossy(body).trim().to_owned();
    if text.is_empty() {
        status
            .canonical_reason()
            .unwrap_or("request failed")
            .to_owned()
    } else {
        text
    }
}

#[derive(Debug, Deserialize)]
struct EventListResponse {
    events: Vec<EventSummary>,
}

#[derive(Debug, Serialize)]
struct QuantityBody {
    quantity: u32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CreateCheckoutSessionBody<'a> {
    cart_id: &'a str,
    buyer_id: &'a str,
    event_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
    shipping_address: &'a ShippingAddress,
    shipping_rate_id: &'a str,
}

#[derive(Debug, Deserialize)]
struct CheckoutOrdersResponse {
    orders: Vec<CheckoutOrder>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::VecDeque;
    use wiremock::{
        matchers::{body_json, header, method, path, query_param},
        Mock, MockServer, ResponseTemplate,
    };

    #[derive(Debug)]
    struct ScriptedResponse {
        status: StatusCode,
        body: Vec<u8>,
    }

    impl ScriptedResponse {
        fn json(status: StatusCode, body: serde_json::Value) -> Self {
            Self {
                status,
                body: serde_json::to_vec(&body).unwrap(),
            }
        }
    }

    #[derive(Debug, Default)]
    struct ScriptedTransport {
        responses: Mutex<VecDeque<ScriptedResponse>>,
        requests: Mutex<Vec<(Method, String)>>,
    }

    impl ScriptedTransport {
        fn new(responses: impl IntoIterator<Item = ScriptedResponse>) -> Self {
            Self {
                responses: Mutex::new(responses.into_iter().collect()),
                requests: Mutex::new(Vec::new()),
            }
        }

        fn requests(&self) -> Vec<(Method, String)> {
            self.requests
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone()
        }
    }

    impl HttpTransport for ScriptedTransport {
        fn send(&self, request: Request) -> TransportFuture {
            self.requests
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push((request.method().clone(), request.url().path().to_owned()));
            let response = self
                .responses
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .pop_front()
                .unwrap_or_else(|| {
                    ScriptedResponse::json(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        json!({"message": "script exhausted"}),
                    )
                });
            Box::pin(async move {
                Ok(TransportResponse {
                    status: response.status,
                    body: response.body,
                })
            })
        }
    }

    #[derive(Debug, Default)]
    struct FakeRuntime {
        now_ms: Mutex<u64>,
        sleeps: Mutex<Vec<Duration>>,
    }

    impl FakeRuntime {
        fn advance(&self, duration: Duration) {
            let mut now = self
                .now_ms
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            *now = now.saturating_add(duration_ms(duration));
        }

        fn sleeps(&self) -> Vec<Duration> {
            self.sleeps
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone()
        }
    }

    impl Runtime for FakeRuntime {
        fn now_unix_ms(&self) -> u64 {
            *self
                .now_ms
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
        }

        fn sleep(&self, duration: Duration) -> SleepFuture<'_> {
            self.sleeps
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(duration);
            self.advance(duration);
            Box::pin(async {})
        }
    }

    fn resilient_client(
        responses: impl IntoIterator<Item = ScriptedResponse>,
    ) -> (ApiClient, Arc<ScriptedTransport>, Arc<FakeRuntime>) {
        let transport = Arc::new(ScriptedTransport::new(responses));
        let runtime = Arc::new(FakeRuntime::default());
        let mut client = ApiClient::new("https://api.example.test").unwrap();
        client.transport = transport.clone();
        client.runtime = runtime.clone();
        client.resilience = ResiliencePolicy {
            fresh_cache_for: Duration::from_secs(1),
            retry: RetryPolicy {
                max_attempts: 3,
                initial_backoff: Duration::from_millis(10),
                max_backoff: Duration::from_millis(20),
            },
        };
        (client, transport, runtime)
    }

    fn event_json() -> serde_json::Value {
        json!({
            "eventId": "sunday-drop",
            "title": "Sunday vintage drop",
            "sellerId": "seller-marsh",
            "sellerName": "Marsh & Co Vintage",
            "status": "live",
            "startsAt": "2026-08-14T12:00:00.000Z",
            "endedAt": null,
            "thumbnailUrl": "https://example.test/drop.png",
            "playbackUrl": "https://media.example.test/sidestage-sunday-drop/whep",
            "viewers": 14
        })
    }

    fn event_list_json() -> serde_json::Value {
        json!({"events": [event_json()]})
    }

    fn cart_json() -> serde_json::Value {
        json!({
            "id": "cart-1",
            "currency": "USD",
            "items": [{
                "productId": "mug/red",
                "title": "Red mug",
                "priceCents": 2400,
                "quantity": 1
            }],
            "subtotalCents": 2400,
            "updatedAt": "2026-08-14T12:01:00.000Z"
        })
    }

    fn address() -> ShippingAddress {
        ShippingAddress {
            name: "Avi Buyer".into(),
            line1: "1 Main St".into(),
            line2: None,
            city: "Brooklyn".into(),
            state: "NY".into(),
            postal_code: "11201".into(),
            country: "US".into(),
            phone: None,
        }
    }

    #[tokio::test]
    async fn resilient_read_covers_cache_miss_hit_and_stale_fallback_without_sleeping() {
        let unavailable = || {
            ScriptedResponse::json(
                StatusCode::SERVICE_UNAVAILABLE,
                json!({"message": "temporary outage"}),
            )
        };
        let (client, transport, runtime) = resilient_client([
            ScriptedResponse::json(StatusCode::OK, event_list_json()),
            unavailable(),
            unavailable(),
            unavailable(),
        ]);

        let cache_miss = client.resilient_events().await.unwrap();
        assert_eq!(cache_miss.freshness.source, ReadSource::Network);
        assert!(!cache_miss.freshness.stale);
        assert_eq!(cache_miss.freshness.attempts, 1);

        let cache_hit = client.resilient_events().await.unwrap();
        assert_eq!(cache_hit.freshness.source, ReadSource::Cache);
        assert!(!cache_hit.freshness.stale);
        assert_eq!(cache_hit.freshness.attempts, 0);
        assert_eq!(transport.requests().len(), 1);

        runtime.advance(Duration::from_millis(1_001));
        let stale = client.resilient_events().await.unwrap();
        assert_eq!(stale.value, cache_miss.value);
        assert_eq!(stale.freshness.source, ReadSource::Cache);
        assert!(stale.freshness.stale);
        assert_eq!(stale.freshness.attempts, 3);
        assert!(stale.freshness.age_ms >= 1_001);
        assert_eq!(transport.requests().len(), 4);
        assert_eq!(
            runtime.sleeps(),
            vec![Duration::from_millis(10), Duration::from_millis(20)]
        );
    }

    #[tokio::test]
    async fn resilient_get_retries_then_succeeds_with_bounded_backoff() {
        let (client, transport, runtime) = resilient_client([
            ScriptedResponse::json(
                StatusCode::SERVICE_UNAVAILABLE,
                json!({"message": "retry me"}),
            ),
            ScriptedResponse::json(StatusCode::OK, event_list_json()),
        ]);

        let result = client.resilient_events().await.unwrap();
        assert_eq!(result.freshness.source, ReadSource::Network);
        assert_eq!(result.freshness.attempts, 2);
        assert_eq!(transport.requests().len(), 2);
        assert_eq!(runtime.sleeps(), vec![Duration::from_millis(10)]);
    }

    #[tokio::test]
    async fn resilient_get_exhausts_retries_on_cache_miss() {
        let unavailable = || {
            ScriptedResponse::json(
                StatusCode::SERVICE_UNAVAILABLE,
                json!({"message": "still unavailable"}),
            )
        };
        let (client, transport, runtime) =
            resilient_client([unavailable(), unavailable(), unavailable()]);

        let error = client.resilient_events().await.unwrap_err();
        assert!(matches!(
            error,
            ApiError::Http {
                status: 503,
                ref message
            } if message == "still unavailable"
        ));
        assert_eq!(transport.requests().len(), 3);
        assert_eq!(
            runtime.sleeps(),
            vec![Duration::from_millis(10), Duration::from_millis(20)]
        );
    }

    #[tokio::test]
    async fn mutating_request_never_enters_get_retry_loop() {
        let (client, transport, runtime) = resilient_client([
            ScriptedResponse::json(
                StatusCode::SERVICE_UNAVAILABLE,
                json!({"message": "do not replay mutation"}),
            ),
            ScriptedResponse::json(StatusCode::OK, cart_json()),
        ]);

        let error = client
            .add_cart_item(&AddCartItemRequest {
                cart_id: Some("cart-1".into()),
                product_id: "mug/red".into(),
                title: "Red mug".into(),
                price_cents: 2400,
                quantity: 1,
                image_url: None,
            })
            .await
            .unwrap_err();

        assert!(matches!(error, ApiError::Http { status: 503, .. }));
        assert_eq!(
            transport.requests(),
            vec![(Method::POST, "/cart/items".into())]
        );
        assert!(runtime.sleeps().is_empty());
    }

    #[tokio::test]
    async fn preserves_api_prefix_and_resolves_event_detail_from_feed() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/events"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "events": [event_json()]
            })))
            .expect(2)
            .mount(&server)
            .await;

        let client = ApiClient::new(format!("{}/api", server.uri())).unwrap();
        assert_eq!(client.events().await.unwrap().len(), 1);
        let event = client.event("sunday-drop").await.unwrap();
        assert_eq!(event.seller_name, "Marsh & Co Vintage");
        // D-035: playback location arrives FROM the API; the client derives nothing.
        assert_eq!(
            event.playback_url.as_deref(),
            Some("https://media.example.test/sidestage-sunday-drop/whep")
        );
    }

    #[tokio::test]
    async fn catalog_search_stays_api_proxied_and_encodes_filters() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/catalog"))
            .and(query_param("q", "mug & bowl"))
            .and(query_param("type", "HOME GOODS"))
            .and(query_param("availability", "in-stock"))
            .and(query_param("page", "2"))
            .and(query_param("pageSize", "24"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "rows": [{
                    "id": "mug/red",
                    "groupId": "mug",
                    "title": "Red mug",
                    "brand": "SideStage",
                    "productType": "HOME GOODS",
                    "sku": "MUG-RED",
                    "condition": "NEW",
                    "handlingDays": 2,
                    "priceCents": 2400,
                    "availableQty": 8
                }],
                "page": 2,
                "pageSize": 24,
                "total": 1,
                "totalIsFloor": false
            })))
            .mount(&server)
            .await;

        let result = ApiClient::new(server.uri())
            .unwrap()
            .catalog(&CatalogSearch {
                q: Some("mug & bowl".into()),
                product_type: Some("HOME GOODS".into()),
                availability: Some(CatalogAvailability::InStock),
                page: Some(2),
                page_size: Some(24),
            })
            .await
            .unwrap();

        assert_eq!(result.rows[0].id, "mug/red");
    }

    #[tokio::test]
    async fn propagates_session_and_uses_typed_cart_paths() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/cart/items"))
            .and(header("authorization", "Bearer mobile-token"))
            .and(header("x-demo-principal", "buyer-mobile"))
            .and(body_json(json!({
                "cartId": "cart-1",
                "productId": "mug/red",
                "title": "Red mug",
                "priceCents": 2400,
                "quantity": 1
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(cart_json()))
            .mount(&server)
            .await;

        let client = ApiClient::new(server.uri())
            .unwrap()
            .with_session(ApiSession {
                buyer_id: "buyer-mobile".into(),
                access_token: Some("mobile-token".into()),
            })
            .unwrap();
        let cart = client
            .add_cart_item(&AddCartItemRequest {
                cart_id: Some("cart-1".into()),
                product_id: "mug/red".into(),
                title: "Red mug".into(),
                price_cents: 2400,
                quantity: 1,
                image_url: None,
            })
            .await
            .unwrap();

        assert_eq!(cart.subtotal_cents, 2400);
    }

    #[tokio::test]
    async fn checkout_sends_rate_identity_and_never_client_shipping_cents() {
        let server = MockServer::start().await;
        let shipping_address = address();
        Mock::given(method("POST"))
            .and(path("/shipping/rates"))
            .and(header("x-demo-principal", "buyer-mobile"))
            .and(body_json(json!({
                "cartId": "cart-1",
                "address": shipping_address
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!([{
                "id": "USPS:Priority",
                "carrier": "USPS",
                "service": "Priority",
                "totalCents": 895,
                "deliveryDays": 3,
                "parcelCount": 1,
                "quotedAt": "2026-08-14T12:01:30.000Z"
            }])))
            .mount(&server)
            .await;

        Mock::given(method("POST"))
            .and(path("/checkout/sessions"))
            .and(header("x-demo-principal", "buyer-mobile"))
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
                "order": {
                    "id": "order-1",
                    "cartId": "cart-1",
                    "buyerId": "buyer-mobile",
                    "eventId": "sunday-drop",
                    "email": "buyer@example.test",
                    "subtotalCents": 2400,
                    "shippingCents": 895,
                    "totalCents": 3295,
                    "currency": "USD",
                    "status": "pending",
                    "createdAt": "2026-08-14T12:02:00.000Z",
                    "items": cart_json()["items"],
                    "paymentSession": {
                        "provider": "square",
                        "mode": "sandbox",
                        "status": "ready",
                        "appId": "sandbox-app",
                        "locationId": "sandbox-location",
                        "orderId": "order-1",
                        "amountCents": 3295,
                        "currency": "USD"
                    }
                },
                "session": {
                    "provider": "square",
                    "mode": "sandbox",
                    "status": "ready",
                    "appId": "sandbox-app",
                    "locationId": "sandbox-location",
                    "orderId": "order-1",
                    "amountCents": 3295,
                    "currency": "USD"
                }
            })))
            .mount(&server)
            .await;

        let client = ApiClient::new(server.uri())
            .unwrap()
            .with_session(ApiSession::anonymous("buyer-mobile"))
            .unwrap();
        let rates = client
            .shipping_rates(&ShippingRatesRequest {
                cart_id: "cart-1".into(),
                address: address(),
            })
            .await
            .unwrap();
        let checkout = client
            .create_checkout_session(&CreateCheckoutSessionRequest {
                cart_id: "cart-1".into(),
                event_id: "sunday-drop".into(),
                email: Some("buyer@example.test".into()),
                name: Some("Avi Buyer".into()),
                shipping_address: address(),
                shipping_rate_id: rates[0].id.clone(),
            })
            .await
            .unwrap();

        assert_eq!(checkout.order.shipping_cents, 895);
        assert_eq!(checkout.session.provider, PaymentProvider::Square);
    }

    #[tokio::test]
    async fn surfaces_nest_error_message_with_status() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/cart/missing"))
            .respond_with(ResponseTemplate::new(404).set_body_json(json!({
                "statusCode": 404,
                "message": "Cart missing was not found",
                "error": "Not Found"
            })))
            .mount(&server)
            .await;

        let error = ApiClient::new(server.uri())
            .unwrap()
            .cart("missing")
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            ApiError::Http {
                status: 404,
                ref message
            } if message == "Cart missing was not found"
        ));
    }
}
