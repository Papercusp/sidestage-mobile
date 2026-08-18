// SPDX-License-Identifier: MIT

//! Typed UniFFI boundary for the shared SideStage buyer core.

// UniFFI 0.28 generates a blank line after a doc comment in its scaffolding.
// Keep clippy strict for our code while allowing that generated fragment.
#![allow(clippy::empty_line_after_doc_comments)]

use sidestage_core as core;

uniffi::include_scaffolding!("sidestage");

pub fn version() -> String {
    core::version()
}

/// The bid ladder lives in the shared core so the Android shell, the iPhone
/// shell, and the web buyer panel cannot drift apart on what to pre-fill.
pub fn suggested_bid_cents(current_price_cents: i64) -> i64 {
    core::suggested_bid_cents(current_price_cents)
}

/// The exclusive lower bound the API enforces on a bid.
pub fn minimum_next_bid_cents(current_price_cents: i64) -> i64 {
    core::minimum_next_bid_cents(current_price_cents)
}

/// The inclusive per-product cart ceiling the API enforces.
///
/// Exported for the same reason as the bid ladder above: a native cart stepper
/// has to bound itself, and a shell that hardcodes the number is a copy that
/// drifts the moment the core's limit moves. Clients read the cap from here so
/// the web input's `max="99"` and a SwiftUI/Compose stepper cannot disagree.
pub fn max_cart_quantity() -> u32 {
    core::MAX_CART_QUANTITY
}

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("invalid SideStage API base URL: {detail}")]
    InvalidBaseUrl { detail: String },
    #[error("the current buyer session is missing or invalid")]
    InvalidSession,
    #[error("event {event_id} was not found in the buyer-visible feed")]
    EventNotFound { event_id: String },
    #[error("SideStage API transport failed: {detail}")]
    Transport { detail: String },
    #[error("SideStage API returned HTTP {status}: {detail}")]
    Http { status: u16, detail: String },
    #[error("SideStage API returned an invalid response: {detail}")]
    Decode { detail: String },
}

