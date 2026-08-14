// SPDX-License-Identifier: MIT

//! Buyer-facing live event state over the SideStage sync contract.

use std::{
    hash::{Hash, Hasher},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use futures_util::StreamExt;
use reqwest::{header::ACCEPT, Method, Response, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::{
    sync::{mpsc, watch, Mutex},
    time::{Instant, MissedTickBehavior},
};

use crate::{ApiClient, ApiError, CatalogVariant};

const TRANSCRIPT_QUERY: &str = "event.chat.messages";
const AUCTION_QUERY: &str = "event.auction.active";
const CATALOG_QUERY: &str = "catalog.page";
const INVENTORY_QUERY: &str = "inventory.snapshot";

fn sync_error(status: StatusCode, message: impl Into<String>) -> ApiError {
    ApiError::Http {
        status: status.as_u16(),
        message: message.into(),
    }
}

#[derive(Debug, Clone)]
pub struct LiveEventSyncConfig {
    pub poll_interval: Duration,
    pub heartbeat_timeout: Duration,
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
}

impl Default for LiveEventSyncConfig {
    fn default() -> Self {
        Self {
            poll_interval: Duration::from_secs(10),
            heartbeat_timeout: Duration::from_secs(30),
            initial_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(30),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "kind")]
pub enum LiveSyncStatus {
    Connecting,
    Live,
    Polling { retry_in_ms: u64 },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventTranscriptEntry {
    pub id: String,
    pub event_id: String,
    pub user_id: String,
    pub display_name: String,
    pub role: ChatRole,
    pub text: String,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grounding: Option<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    Buyer,
    Seller,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuctionBid {
    pub id: String,
    pub bidder_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub amount_cents: i64,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuctionStatus {
    Active,
    Closed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveAuction {
    pub id: String,
    pub event_id: String,
    pub event_item_id: String,
    pub product_id: String,
    pub quantity: u32,
    pub starting_price_cents: i64,
    pub current_price_cents: i64,
    pub status: AuctionStatus,
    pub started_at: String,
    pub ends_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub closed_at: Option<String>,
    pub bids: Vec<AuctionBid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub winner_order: Option<Value>,
}

impl LiveAuction {
    /// `true` while the auction still accepts bids.
    ///
    /// This is the *status* the API last published. The server also closes an
    /// auction lazily on the next write once `ends_at` has passed, so a shell
    /// must treat a stale `Active` as advisory and let the API arbitrate.
    pub fn is_open(&self) -> bool {
        matches!(self.status, AuctionStatus::Active)
    }

    /// The highest bid, or `None` when nobody has bid yet.
    ///
    /// The API returns `bids` sorted by amount descending, then oldest-first on
    /// a tie. We do not re-sort: taking the first entry keeps the shells
    /// agreeing with the server about who is leading.
    pub fn leading_bid(&self) -> Option<&AuctionBid> {
        self.bids.first()
    }

    /// The smallest amount the API will accept: strictly above the current price.
    ///
    /// Mirrors `AuctionService::placeBid`, which rejects
    /// `amountCents <= currentPriceCents` with HTTP 409.
    pub fn minimum_next_bid_cents(&self) -> i64 {
        minimum_next_bid_cents(self.current_price_cents)
    }

    /// The pre-filled bid the buyer sees, matching the web buyer panel's
    /// `suggestedBidCents`: one whole dollar, or 5% rounded up to a whole
    /// dollar — whichever is larger.
    pub fn suggested_bid_cents(&self) -> i64 {
        suggested_bid_cents(self.current_price_cents)
    }

    /// Whether `amount_cents` clears the server's minimum for this auction.
    pub fn accepts_bid(&self, amount_cents: i64) -> bool {
        self.is_open() && amount_cents >= self.minimum_next_bid_cents()
    }
}

/// The exclusive lower bound the API enforces: `placeBid` rejects any amount
/// at or below the current price with HTTP 409.
pub fn minimum_next_bid_cents(current_price_cents: i64) -> i64 {
    current_price_cents.saturating_add(1)
}

/// Shared bid-ladder rule, kept identical to the web buyer panel so a buyer
/// sees the same pre-filled amount on every surface.
pub fn suggested_bid_cents(current_price_cents: i64) -> i64 {
    // `Math.ceil((current * 0.05) / 100) * 100` in exact integer arithmetic:
    // five percent of the price, rounded UP to a whole dollar.
    let five_percent = current_price_cents.max(0).saturating_mul(5);
    let whole_dollars = (five_percent + 9_999) / 10_000;
    let increment = whole_dollars.saturating_mul(100).max(100);
    current_price_cents.saturating_add(increment)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaceBidRequest {
    #[serde(skip)]
    pub auction_id: String,
    pub bidder_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub amount_cents: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveEventSnapshot {
    pub event_id: String,
    pub transcript: Vec<EventTranscriptEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_deck_product: Option<CatalogVariant>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auction: Option<LiveAuction>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum LiveEventUpdate {
    Status { status: LiveSyncStatus },
    Snapshot { snapshot: Box<LiveEventSnapshot> },
    Error { message: String },
}

pub struct LiveEventSync {
    rx: Mutex<mpsc::Receiver<LiveEventUpdate>>,
    shutdown: watch::Sender<bool>,
}

impl LiveEventSync {
    pub async fn next_event(&self) -> Option<LiveEventUpdate> {
        self.rx.lock().await.recv().await
    }

    pub fn close(&self) {
        let _ = self.shutdown.send(true);
    }
}

impl Drop for LiveEventSync {
    fn drop(&mut self) {
        self.close();
    }
}

impl ApiClient {
    pub fn live_event_sync(&self, event_id: impl Into<String>) -> Result<LiveEventSync, ApiError> {
        self.live_event_sync_with_config(event_id, LiveEventSyncConfig::default())
    }

    pub fn live_event_sync_with_config(
        &self,
        event_id: impl Into<String>,
        config: LiveEventSyncConfig,
    ) -> Result<LiveEventSync, ApiError> {
        let event_id = event_id.into();
        if event_id.trim().is_empty() || event_id.len() > 120 {
            return Err(sync_error(
                StatusCode::BAD_REQUEST,
                "eventId is required and must be 120 characters or fewer",
            ));
        }
        if config.poll_interval.is_zero()
            || config.heartbeat_timeout.is_zero()
            || config.initial_backoff.is_zero()
            || config.max_backoff < config.initial_backoff
        {
            return Err(sync_error(
                StatusCode::BAD_REQUEST,
                "invalid live sync timing configuration",
            ));
        }

        let (tx, rx) = mpsc::channel(64);
        let (shutdown, shutdown_rx) = watch::channel(false);
        tokio::spawn(run_live_sync(
            self.clone(),
            event_id,
            config,
            tx,
            shutdown_rx,
        ));
        Ok(LiveEventSync {
            rx: Mutex::new(rx),
            shutdown,
        })
    }

    async fn live_event_snapshot(&self, event_id: &str) -> Result<LiveEventSnapshot, ApiError> {
        let url = self.endpoint(&["sync", "rest-query-batch"])?;
        let body = json!({
            "queries": [
                { "name": TRANSCRIPT_QUERY, "args": { "eventId": event_id } },
                { "name": AUCTION_QUERY, "args": { "eventId": event_id } }
            ]
        });
        let response = self.request(Method::POST, url).json(&body).send().await?;
        let status = response.status();
        let bytes = response.bytes().await?;
        if !status.is_success() {
            return Err(ApiError::Http {
                status: status.as_u16(),
                message: String::from_utf8_lossy(&bytes).trim().to_owned(),
            });
        }
        let mut batch: SyncBatchResponse = serde_json::from_slice(&bytes)?;
        if batch.results.len() != 2 {
            return Err(sync_error(
                StatusCode::BAD_GATEWAY,
                format!("expected 2 batch results, received {}", batch.results.len()),
            ));
        }
        for result in &batch.results {
            if let Some(error) = result.error.as_deref() {
                return Err(sync_error(StatusCode::BAD_GATEWAY, error));
            }
        }

        let auction_rows = batch.results.pop().expect("batch length checked").rows;
        let transcript_rows = batch.results.pop().expect("batch length checked").rows;
        let transcript = serde_json::from_value(Value::Array(transcript_rows))?;
        let auction: Option<LiveAuction> = auction_rows
            .into_iter()
            .next()
            .map(serde_json::from_value)
            .transpose()?;
        let on_deck_product = match &auction {
            Some(auction) => Some(self.product(&auction.product_id).await?),
            None => None,
        };

        Ok(LiveEventSnapshot {
            event_id: event_id.to_owned(),
            transcript,
            on_deck_product,
            auction,
        })
    }

    /// Place a bid on a live auction: `POST /auctions/{auctionId}/bids`.
    ///
    /// Returns the auction as the API re-published it, so the caller renders
    /// the authoritative price and bid ladder rather than a local guess. The
    /// realtime stream also carries the same update to every other buyer.
    ///
    /// Server-side rejections surface as [`ApiError::Http`] — notably `409`
    /// for a closed auction or a bid at or below the current price. The local
    /// argument checks below only catch inputs the API could never accept, so
    /// the shells never spend a round trip on an empty field.
    pub async fn place_bid(&self, request: &PlaceBidRequest) -> Result<LiveAuction, ApiError> {
        let auction_id = request.auction_id.trim();
        if auction_id.is_empty() || auction_id.len() > 120 {
            return Err(sync_error(
                StatusCode::BAD_REQUEST,
                "auctionId is required and must be 120 characters or fewer",
            ));
        }
        if request.bidder_id.trim().is_empty() {
            return Err(sync_error(StatusCode::BAD_REQUEST, "bidderId is required"));
        }
        if request.amount_cents <= 0 {
            return Err(sync_error(
                StatusCode::BAD_REQUEST,
                "amountCents must be a positive integer",
            ));
        }
        let url = self.endpoint(&["auctions", auction_id, "bids"])?;
        self.execute(self.request(Method::POST, url).json(request))
            .await
    }

    async fn open_live_stream(&self, event_id: &str) -> Result<Response, ApiError> {
        let mut url = self.endpoint(&["sync", "sse"])?;
        url.query_pairs_mut().append_pair("eventId", event_id);
        let response = self
            .request(Method::GET, url)
            .header(ACCEPT, "text/event-stream")
            .send()
            .await?;
        if !response.status().is_success() {
            let status = response.status();
            let body = response.bytes().await?;
            return Err(ApiError::Http {
                status: status.as_u16(),
                message: String::from_utf8_lossy(&body).trim().to_owned(),
            });
        }
        Ok(response)
    }
}

#[derive(Debug, Deserialize)]
struct SyncBatchResponse {
    results: Vec<SyncResult>,
}

#[derive(Debug, Deserialize)]
struct SyncResult {
    rows: Vec<Value>,
    #[allow(dead_code)]
    version: String,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Invalidation {
    name: String,
    args: Option<Value>,
    #[allow(dead_code)]
    ts_ms: Option<u64>,
}

async fn run_live_sync(
    client: ApiClient,
    event_id: String,
    config: LiveEventSyncConfig,
    tx: mpsc::Sender<LiveEventUpdate>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut current = None;
    let mut poll = tokio::time::interval(config.poll_interval);
    poll.set_missed_tick_behavior(MissedTickBehavior::Skip);
    poll.tick().await;
    if !refresh_snapshot(&client, &event_id, &tx, &mut current).await {
        return;
    }

    let mut backoff = config.initial_backoff;
    let mut attempt = 0_u64;
    loop {
        if stopped(&shutdown) || !send_status(&tx, LiveSyncStatus::Connecting).await {
            return;
        }
        match client.open_live_stream(&event_id).await {
            Ok(response) => {
                backoff = config.initial_backoff;
                attempt = 0;
                if !send_status(&tx, LiveSyncStatus::Live).await {
                    return;
                }
                if stream_session(
                    &client,
                    &event_id,
                    response,
                    &config,
                    &tx,
                    &mut shutdown,
                    &mut poll,
                    &mut current,
                )
                .await
                {
                    return;
                }
            }
            Err(error) => {
                if !send_error(&tx, error).await {
                    return;
                }
            }
        }

        attempt += 1;
        let retry = jittered(backoff, &event_id, attempt);
        if !send_status(
            &tx,
            LiveSyncStatus::Polling {
                retry_in_ms: retry.as_millis().min(u128::from(u64::MAX)) as u64,
            },
        )
        .await
        {
            return;
        }
        let deadline = Instant::now() + retry;
        loop {
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || stopped(&shutdown) { return; }
                }
                _ = tokio::time::sleep_until(deadline) => break,
                _ = poll.tick() => {
                    if !refresh_snapshot(&client, &event_id, &tx, &mut current).await { return; }
                }
            }
        }
        backoff = backoff.saturating_mul(2).min(config.max_backoff);
    }
}

#[allow(clippy::too_many_arguments)]
async fn stream_session(
    client: &ApiClient,
    event_id: &str,
    response: Response,
    config: &LiveEventSyncConfig,
    tx: &mpsc::Sender<LiveEventUpdate>,
    shutdown: &mut watch::Receiver<bool>,
    poll: &mut tokio::time::Interval,
    current: &mut Option<LiveEventSnapshot>,
) -> bool {
    let mut stream = response.bytes_stream();
    let mut decoder = SseDecoder::default();
    let mut last_activity = Instant::now();
    loop {
        let zombie_deadline = last_activity + config.heartbeat_timeout;
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || stopped(shutdown) { return true; }
            }
            _ = tokio::time::sleep_until(zombie_deadline) => {
                let _ = send_error(
                    tx,
                    sync_error(StatusCode::GATEWAY_TIMEOUT, "SSE heartbeat timed out"),
                )
                .await;
                return false;
            }
            _ = poll.tick() => {
                if !refresh_snapshot(client, event_id, tx, current).await { return true; }
            }
            chunk = stream.next() => match chunk {
                Some(Ok(bytes)) => {
                    let frames = decoder.push(&bytes);
                    if !frames.is_empty() { last_activity = Instant::now(); }
                    for frame in frames {
                        if frame.event == "heartbeat" { continue; }
                        if !matches!(frame.event.as_str(), "invalidate" | "update") { continue; }
                        let invalidation = match serde_json::from_str::<Invalidation>(&frame.data) {
                            Ok(value) => value,
                            Err(error) => {
                                if !send_error(tx, ApiError::Decode(error)).await { return true; }
                                continue;
                            }
                        };
                        if invalidates_snapshot(&invalidation, event_id)
                            && !refresh_snapshot(client, event_id, tx, current).await
                        {
                            return true;
                        }
                    }
                }
                Some(Err(error)) => {
                    let _ = send_error(tx, ApiError::Transport(error)).await;
                    return false;
                }
                None => return false,
            }
        }
    }
}

async fn refresh_snapshot(
    client: &ApiClient,
    event_id: &str,
    tx: &mpsc::Sender<LiveEventUpdate>,
    current: &mut Option<LiveEventSnapshot>,
) -> bool {
    match client.live_event_snapshot(event_id).await {
        Ok(snapshot) => {
            if current.as_ref() != Some(&snapshot) {
                *current = Some(snapshot.clone());
                tx.send(LiveEventUpdate::Snapshot {
                    snapshot: Box::new(snapshot),
                })
                .await
                .is_ok()
            } else {
                true
            }
        }
        Err(error) => send_error(tx, error).await,
    }
}

fn invalidates_snapshot(invalidation: &Invalidation, event_id: &str) -> bool {
    if !matches!(
        invalidation.name.as_str(),
        TRANSCRIPT_QUERY | AUCTION_QUERY | CATALOG_QUERY | INVENTORY_QUERY
    ) {
        return false;
    }
    invalidation
        .args
        .as_ref()
        .and_then(|args| args.get("eventId"))
        .and_then(Value::as_str)
        .is_none_or(|candidate| candidate == event_id)
}

async fn send_status(tx: &mpsc::Sender<LiveEventUpdate>, status: LiveSyncStatus) -> bool {
    tx.send(LiveEventUpdate::Status { status }).await.is_ok()
}

async fn send_error(tx: &mpsc::Sender<LiveEventUpdate>, error: ApiError) -> bool {
    tx.send(LiveEventUpdate::Error {
        message: error.to_string(),
    })
    .await
    .is_ok()
}

fn stopped(shutdown: &watch::Receiver<bool>) -> bool {
    *shutdown.borrow()
}

fn jittered(base: Duration, event_id: &str, attempt: u64) -> Duration {
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    event_id.hash(&mut hasher);
    attempt.hash(&mut hasher);
    seed.hash(&mut hasher);
    let unit = hasher.finish() as f64 / u64::MAX as f64;
    let multiplier = 0.8 + unit * 0.4;
    Duration::from_secs_f64((base.as_secs_f64() * multiplier).max(0.001))
}

#[derive(Debug, PartialEq, Eq)]
struct SseFrame {
    event: String,
    data: String,
    #[allow(dead_code)]
    id: Option<String>,
}

#[derive(Default)]
struct SseDecoder {
    buffer: Vec<u8>,
}

impl SseDecoder {
    fn push(&mut self, chunk: &[u8]) -> Vec<SseFrame> {
        self.buffer.extend_from_slice(chunk);
        let mut frames = Vec::new();
        while let Some((position, delimiter_len)) = frame_boundary(&self.buffer) {
            let frame = self.buffer.drain(..position).collect::<Vec<_>>();
            self.buffer.drain(..delimiter_len);
            if let Some(frame) = parse_sse_frame(&String::from_utf8_lossy(&frame)) {
                frames.push(frame);
            }
        }
        frames
    }
}

fn frame_boundary(buffer: &[u8]) -> Option<(usize, usize)> {
    buffer
        .windows(2)
        .position(|window| window == b"\n\n")
        .map(|position| (position, 2))
        .into_iter()
        .chain(
            buffer
                .windows(4)
                .position(|window| window == b"\r\n\r\n")
                .map(|position| (position, 4)),
        )
        .min_by_key(|(position, _)| *position)
}

fn parse_sse_frame(raw: &str) -> Option<SseFrame> {
    let mut event = "message".to_owned();
    let mut data = Vec::new();
    let mut id = None;
    for line in raw.lines() {
        if line.starts_with(':') {
            continue;
        }
        let (field, value) = line.split_once(':').unwrap_or((line, ""));
        let value = value.strip_prefix(' ').unwrap_or(value);
        match field {
            "event" => event = value.to_owned(),
            "data" => data.push(value),
            "id" => id = Some(value.to_owned()),
            _ => {}
        }
    }
    (!data.is_empty()).then(|| SseFrame {
        event,
        data: data.join("\n"),
        id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use wiremock::{
        matchers::{body_json, method, path, query_param},
        Mock, MockServer, ResponseTemplate,
    };

    fn empty_batch() -> Value {
        json!({
            "results": [
                { "rows": [], "version": "1" },
                { "rows": [], "version": "1" }
            ]
        })
    }

    #[test]
    fn decodes_chunked_crlf_frames_and_multiline_data() {
        let mut decoder = SseDecoder::default();
        assert!(decoder.push(b"id: 7\r\nevent: inval").is_empty());
        let frames =
            decoder.push(b"idate\r\ndata: {\"name\":\r\ndata: \"event.chat.messages\"}\r\n\r\n");
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].event, "invalidate");
        assert_eq!(frames[0].id.as_deref(), Some("7"));
        assert_eq!(frames[0].data, "{\"name\":\n\"event.chat.messages\"}");
    }

    #[test]
    fn scopes_event_invalidations_and_keeps_global_catalog_refreshes() {
        let scoped = Invalidation {
            name: AUCTION_QUERY.into(),
            args: Some(json!({ "eventId": "event-a" })),
            ts_ms: None,
        };
        assert!(invalidates_snapshot(&scoped, "event-a"));
        assert!(!invalidates_snapshot(&scoped, "event-b"));
        assert!(invalidates_snapshot(
            &Invalidation {
                name: CATALOG_QUERY.into(),
                args: None,
                ts_ms: None
            },
            "event-b"
        ));
    }

    #[tokio::test]
    async fn reads_transcript_auction_and_on_deck_product_from_authoritative_rest() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/sync/rest-query-batch"))
            .and(body_json(json!({
                "queries": [
                    { "name": TRANSCRIPT_QUERY, "args": { "eventId": "drop" } },
                    { "name": AUCTION_QUERY, "args": { "eventId": "drop" } }
                ]
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "results": [
                    { "rows": [{
                        "id": "message-1", "eventId": "drop", "userId": "buyer-1",
                        "displayName": "Avi", "role": "buyer", "text": "Show the base",
                        "createdAt": "2026-08-14T12:00:00Z"
                    }], "version": "1" },
                    { "rows": [{
                        "id": "auction-1", "eventId": "drop", "eventItemId": "item-1",
                        "productId": "mug/red", "quantity": 1, "startingPriceCents": 2000,
                        "currentPriceCents": 2400, "status": "active",
                        "startedAt": "2026-08-14T12:00:00Z", "endsAt": "2026-08-14T12:01:00Z",
                        "bids": []
                    }], "version": "1" }
                ]
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/catalog/variants/mug%2Fred"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "id": "mug/red", "groupId": "mug", "title": "Red mug", "brand": "SideStage",
                "productType": "HOME GOODS", "sku": "MUG-RED", "condition": "NEW",
                "handlingDays": 2, "priceCents": 2400, "availableQty": 8
            })))
            .mount(&server)
            .await;

        let snapshot = ApiClient::new(server.uri())
            .unwrap()
            .live_event_snapshot("drop")
            .await
            .unwrap();
        assert_eq!(snapshot.transcript[0].text, "Show the base");
        assert_eq!(snapshot.auction.as_ref().unwrap().current_price_cents, 2400);
        assert_eq!(snapshot.on_deck_product.as_ref().unwrap().id, "mug/red");
    }

    fn auction_at(current_price_cents: i64, status: AuctionStatus) -> LiveAuction {
        LiveAuction {
            id: "auction-1".into(),
            event_id: "drop".into(),
            event_item_id: "item-1".into(),
            product_id: "mug/red".into(),
            quantity: 1,
            starting_price_cents: 2_000,
            current_price_cents,
            status,
            started_at: "2026-08-14T12:00:00Z".into(),
            ends_at: "2026-08-14T12:01:00Z".into(),
            closed_at: None,
            bids: Vec::new(),
            winner_order: None,
        }
    }

    #[test]
    fn suggested_bid_matches_the_web_buyer_ladder() {
        // Pinned to apps/web/src/auction.ts `suggestedBidCents`, whose own
        // tests assert exactly these two pairs.
        assert_eq!(suggested_bid_cents(2_400), 2_600);
        assert_eq!(suggested_bid_cents(900), 1_000);
        // Below the point where 5% reaches a dollar, the floor is one dollar.
        assert_eq!(suggested_bid_cents(0), 100);
        // A price landing exactly on a whole dollar of 5% must not round up
        // an extra dollar: 5% of $20.00 is exactly $1.00.
        assert_eq!(suggested_bid_cents(2_000), 2_100);
    }

    #[test]
    fn minimum_next_bid_is_strictly_above_the_current_price() {
        let auction = auction_at(2_400, AuctionStatus::Active);
        assert_eq!(auction.minimum_next_bid_cents(), 2_401);
        // The API rejects `amountCents <= currentPriceCents`, so the boundary
        // has to be exclusive on the low side.
        assert!(!auction.accepts_bid(2_400));
        assert!(auction.accepts_bid(2_401));
    }

    #[test]
    fn a_closed_auction_accepts_no_bid_however_large() {
        let auction = auction_at(2_400, AuctionStatus::Closed);
        assert!(!auction.is_open());
        assert!(!auction.accepts_bid(1_000_000));
    }

    #[test]
    fn leading_bid_trusts_the_server_ordering() {
        let mut auction = auction_at(2_400, AuctionStatus::Active);
        auction.bids = vec![
            AuctionBid {
                id: "bid-2".into(),
                bidder_id: "buyer-2".into(),
                display_name: Some("Avi".into()),
                amount_cents: 2_400,
                created_at: "2026-08-14T12:00:30Z".into(),
            },
            AuctionBid {
                id: "bid-1".into(),
                bidder_id: "buyer-1".into(),
                display_name: None,
                amount_cents: 2_200,
                created_at: "2026-08-14T12:00:10Z".into(),
            },
        ];
        assert_eq!(auction.leading_bid().unwrap().bidder_id, "buyer-2");
        assert!(auction_at(2_400, AuctionStatus::Active)
            .leading_bid()
            .is_none());
    }

    #[tokio::test]
    async fn place_bid_posts_to_the_auction_and_returns_the_republished_auction() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/auctions/auction-1/bids"))
            // `auction_id` rides in the URL, never the body — the API's
            // PlaceBidInput has exactly these three fields.
            .and(body_json(json!({
                "bidderId": "buyer-1",
                "displayName": "Avi",
                "amountCents": 2_600
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "id": "auction-1", "eventId": "drop", "eventItemId": "item-1",
                "productId": "mug/red", "quantity": 1, "startingPriceCents": 2000,
                "currentPriceCents": 2600, "status": "active",
                "startedAt": "2026-08-14T12:00:00Z", "endsAt": "2026-08-14T12:01:00Z",
                "bids": [{
                    "id": "bid-1", "bidderId": "buyer-1", "displayName": "Avi",
                    "amountCents": 2600, "createdAt": "2026-08-14T12:00:30Z"
                }]
            })))
            .mount(&server)
            .await;

        let auction = ApiClient::new(server.uri())
            .unwrap()
            .place_bid(&PlaceBidRequest {
                auction_id: "auction-1".into(),
                bidder_id: "buyer-1".into(),
                display_name: Some("Avi".into()),
                amount_cents: 2_600,
            })
            .await
            .unwrap();

        assert_eq!(auction.current_price_cents, 2_600);
        assert_eq!(auction.leading_bid().unwrap().amount_cents, 2_600);
    }

    #[tokio::test]
    async fn place_bid_surfaces_the_conflict_status_when_the_api_rejects_it() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/auctions/auction-1/bids"))
            .respond_with(ResponseTemplate::new(409).set_body_json(json!({
                "message": "Bid must be greater than the current price of 2600 cents"
            })))
            .mount(&server)
            .await;

        let error = ApiClient::new(server.uri())
            .unwrap()
            .place_bid(&PlaceBidRequest {
                auction_id: "auction-1".into(),
                bidder_id: "buyer-1".into(),
                display_name: None,
                amount_cents: 2_400,
            })
            .await
            .unwrap_err();

        // The shells branch on 409 to say "someone outbid you" rather than
        // showing a generic failure, so the status must survive the boundary.
        assert!(matches!(error, ApiError::Http { status: 409, .. }));
    }

    #[tokio::test]
    async fn place_bid_rejects_unusable_input_without_a_round_trip() {
        let server = MockServer::start().await;
        // No mock is mounted: any outbound request would 404 and fail the
        // `BAD_REQUEST` assertions below.
        let client = ApiClient::new(server.uri()).unwrap();

        for (auction_id, bidder_id, amount_cents) in [
            ("", "buyer-1", 2_600),
            ("auction-1", "   ", 2_600),
            ("auction-1", "buyer-1", 0),
            ("auction-1", "buyer-1", -100),
        ] {
            let error = client
                .place_bid(&PlaceBidRequest {
                    auction_id: auction_id.into(),
                    bidder_id: bidder_id.into(),
                    display_name: None,
                    amount_cents,
                })
                .await
                .unwrap_err();
            assert!(
                matches!(error, ApiError::Http { status: 400, .. }),
                "expected a local 400 for ({auction_id:?}, {bidder_id:?}, {amount_cents})"
            );
        }
    }

    #[tokio::test]
    async fn reconnects_after_a_finite_sse_response_while_rest_polling_remains_available() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/sync/rest-query-batch"))
            .respond_with(ResponseTemplate::new(200).set_body_json(empty_batch()))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/sync/sse"))
            .and(query_param("eventId", "drop"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("content-type", "text/event-stream")
                    .set_body_string("event: heartbeat\ndata: {\"tsMs\":1}\n\n"),
            )
            .mount(&server)
            .await;

        let sync = ApiClient::new(server.uri())
            .unwrap()
            .live_event_sync_with_config(
                "drop",
                LiveEventSyncConfig {
                    poll_interval: Duration::from_millis(25),
                    heartbeat_timeout: Duration::from_millis(100),
                    initial_backoff: Duration::from_millis(5),
                    max_backoff: Duration::from_millis(5),
                },
            )
            .unwrap();
        let observed = tokio::time::timeout(Duration::from_secs(1), async {
            let mut live_count = 0;
            while let Some(update) = sync.next_event().await {
                if matches!(
                    update,
                    LiveEventUpdate::Status {
                        status: LiveSyncStatus::Live
                    }
                ) {
                    live_count += 1;
                    if live_count == 2 {
                        return true;
                    }
                }
            }
            false
        })
        .await
        .unwrap();
        sync.close();
        assert!(observed);
    }
}