impl From<core::ApiError> for ApiError {
    fn from(error: core::ApiError) -> Self {
        match error {
            core::ApiError::InvalidBaseUrl(detail) => Self::InvalidBaseUrl { detail },
            core::ApiError::InvalidSession => Self::InvalidSession,
            core::ApiError::EventNotFound(event_id) => Self::EventNotFound { event_id },
            core::ApiError::Transport(error) => Self::Transport {
                detail: error.to_string(),
            },
            core::ApiError::Http { status, message } => Self::Http {
                status,
                detail: message,
            },
            core::ApiError::Decode(error) => Self::Decode {
                detail: error.to_string(),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiSession {
    pub buyer_id: String,
    pub access_token: Option<String>,
}

impl From<ApiSession> for core::ApiSession {
    fn from(session: ApiSession) -> Self {
        Self {
            buyer_id: session.buyer_id,
            access_token: session.access_token,
        }
    }
}

impl From<core::ApiSession> for ApiSession {
    fn from(session: core::ApiSession) -> Self {
        Self {
            buyer_id: session.buyer_id,
            access_token: session.access_token,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventStatus {
    Live,
    Scheduled,
    Ended,
}

impl From<core::EventStatus> for EventStatus {
    fn from(status: core::EventStatus) -> Self {
        match status {
            core::EventStatus::Live => Self::Live,
            core::EventStatus::Scheduled => Self::Scheduled,
            core::EventStatus::Ended => Self::Ended,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventSummary {
    pub event_id: String,
    pub title: String,
    pub seller_id: String,
    pub seller_name: String,
    pub status: EventStatus,
    pub starts_at: Option<String>,
    pub ended_at: Option<String>,
    pub thumbnail_url: Option<String>,
    pub playback_url: Option<String>,
    pub viewers: u64,
}

impl From<core::EventSummary> for EventSummary {
    fn from(event: core::EventSummary) -> Self {
        Self {
            event_id: event.event_id,
            title: event.title,
            seller_id: event.seller_id,
            seller_name: event.seller_name,
            status: event.status.into(),
            starts_at: event.starts_at,
            ended_at: event.ended_at,
            thumbnail_url: event.thumbnail_url,
            playback_url: event.playback_url,
            viewers: event.viewers,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CatalogAvailability {
    All,
    InStock,
}

impl From<CatalogAvailability> for core::CatalogAvailability {
    fn from(availability: CatalogAvailability) -> Self {
        match availability {
            CatalogAvailability::All => Self::All,
            CatalogAvailability::InStock => Self::InStock,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogSearch {
    pub q: Option<String>,
    pub product_type: Option<String>,
    pub availability: Option<CatalogAvailability>,
    pub page: Option<u32>,
    pub page_size: Option<u32>,
}

impl From<CatalogSearch> for core::CatalogSearch {
    fn from(search: CatalogSearch) -> Self {
        Self {
            q: search.q,
            product_type: search.product_type,
            availability: search.availability.map(Into::into),
            page: search.page,
            page_size: search.page_size,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
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
    pub image_url: Option<String>,
    pub description: Option<String>,
}

impl From<core::CatalogVariant> for CatalogVariant {
    fn from(product: core::CatalogVariant) -> Self {
        Self {
            id: product.id,
            group_id: product.group_id,
            title: product.title,
            brand: product.brand,
            product_type: product.product_type,
            sku: product.sku,
            condition: product.condition,
            handling_days: product.handling_days,
            price_cents: product.price_cents,
            available_qty: product.available_qty,
            image_url: product.image_url,
            description: product.description,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogPage {
    pub rows: Vec<CatalogVariant>,
    pub page: u32,
    pub page_size: u32,
    pub total: u64,
    pub total_is_floor: bool,
}

impl From<core::CatalogPage> for CatalogPage {
    fn from(page: core::CatalogPage) -> Self {
        Self {
            rows: page.rows.into_iter().map(Into::into).collect(),
            page: page.page,
            page_size: page.page_size,
            total: page.total,
            total_is_floor: page.total_is_floor,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Currency {
    Usd,
}

impl From<core::Currency> for Currency {
    fn from(currency: core::Currency) -> Self {
        match currency {
            core::Currency::Usd => Self::Usd,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CartItem {
    pub product_id: String,
    pub title: String,
    pub price_cents: i64,
    pub quantity: u32,
    pub image_url: Option<String>,
}

impl From<core::CartItem> for CartItem {
    fn from(item: core::CartItem) -> Self {
        Self {
            product_id: item.product_id,
            title: item.title,
            price_cents: item.price_cents,
            quantity: item.quantity,
            image_url: item.image_url,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cart {
    pub id: String,
    pub currency: Currency,
    pub items: Vec<CartItem>,
    pub subtotal_cents: i64,
    pub updated_at: String,
}

impl From<core::Cart> for Cart {
    fn from(cart: core::Cart) -> Self {
        Self {
            id: cart.id,
            currency: cart.currency.into(),
            items: cart.items.into_iter().map(Into::into).collect(),
            subtotal_cents: cart.subtotal_cents,
            updated_at: cart.updated_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AddCartItemRequest {
    pub cart_id: Option<String>,
    pub product_id: String,
    pub title: String,
    pub price_cents: i64,
    pub quantity: u32,
    pub image_url: Option<String>,
}

impl From<AddCartItemRequest> for core::AddCartItemRequest {
    fn from(item: AddCartItemRequest) -> Self {
        Self {
            cart_id: item.cart_id,
            product_id: item.product_id,
            title: item.title,
            price_cents: item.price_cents,
            quantity: item.quantity,
            image_url: item.image_url,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShippingAddress {
    pub name: String,
    pub line1: String,
    pub line2: Option<String>,
    pub city: String,
    pub state: String,
    pub postal_code: String,
    pub country: String,
    pub phone: Option<String>,
}

impl From<ShippingAddress> for core::ShippingAddress {
    fn from(address: ShippingAddress) -> Self {
        Self {
            name: address.name,
            line1: address.line1,
            line2: address.line2,
            city: address.city,
            state: address.state,
            postal_code: address.postal_code,
            country: address.country,
            phone: address.phone,
        }
    }
}

impl From<core::ShippingAddress> for ShippingAddress {
    fn from(address: core::ShippingAddress) -> Self {
        Self {
            name: address.name,
            line1: address.line1,
            line2: address.line2,
            city: address.city,
            state: address.state,
            postal_code: address.postal_code,
            country: address.country,
            phone: address.phone,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShippingRatesRequest {
    pub cart_id: String,
    pub address: ShippingAddress,
}

impl From<ShippingRatesRequest> for core::ShippingRatesRequest {
    fn from(request: ShippingRatesRequest) -> Self {
        Self {
            cart_id: request.cart_id,
            address: request.address.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShippingRate {
    pub id: String,
    pub carrier: String,
    pub service: String,
    pub total_cents: i64,
    pub delivery_days: Option<u32>,
    pub parcel_count: u32,
    pub quoted_at: String,
}

impl From<core::ShippingRate> for ShippingRate {
    fn from(rate: core::ShippingRate) -> Self {
        Self {
            id: rate.id,
            carrier: rate.carrier,
            service: rate.service,
            total_cents: rate.total_cents,
            delivery_days: rate.delivery_days,
            parcel_count: rate.parcel_count,
            quoted_at: rate.quoted_at,
        }
    }
}

impl From<core::ShippingRateSnapshot> for ShippingRate {
    fn from(rate: core::ShippingRateSnapshot) -> Self {
        Self {
            id: rate.id,
            carrier: rate.carrier,
            service: rate.service,
            total_cents: rate.total_cents,
            delivery_days: rate.delivery_days,
            parcel_count: rate.parcel_count,
            quoted_at: rate.quoted_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaymentSession {
    pub provider: String,
    pub mode: String,
    pub status: String,
    pub app_id: Option<String>,
    pub location_id: Option<String>,
    pub order_id: String,
    pub amount_cents: i64,
    pub currency: Currency,
}

impl From<core::PaymentSession> for PaymentSession {
    fn from(session: core::PaymentSession) -> Self {
        let provider = match session.provider {
            core::PaymentProvider::Square => "square",
        };
        let mode = match session.mode {
            core::PaymentMode::Sandbox => "sandbox",
        };
        let status = match session.status {
            core::PaymentSessionStatus::Ready => "ready",
            core::PaymentSessionStatus::NeedsConfiguration => "needs-configuration",
        };
        Self {
            provider: provider.into(),
            mode: mode.into(),
            status: status.into(),
            app_id: session.app_id,
            location_id: session.location_id,
            order_id: session.order_id,
            amount_cents: session.amount_cents,
            currency: session.currency.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckoutOrder {
    pub id: String,
    pub cart_id: String,
    pub buyer_id: String,
    pub event_id: String,
    pub email: Option<String>,
    pub subtotal_cents: i64,
    pub shipping_cents: i64,
    pub total_cents: i64,
    pub currency: Currency,
    pub status: String,
    pub created_at: String,
    pub items: Vec<CartItem>,
    pub payment_session: PaymentSession,
    pub shipping_address: Option<ShippingAddress>,
    pub selected_shipping_rate: Option<ShippingRate>,
}

impl From<core::CheckoutOrder> for CheckoutOrder {
    fn from(order: core::CheckoutOrder) -> Self {
        let status = match order.status {
            core::CheckoutOrderStatus::Pending => "pending",
            core::CheckoutOrderStatus::Paid => "paid",
            core::CheckoutOrderStatus::Failed => "failed",
        };
        Self {
            id: order.id,
            cart_id: order.cart_id,
            buyer_id: order.buyer_id,
            event_id: order.event_id,
            email: order.email,
            subtotal_cents: order.subtotal_cents,
            shipping_cents: order.shipping_cents,
            total_cents: order.total_cents,
            currency: order.currency.into(),
            status: status.into(),
            created_at: order.created_at,
            items: order.items.into_iter().map(Into::into).collect(),
            payment_session: order.payment_session.into(),
            shipping_address: order.shipping_address.map(Into::into),
            selected_shipping_rate: order.selected_shipping_rate.map(Into::into),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderSource {
    Checkout,
    Auction,
    Offer,
}

impl From<core::OrderSource> for OrderSource {
    fn from(source: core::OrderSource) -> Self {
        match source {
            core::OrderSource::Checkout => Self::Checkout,
            core::OrderSource::Auction => Self::Auction,
            core::OrderSource::Offer => Self::Offer,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderStatus {
    Pending,
    Paid,
    Failed,
    Accepted,
    Expired,
    Cancelled,
}

impl From<core::OrderStatus> for OrderStatus {
    fn from(status: core::OrderStatus) -> Self {
        match status {
            core::OrderStatus::Pending => Self::Pending,
            core::OrderStatus::Paid => Self::Paid,
            core::OrderStatus::Failed => Self::Failed,
            core::OrderStatus::Accepted => Self::Accepted,
            core::OrderStatus::Expired => Self::Expired,
            core::OrderStatus::Cancelled => Self::Cancelled,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrderLine {
    pub product_id: String,
    pub title: String,
    pub quantity: u32,
    pub unit_price_cents: i64,
    pub image_url: Option<String>,
}

impl From<core::OrderLine> for OrderLine {
    fn from(line: core::OrderLine) -> Self {
        Self {
            product_id: line.product_id,
            title: line.title,
            quantity: line.quantity,
            unit_price_cents: line.unit_price_cents,
            image_url: line.image_url,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderEvidenceKind {
    Condition,
}

impl From<core::OrderEvidenceKind> for OrderEvidenceKind {
    fn from(kind: core::OrderEvidenceKind) -> Self {
        match kind {
            core::OrderEvidenceKind::Condition => Self::Condition,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrderVideoSnapshot {
    pub id: String,
    pub event_id: String,
    pub event_title: String,
    pub seller_name: Option<String>,
    pub product_id: String,
    pub product_title: String,
    pub thumbnail_url: Option<String>,
    pub start_ms: Option<u64>,
    pub end_ms: Option<u64>,
    pub preview_text: Option<String>,
    pub evidence_kind: Option<OrderEvidenceKind>,
    pub evidence_label: Option<String>,
}

impl From<core::OrderVideoSnapshot> for OrderVideoSnapshot {
    fn from(snapshot: core::OrderVideoSnapshot) -> Self {
        Self {
            id: snapshot.id,
            event_id: snapshot.event_id,
            event_title: snapshot.event_title,
            seller_name: snapshot.seller_name,
            product_id: snapshot.product_id,
            product_title: snapshot.product_title,
            thumbnail_url: snapshot.thumbnail_url,
            start_ms: snapshot.start_ms,
            end_ms: snapshot.end_ms,
            preview_text: snapshot.preview_text,
            evidence_kind: snapshot.evidence_kind.map(Into::into),
            evidence_label: snapshot.evidence_label,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Order {
    pub id: String,
    pub source: OrderSource,
    pub buyer_id: String,
    pub event_id: String,
    pub event_title: String,
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

impl From<core::Order> for Order {
    fn from(order: core::Order) -> Self {
        Self {
            id: order.id,
            source: order.source.into(),
            buyer_id: order.buyer_id,
            event_id: order.event_id,
            event_title: order.event_title,
            seller_name: order.seller_name,
            status: order.status.into(),
            created_at: order.created_at,
            subtotal_cents: order.subtotal_cents,
            shipping_cents: order.shipping_cents,
            total_cents: order.total_cents,
            currency: order.currency.into(),
            items: order.items.into_iter().map(Into::into).collect(),
            video_snapshots: order.video_snapshots.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateCheckoutSessionRequest {
    pub cart_id: String,
    pub event_id: String,
    pub email: Option<String>,
    pub name: Option<String>,
    pub shipping_address: ShippingAddress,
    pub shipping_rate_id: String,
}

impl From<CreateCheckoutSessionRequest> for core::CreateCheckoutSessionRequest {
    fn from(request: CreateCheckoutSessionRequest) -> Self {
        Self {
            cart_id: request.cart_id,
            event_id: request.event_id,
            email: request.email,
            name: request.name,
            shipping_address: request.shipping_address.into(),
            shipping_rate_id: request.shipping_rate_id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckoutSessionResponse {
    pub order: CheckoutOrder,
    pub session: PaymentSession,
}

impl From<core::CheckoutSessionResponse> for CheckoutSessionResponse {
    fn from(response: core::CheckoutSessionResponse) -> Self {
        Self {
            order: response.order.into(),
            session: response.session.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfirmCheckoutRequest {
    pub order_id: String,
    pub source_id: String,
}

impl From<ConfirmCheckoutRequest> for core::ConfirmCheckoutRequest {
    fn from(request: ConfirmCheckoutRequest) -> Self {
        Self {
            order_id: request.order_id,
            source_id: request.source_id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaymentResult {
    pub status: String,
    pub transaction_id: Option<String>,
    pub error_message: Option<String>,
}

impl From<core::PaymentResult> for PaymentResult {
    fn from(result: core::PaymentResult) -> Self {
        let status = match result.status {
            core::PaymentResultStatus::Paid => "paid",
            core::PaymentResultStatus::Failed => "failed",
            core::PaymentResultStatus::NeedsConfiguration => "needs-configuration",
        };
        Self {
            status: status.into(),
            transaction_id: result.transaction_id,
            error_message: result.error_message,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckoutConfirmation {
    pub order: CheckoutOrder,
    pub payment: PaymentResult,
}

impl From<core::CheckoutConfirmation> for CheckoutConfirmation {
    fn from(confirmation: core::CheckoutConfirmation) -> Self {
        Self {
            order: confirmation.order.into(),
            payment: confirmation.payment.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatRole {
    Buyer,
    Seller,
}

impl From<core::ChatRole> for ChatRole {
    fn from(role: core::ChatRole) -> Self {
        match role {
            core::ChatRole::Buyer => Self::Buyer,
            core::ChatRole::Seller => Self::Seller,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventTranscriptEntry {
    pub id: String,
    pub event_id: String,
    pub user_id: String,
    pub display_name: String,
    pub role: ChatRole,
    pub text: String,
    pub created_at: String,
    pub grounding_json: Option<String>,
}

impl From<core::EventTranscriptEntry> for EventTranscriptEntry {
    fn from(entry: core::EventTranscriptEntry) -> Self {
        Self {
            id: entry.id,
            event_id: entry.event_id,
            user_id: entry.user_id,
            display_name: entry.display_name,
            role: entry.role.into(),
            text: entry.text,
            created_at: entry.created_at,
            // `grounding` is free-form seller-copilot JSON with no fixed
            // schema, so it crosses the boundary as text rather than forcing a
            // lossy typed shape on the shells.
            grounding_json: entry.grounding.map(|value| value.to_string()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuctionStatus {
    Active,
    Closed,
}

impl From<core::AuctionStatus> for AuctionStatus {
    fn from(status: core::AuctionStatus) -> Self {
        match status {
            core::AuctionStatus::Active => Self::Active,
            core::AuctionStatus::Closed => Self::Closed,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuctionBid {
    pub id: String,
    pub bidder_id: String,
    pub display_name: Option<String>,
    pub amount_cents: i64,
    pub created_at: String,
}

impl From<core::AuctionBid> for AuctionBid {
    fn from(bid: core::AuctionBid) -> Self {
        Self {
            id: bid.id,
            bidder_id: bid.bidder_id,
            display_name: bid.display_name,
            amount_cents: bid.amount_cents,
            created_at: bid.created_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
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
    pub closed_at: Option<String>,
    pub bids: Vec<AuctionBid>,
    pub winner_order_json: Option<String>,
}

impl From<core::LiveAuction> for LiveAuction {
    fn from(auction: core::LiveAuction) -> Self {
        Self {
            id: auction.id,
            event_id: auction.event_id,
            event_item_id: auction.event_item_id,
            product_id: auction.product_id,
            quantity: auction.quantity,
            starting_price_cents: auction.starting_price_cents,
            current_price_cents: auction.current_price_cents,
            status: auction.status.into(),
            started_at: auction.started_at,
            ends_at: auction.ends_at,
            closed_at: auction.closed_at,
            bids: auction.bids.into_iter().map(Into::into).collect(),
            winner_order_json: auction.winner_order.map(|value| value.to_string()),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct LiveEventSnapshot {
    pub event_id: String,
    pub transcript: Vec<EventTranscriptEntry>,
    pub on_deck_product: Option<CatalogVariant>,
    pub auction: Option<LiveAuction>,
}

impl From<core::LiveEventSnapshot> for LiveEventSnapshot {
    fn from(snapshot: core::LiveEventSnapshot) -> Self {
        Self {
            event_id: snapshot.event_id,
            transcript: snapshot.transcript.into_iter().map(Into::into).collect(),
            on_deck_product: snapshot.on_deck_product.map(Into::into),
            auction: snapshot.auction.map(Into::into),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveSyncStatus {
    Connecting,
    Live,
    Polling { retry_in_ms: u64 },
}

impl From<core::LiveSyncStatus> for LiveSyncStatus {
    fn from(status: core::LiveSyncStatus) -> Self {
        match status {
            core::LiveSyncStatus::Connecting => Self::Connecting,
            core::LiveSyncStatus::Live => Self::Live,
            core::LiveSyncStatus::Polling { retry_in_ms } => Self::Polling { retry_in_ms },
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
// UniFFI's UDL-generated scaffolding requires this record payload inline; boxing
// it would make the Rust enum diverge from the native binding contract.
#[allow(clippy::large_enum_variant)]
pub enum LiveEventUpdate {
    Status { status: LiveSyncStatus },
    Snapshot { snapshot: LiveEventSnapshot },
    Error { message: String },
}

impl From<core::LiveEventUpdate> for LiveEventUpdate {
    fn from(update: core::LiveEventUpdate) -> Self {
        match update {
            core::LiveEventUpdate::Status { status } => Self::Status {
                status: status.into(),
            },
            // The core boxes the snapshot to keep its update enum small; the
            // boundary type is owned by the foreign side, so unbox it here.
            core::LiveEventUpdate::Snapshot { snapshot } => Self::Snapshot {
                snapshot: (*snapshot).into(),
            },
            core::LiveEventUpdate::Error { message } => Self::Error { message },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaceBidRequest {
    pub auction_id: String,
    pub bidder_id: String,
    pub display_name: Option<String>,
    pub amount_cents: i64,
}

impl From<PlaceBidRequest> for core::PlaceBidRequest {
    fn from(request: PlaceBidRequest) -> Self {
        Self {
            auction_id: request.auction_id,
            bidder_id: request.bidder_id,
            display_name: request.display_name,
            amount_cents: request.amount_cents,
        }
    }
}

/// A running live-event subscription handed to the native shell.
///
/// It holds the runtime that drives the background sync task alive for exactly
/// as long as the shell holds the subscription, so a shell that drops its
/// reference also stops the polling and streaming work.
pub struct LiveEventSync {
    inner: core::LiveEventSync,
    _runtime: std::sync::Arc<tokio::runtime::Runtime>,
}

impl LiveEventSync {
    pub async fn next_event(&self) -> Option<LiveEventUpdate> {
        self.inner.next_event().await.map(Into::into)
    }

    pub fn stop(&self) {
        self.inner.close();
    }
}

pub struct SideStageClient {
    inner: std::sync::RwLock<core::ApiClient>,
    /// The async work this boundary starts has to run somewhere.
    ///
    /// UniFFI's async methods are polled by the FOREIGN executor, which is not
    /// a Tokio runtime, so `tokio::spawn` inside the core would panic and
    /// Reqwest would have no reactor. Owning a runtime here keeps that
    /// entirely inside the boundary rather than making every caller supply it.
    runtime: std::sync::Arc<tokio::runtime::Runtime>,
}

impl SideStageClient {
    pub fn new(base_url: String) -> Result<Self, ApiError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("sidestage-core")
            .build()
            .map_err(|error| ApiError::Transport {
                detail: format!("could not start the SideStage runtime: {error}"),
            })?;
        Ok(Self {
            inner: std::sync::RwLock::new(core::ApiClient::new(base_url)?),
            runtime: std::sync::Arc::new(runtime),
        })
    }

    pub fn set_session(&self, session: Option<ApiSession>) -> Result<(), ApiError> {
        self.inner
            .write()
            .expect("SideStage client session lock poisoned")
            .set_session(session.map(Into::into))
            .map_err(Into::into)
    }

    pub fn session(&self) -> Option<ApiSession> {
        self.inner
            .read()
            .expect("SideStage client session lock poisoned")
            .session()
            .cloned()
            .map(Into::into)
    }

    pub async fn events(&self) -> Result<Vec<EventSummary>, ApiError> {
        let client = self.client();
        let events = self
            .on_runtime("events", async move { client.events().await })
            .await??;
        Ok(events.into_iter().map(Into::into).collect())
    }

    pub async fn event(&self, event_id: String) -> Result<EventSummary, ApiError> {
        let client = self.client();
        Ok(self
            .on_runtime("event", async move { client.event(&event_id).await })
            .await??
            .into())
    }

    pub async fn catalog(&self, search: CatalogSearch) -> Result<CatalogPage, ApiError> {
        let client = self.client();
        let search: core::CatalogSearch = search.into();
        Ok(self
            .on_runtime("catalog", async move { client.catalog(&search).await })
            .await??
            .into())
    }

    pub async fn product_types(&self) -> Result<Vec<String>, ApiError> {
        let client = self.client();
        self.on_runtime("product types", async move { client.product_types().await })
            .await?
            .map_err(Into::into)
    }

    pub async fn product(&self, product_id: String) -> Result<CatalogVariant, ApiError> {
        let client = self.client();
        Ok(self
            .on_runtime("product", async move { client.product(&product_id).await })
            .await??
            .into())
    }

    pub async fn cart(&self, cart_id: String) -> Result<Option<Cart>, ApiError> {
        let client = self.client();
        Ok(self
            .on_runtime("cart", async move { client.cart(&cart_id).await })
            .await??
            .map(Into::into))
    }

    pub async fn add_cart_item(&self, input: AddCartItemRequest) -> Result<Cart, ApiError> {
        let client = self.client();
        let request: core::AddCartItemRequest = input.into();
        Ok(self
            .on_runtime("add cart item", async move {
                client.add_cart_item(&request).await
            })
            .await??
            .into())
    }

    pub async fn set_cart_quantity(
        &self,
        cart_id: String,
        product_id: String,
        quantity: u32,
    ) -> Result<Cart, ApiError> {
        let client = self.client();
        Ok(self
            .on_runtime("set cart quantity", async move {
                client
                    .set_cart_quantity(&cart_id, &product_id, quantity)
                    .await
            })
            .await??
            .into())
    }

    pub async fn remove_cart_item(
        &self,
        cart_id: String,
        product_id: String,
    ) -> Result<Cart, ApiError> {
        let client = self.client();
        Ok(self
            .on_runtime("remove cart item", async move {
                client.remove_cart_item(&cart_id, &product_id).await
            })
            .await??
            .into())
    }

    pub async fn shipping_rates(
        &self,
        input: ShippingRatesRequest,
    ) -> Result<Vec<ShippingRate>, ApiError> {
        let client = self.client();
        let request: core::ShippingRatesRequest = input.into();
        let rates = self
            .on_runtime("shipping rates", async move {
                client.shipping_rates(&request).await
            })
            .await??;
        Ok(rates.into_iter().map(Into::into).collect())
    }

    pub async fn create_checkout_session(
        &self,
        input: CreateCheckoutSessionRequest,
    ) -> Result<CheckoutSessionResponse, ApiError> {
        let client = self.client();
        let request: core::CreateCheckoutSessionRequest = input.into();
        Ok(self
            .on_runtime("create checkout session", async move {
                client.create_checkout_session(&request).await
            })
            .await??
            .into())
    }

    pub async fn confirm_checkout(
        &self,
        input: ConfirmCheckoutRequest,
    ) -> Result<CheckoutConfirmation, ApiError> {
        let client = self.client();
        let request: core::ConfirmCheckoutRequest = input.into();
        Ok(self
            .on_runtime("confirm checkout", async move {
                client.confirm_checkout(&request).await
            })
            .await??
            .into())
    }

    pub async fn orders(&self) -> Result<Vec<CheckoutOrder>, ApiError> {
        let client = self.client();
        let orders = self
            .on_runtime("orders", async move { client.orders().await })
            .await??;
        Ok(orders.into_iter().map(Into::into).collect())
    }

    /// Fetch the API's bounded unified order snapshot for the current Buyer.
    ///
    /// The core owns the page-size ceiling. Asking for the largest possible
    /// page lets it clamp to that ceiling so this collection-style foreign API
    /// returns the whole server snapshot without duplicating the limit here.
    pub async fn order_history(&self) -> Result<Vec<Order>, ApiError> {
        let client = self.client();
        let page = self
            .on_runtime("order history", async move {
                client
                    .order_history(&core::OrderPageRequest {
                        cursor: None,
                        page_size: Some(u32::MAX),
                    })
                    .await
            })
            .await??;
        Ok(page.orders.into_iter().map(Into::into).collect())
    }

    /// Start streaming a live event.
    ///
    /// The core spawns its stream/poll task on the ambient runtime, so this
    /// enters ours first — otherwise the spawn panics under the foreign
    /// executor. The returned handle keeps that runtime alive.
    pub fn live_event_sync(
        &self,
        event_id: String,
    ) -> Result<std::sync::Arc<LiveEventSync>, ApiError> {
        let guard = self.runtime.enter();
        let inner = self.client().live_event_sync(event_id);
        drop(guard);
        Ok(std::sync::Arc::new(LiveEventSync {
            inner: inner?,
            _runtime: self.runtime.clone(),
        }))
    }

    /// Place a bid, returning the auction as the API re-published it.
    ///
    /// The request is driven on our own runtime and awaited through the join
    /// handle, so it holds regardless of which executor the foreign side polls
    /// this future on.
    pub async fn place_bid(&self, input: PlaceBidRequest) -> Result<LiveAuction, ApiError> {
        let client = self.client();
        let request: core::PlaceBidRequest = input.into();
        self.on_runtime("bid", async move { client.place_bid(&request).await })
            .await?
            .map(Into::into)
            .map_err(Into::into)
    }

    /// Drive one core request on OUR runtime, whatever executor the foreign
    /// side polls the returned future on.
    ///
    /// Every `async` method on this boundary owes this hop. UniFFI hands the
    /// future to the FOREIGN executor (Swift's, here), which is not a Tokio
    /// runtime — so Reqwest finds no reactor and any `tokio::spawn` inside the
    /// core panics. `live_event_sync` and `place_bid` were written with the hop
    /// because their failure was immediate and obvious; the other thirteen were
    /// not, which is exactly what made the gap easy to miss.
    ///
    /// The outer `Result` is the JOIN result (the runtime dropping the task);
    /// the inner one is the request's own. Callers `??` through both, so a lost
    /// task can never be mistaken for an API error.
    async fn on_runtime<F, T>(&self, what: &'static str, future: F) -> Result<T, ApiError>
    where
        F: std::future::Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        self.runtime
            .spawn(future)
            .await
            .map_err(|error| ApiError::Transport {
                detail: format!("the SideStage runtime dropped the {what} request: {error}"),
            })
    }

    fn client(&self) -> core::ApiClient {
        self.inner
            .read()
            .expect("SideStage client session lock poisoned")
            .clone()
    }
}

/// Exercise constructor/session validation through the same Rust surface that
/// UniFFI scaffolding calls. The binary target makes this a cheap host probe.
pub fn host_smoke() -> Result<String, ApiError> {
    let client = SideStageClient::new("https://api.example.test/v1".into())?;
    client.set_session(Some(ApiSession {
        buyer_id: "host-smoke-buyer".into(),
        access_token: Some("host-smoke-token".into()),
    }))?;
    let session = client.session().ok_or(ApiError::InvalidSession)?;
    if session.buyer_id != "host-smoke-buyer" {
        return Err(ApiError::InvalidSession);
    }
    if !matches!(
        SideStageClient::new("not a URL".into()),
        Err(ApiError::InvalidBaseUrl { .. })
    ) {
        return Err(ApiError::InvalidBaseUrl {
            detail: "invalid URL unexpectedly crossed the boundary".into(),
        });
    }
    Ok(format!(
        "sidestage-bindings {} ({})",
        version(),
        session.buyer_id
    ))
}

#[derive(Debug, thiserror::Error)]
pub enum WhepError {
    #[error("the stream publisher has not started yet")]
    PublisherNotReady,
    #[error("invalid WHEP endpoint URL: {detail}")]
    InvalidEndpoint { detail: String },
    #[error("WHEP transport failed: {detail}")]
    Transport { detail: String },
    #[error("media server returned HTTP {status}: {detail}")]
    Http { status: u16, detail: String },
    #[error("media server returned an empty SDP answer")]
    EmptyAnswer,
}

impl From<core::WhepError> for WhepError {
    fn from(error: core::WhepError) -> Self {
        match error {
            core::WhepError::PublisherNotReady => Self::PublisherNotReady,
            core::WhepError::InvalidEndpoint(detail) => Self::InvalidEndpoint { detail },
            core::WhepError::Transport(error) => Self::Transport {
                detail: error.to_string(),
            },
            core::WhepError::Http { status, detail } => Self::Http { status, detail },
            core::WhepError::EmptyAnswer => Self::EmptyAnswer,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhepIceServer {
    pub urls: String,
    pub username: Option<String>,
    pub credential: Option<String>,
}

impl From<core::WhepIceServer> for WhepIceServer {
    fn from(server: core::WhepIceServer) -> Self {
        Self {
            urls: server.urls,
            username: server.username,
            credential: server.credential,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhepAnswer {
    pub sdp: String,
    pub resource_url: Option<String>,
}

impl From<core::WhepAnswer> for WhepAnswer {
    fn from(answer: core::WhepAnswer) -> Self {
        Self {
            sdp: answer.sdp,
            resource_url: answer.resource_url,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerConnectionState {
    New,
    Connecting,
    Connected,
    Disconnected,
    Failed,
    Closed,
}

impl From<PeerConnectionState> for core::PeerConnectionState {
    fn from(state: PeerConnectionState) -> Self {
        match state {
            PeerConnectionState::New => Self::New,
            PeerConnectionState::Connecting => Self::Connecting,
            PeerConnectionState::Connected => Self::Connected,
            PeerConnectionState::Disconnected => Self::Disconnected,
            PeerConnectionState::Failed => Self::Failed,
            PeerConnectionState::Closed => Self::Closed,
        }
    }
}

/// WHEP publisher-not-ready backoff (WI-39733); see the core for the schedule.
pub fn publisher_retry_delay_ms(attempt: u32) -> Option<u64> {
    core::publisher_retry_delay_ms(attempt)
}

/// Only `Failed` means the media is gone for good (WI-39747).
pub fn is_lost_connection_state(state: PeerConnectionState) -> bool {
    core::is_lost_connection_state(state.into())
}

/// Loss-recovery budget for an established stream (WI-39747).
pub fn max_loss_reconnects() -> u32 {
    core::MAX_LOSS_RECONNECTS
}

/// Whether a local SDP carries at least one `a=candidate:` line.
pub fn sdp_has_ice_candidate(sdp: String) -> bool {
    core::sdp_has_ice_candidate(&sdp)
}

/// Identical copy to the web buyer's waiting state.
pub fn waiting_for_publisher_message() -> String {
    core::WAITING_FOR_PUBLISHER_MESSAGE.to_string()
}

/// Identical copy to the web buyer's spent-schedule state.
pub fn publisher_absent_message() -> String {
    core::PUBLISHER_ABSENT_MESSAGE.to_string()
}

/// HTTP signaling against one WHEP endpoint. Owns its own runtime for the
/// same reason `SideStageClient` does: UniFFI async methods are polled by the
/// foreign executor, which is not a Tokio runtime.
pub struct WhepSignaling {
    inner: core::WhepSignaling,
    runtime: std::sync::Arc<tokio::runtime::Runtime>,
}

impl WhepSignaling {
    pub fn new() -> Result<Self, WhepError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("sidestage-whep")
            .build()
            .map_err(|error| WhepError::Transport {
                detail: format!("could not start the WHEP runtime: {error}"),
            })?;
        Ok(Self {
            inner: core::WhepSignaling::new(),
            runtime: std::sync::Arc::new(runtime),
        })
    }

    pub async fn discover_ice_servers(
        &self,
        endpoint: String,
    ) -> Result<Vec<WhepIceServer>, WhepError> {
        let signaling = self.inner.clone();
        self.on_runtime("ICE discovery", async move {
            signaling.discover_ice_servers(&endpoint).await
        })
        .await?
        .map(|servers| servers.into_iter().map(Into::into).collect())
        .map_err(Into::into)
    }

    pub async fn post_offer(
        &self,
        endpoint: String,
        offer_sdp: String,
    ) -> Result<WhepAnswer, WhepError> {
        let signaling = self.inner.clone();
        self.on_runtime("WHEP offer", async move {
            signaling.post_offer(&endpoint, &offer_sdp).await
        })
        .await?
        .map(Into::into)
        .map_err(Into::into)
    }

    pub async fn delete_resource(&self, resource_url: String) -> Result<(), WhepError> {
        let signaling = self.inner.clone();
        self.on_runtime("WHEP session cleanup", async move {
            signaling.delete_resource(&resource_url).await
        })
        .await?
        .map_err(Into::into)
    }

    /// Same two-layer result as `SideStageClient::on_runtime`: the outer error
    /// is the runtime dropping the task, the inner one the request's own.
    async fn on_runtime<F, T>(&self, what: &'static str, future: F) -> Result<T, WhepError>
    where
        F: std::future::Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        self.runtime
            .spawn(future)
            .await
            .map_err(|error| WhepError::Transport {
                detail: format!("the WHEP runtime dropped the {what} request: {error}"),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_boundary_smoke_passes() {
        let report = host_smoke().expect("host boundary smoke");
        assert!(report.contains("host-smoke-buyer"));
    }

    /// A deliberately minimal, NON-Tokio executor.
    ///
    /// This is the point of the whole test below: `#[tokio::test]` would supply
    /// the very ambient runtime whose absence is the bug, so it can never catch
    /// this class. Swift's executor is not Tokio either — this stands in for it
    /// with nothing but `std`.
    fn block_on_foreign_executor<F: std::future::Future>(future: F) -> F::Output {
        use std::sync::{Arc, Condvar, Mutex};
        use std::task::{Context, Poll, Wake, Waker};

        struct Signal {
            woken: Mutex<bool>,
            ready: Condvar,
        }
        impl Wake for Signal {
            fn wake(self: Arc<Self>) {
                self.wake_by_ref();
            }
            fn wake_by_ref(self: &Arc<Self>) {
                *self.woken.lock().expect("waker lock") = true;
                self.ready.notify_one();
            }
        }

        let signal = Arc::new(Signal {
            woken: Mutex::new(false),
            ready: Condvar::new(),
        });
        let waker = Waker::from(signal.clone());
        let mut cx = Context::from_waker(&waker);
        let mut future = std::pin::pin!(future);
        loop {
            match future.as_mut().poll(&mut cx) {
                Poll::Ready(value) => return value,
                Poll::Pending => {
                    let mut woken = signal.woken.lock().expect("waker lock");
                    while !*woken {
                        woken = signal.ready.wait(woken).expect("waker wait");
                    }
                    *woken = false;
                }
            }
        }
    }

    /// EI-20438504039508900: every `async` method on the boundary owes the
    /// `on_runtime` hop, and only `place_bid` / `live_event_sync` had it — so
    /// the entire cart → shipping → checkout → orders path would have died
    /// under the foreign executor the first time a buyer used it.
    ///
    /// The assertion is simply that each call RETURNS. Without the hop these
    /// panic ("no reactor running" / a `tokio::spawn` outside a runtime) rather
    /// than failing as an `ApiError`, and a panic fails this test. Port 1 is
    /// closed, so every call is expected to come back as a transport error —
    /// reaching the transport at all is the property under test, not success.
    #[test]
    fn every_async_boundary_method_runs_without_an_ambient_runtime() {
        let client = SideStageClient::new("http://127.0.0.1:1".into()).expect("client");

        // REQUIRED, and the reason this guard was vacuous when first written:
        // the buyer-scoped methods build their URL through `buyer_id()`, which
        // fails on a session-less client BEFORE any request is made. Without a
        // session every call below returns `Err` without touching the
        // transport, so `is_err()` holds whether or not the runtime hop exists
        // — the mutation probe caught exactly that. A session is what pushes
        // these calls far enough to need a reactor.
        client
            .set_session(Some(ApiSession {
                buyer_id: "guard-buyer".into(),
                access_token: Some("guard-token".into()),
            }))
            .expect("session");

        let address = ShippingAddress {
            name: "Ada".into(),
            line1: "1 Main St".into(),
            line2: None,
            city: "Brooklyn".into(),
            state: "NY".into(),
            postal_code: "11201".into(),
            country: "US".into(),
            phone: None,
        };

        assert!(
            block_on_foreign_executor(client.events()).is_err(),
            "events"
        );
        assert!(
            block_on_foreign_executor(client.event("drop".into())).is_err(),
            "event"
        );
        assert!(
            block_on_foreign_executor(client.catalog(CatalogSearch {
                q: None,
                product_type: None,
                availability: None,
                page: None,
                page_size: None,
            }))
            .is_err(),
            "catalog"
        );
        assert!(
            block_on_foreign_executor(client.product_types()).is_err(),
            "product_types"
        );
        assert!(
            block_on_foreign_executor(client.product("mug/red".into())).is_err(),
            "product"
        );
        assert!(
            block_on_foreign_executor(client.cart("cart-1".into())).is_err(),
            "cart"
        );
        assert!(
            block_on_foreign_executor(client.add_cart_item(AddCartItemRequest {
                cart_id: None,
                product_id: "mug/red".into(),
                title: "Red mug".into(),
                price_cents: 2_600,
                quantity: 1,
                image_url: None,
            }))
            .is_err(),
            "add_cart_item"
        );
        assert!(
            block_on_foreign_executor(client.set_cart_quantity(
                "cart-1".into(),
                "mug/red".into(),
                2
            ))
            .is_err(),
            "set_cart_quantity"
        );
        assert!(
            block_on_foreign_executor(client.remove_cart_item("cart-1".into(), "mug/red".into()))
                .is_err(),
            "remove_cart_item"
        );
        assert!(
            block_on_foreign_executor(client.shipping_rates(ShippingRatesRequest {
                cart_id: "cart-1".into(),
                address: address.clone(),
            }))
            .is_err(),
            "shipping_rates"
        );
        assert!(
            block_on_foreign_executor(client.create_checkout_session(
                CreateCheckoutSessionRequest {
                    cart_id: "cart-1".into(),
                    event_id: "drop".into(),
                    email: None,
                    name: None,
                    shipping_address: address,
                    shipping_rate_id: "rate-1".into(),
                }
            ))
            .is_err(),
            "create_checkout_session"
        );
        assert!(
            block_on_foreign_executor(client.confirm_checkout(ConfirmCheckoutRequest {
                order_id: "order-1".into(),
                source_id: "cnon:card-nonce-ok".into(),
            }))
            .is_err(),
            "confirm_checkout"
        );
        assert!(
            block_on_foreign_executor(client.orders()).is_err(),
            "orders"
        );
        assert!(
            block_on_foreign_executor(client.order_history()).is_err(),
            "order_history"
        );
        assert!(
            block_on_foreign_executor(client.place_bid(PlaceBidRequest {
                auction_id: "auction-1".into(),
                bidder_id: "buyer-1".into(),
                display_name: None,
                amount_cents: 2_700,
            }))
            .is_err(),
            "place_bid"
        );
    }

    #[test]
    fn unified_order_history_decodes_the_api_payload_across_the_boundary() {
        use serde_json::json;
        use wiremock::{
            matchers::{method, path, query_param},
            Mock, MockServer, ResponseTemplate,
        };

        let server_runtime = tokio::runtime::Runtime::new().expect("wiremock runtime");
        let server = server_runtime.block_on(MockServer::start());
        server_runtime.block_on(async {
            Mock::given(method("GET"))
                .and(path("/checkout/orders"))
                .and(query_param("buyerId", "buyer-ff39f82b"))
                .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                    "orders": [{
                        "id": "order_a48d06cf-6c67-4375-8f25-7664243597b0",
                        "source": "checkout",
                        "buyerId": "buyer-ff39f82b",
                        "eventId": "sunday-drop",
                        "eventTitle": "Sunday vintage drop",
                        "sellerName": "Marsh & Co Vintage",
                        "status": "paid",
                        "createdAt": "2026-08-14T21:50:00.000Z",
                        "subtotalCents": 19900,
                        "shippingCents": 1005,
                        "totalCents": 20905,
                        "currency": "USD",
                        "items": [{
                            "productId": "cloud-anc-headphones",
                            "title": "Cloud ANC Headphones",
                            "quantity": 1,
                            "unitPriceCents": 19900,
                            "imageUrl": null
                        }],
                        "videoSnapshots": []
                    }]
                })))
                .mount(&server)
                .await;
        });

        let client = SideStageClient::new(server.uri()).expect("client");
        client
            .set_session(Some(ApiSession {
                buyer_id: "buyer-ff39f82b".into(),
                access_token: None,
            }))
            .expect("session");

        let orders = block_on_foreign_executor(client.order_history()).expect("unified orders");

        assert_eq!(orders.len(), 1);
        assert_eq!(orders[0].id, "order_a48d06cf-6c67-4375-8f25-7664243597b0");
        assert_eq!(orders[0].source, OrderSource::Checkout);
        assert_eq!(orders[0].status, OrderStatus::Paid);
        assert_eq!(orders[0].items[0].unit_price_cents, 19_900);
        assert_eq!(orders[0].total_cents, 20_905);
    }

    #[test]
    fn live_event_sync_runs_without_an_ambient_runtime() {
        // The whole point of the owned runtime: this is a PLAIN sync test with
        // no `#[tokio::test]`, exactly like the foreign executor's thread. The
        // core's `tokio::spawn` would panic here if the boundary did not enter
        // its own runtime first.
        let client = SideStageClient::new("https://api.example.test/v1".into())
            .expect("client with an owned runtime");
        let sync = client
            .live_event_sync("drop".into())
            .expect("a live event subscription");
        sync.stop();
    }

    #[test]
    fn live_event_sync_rejects_an_unusable_event_id_before_spawning() {
        let client = SideStageClient::new("https://api.example.test/v1".into()).expect("client");
        assert!(matches!(
            client.live_event_sync("   ".into()),
            Err(ApiError::Http { status: 400, .. })
        ));
    }

    #[test]
    fn live_updates_cross_the_boundary_with_their_payloads_intact() {
        let auction = core::LiveAuction {
            id: "auction-1".into(),
            event_id: "drop".into(),
            event_item_id: "item-1".into(),
            product_id: "mug/red".into(),
            quantity: 1,
            starting_price_cents: 2_000,
            current_price_cents: 2_600,
            status: core::AuctionStatus::Active,
            started_at: "2026-08-14T12:00:00Z".into(),
            ends_at: "2026-08-14T12:01:00Z".into(),
            closed_at: None,
            bids: vec![core::AuctionBid {
                id: "bid-1".into(),
                bidder_id: "buyer-1".into(),
                display_name: Some("Avi".into()),
                amount_cents: 2_600,
                created_at: "2026-08-14T12:00:30Z".into(),
            }],
            winner_order: None,
        };
        let snapshot = core::LiveEventSnapshot {
            event_id: "drop".into(),
            transcript: vec![core::EventTranscriptEntry {
                id: "message-1".into(),
                event_id: "drop".into(),
                user_id: "buyer-1".into(),
                display_name: "Avi".into(),
                role: core::ChatRole::Buyer,
                text: "Show the base".into(),
                created_at: "2026-08-14T12:00:00Z".into(),
                grounding: None,
            }],
            on_deck_product: None,
            auction: Some(auction),
        };

        let update = LiveEventUpdate::from(core::LiveEventUpdate::Snapshot {
            snapshot: Box::new(snapshot),
        });
        let LiveEventUpdate::Snapshot { snapshot } = update else {
            panic!("expected a snapshot update");
        };
        let auction = snapshot.auction.expect("the snapshot carries its auction");
        assert_eq!(auction.current_price_cents, 2_600);
        assert_eq!(auction.status, AuctionStatus::Active);
        // Bid identity must survive: the shell highlights the buyer's own bid.
        assert_eq!(auction.bids[0].bidder_id, "buyer-1");
        assert_eq!(auction.bids[0].display_name.as_deref(), Some("Avi"));
        assert_eq!(snapshot.transcript[0].role, ChatRole::Buyer);

        assert_eq!(
            LiveSyncStatus::from(core::LiveSyncStatus::Polling { retry_in_ms: 1_500 }),
            LiveSyncStatus::Polling { retry_in_ms: 1_500 }
        );
    }

    #[test]
    fn free_form_json_fields_cross_as_text_rather_than_being_dropped() {
        let entry = EventTranscriptEntry::from(core::EventTranscriptEntry {
            id: "message-1".into(),
            event_id: "drop".into(),
            user_id: "seller-1".into(),
            display_name: "Studio".into(),
            role: core::ChatRole::Seller,
            text: "Base is walnut".into(),
            created_at: "2026-08-14T12:00:00Z".into(),
            grounding: Some(serde_json::json!({ "productId": "mug/red" })),
        });
        let grounding = entry.grounding_json.expect("grounding survives as text");
        assert!(grounding.contains("mug/red"));
    }

    #[test]
    fn maps_core_http_errors_without_losing_status() {
        let error = ApiError::from(core::ApiError::Http {
            status: 422,
            message: "shipping rate expired".into(),
        });
        assert!(matches!(
            error,
            ApiError::Http {
                status: 422,
                detail
            } if detail == "shipping rate expired"
        ));
    }
}
