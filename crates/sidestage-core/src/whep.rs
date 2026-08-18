// SPDX-License-Identifier: MIT

//! WHEP viewer signaling and reconnect policy for the mobile live-room player.
//!
//! The playback location itself comes from the API (`EventSummary::playback_url`,
//! plan decision D-035): a full WHEP endpoint URL, or `None` when the media
//! plane is unconfigured — in which case the shells keep rendering the poster.
//!
//! This module is the shared half of plan decision D-036: everything about WHEP
//! that is NOT the WebRTC engine lives here — endpoint signaling (plain
//! HTTP/SDP), the publisher-not-ready retry schedule, the connection-loss rule,
//! and the user-facing waiting copy. The native shells own only the
//! `RTCPeerConnection` (recvonly transceivers), the local offer + bounded ICE
//! gathering wait, and attaching the remote track to the stage surface.
//!
//! The reference implementation is the web buyer:
//! `apps/web/src/streaming.ts` + `apps/web/src/buyer-stream-recovery.ts` in the
//! sidestage repo. Two of its rules were bought with real defects and MUST hold
//! here identically:
//!
//! - **WI-39733** — MediaMTX answers 404 while the event's publisher has not
//!   started yet, and the event lifecycle goes live BEFORE the seller's camera
//!   does. That 404 is a NOT-YET, not an error: the viewer re-offers on a
//!   finite backoff schedule and only then surfaces an explicit retry.
//! - **WI-39747** — once established, only peer-connection state `failed`
//!   means the media is gone for good. `disconnected` is routinely transient
//!   (ICE recovers from it); tearing down on it kills working streams.

use reqwest::{Client, StatusCode, Url};
use thiserror::Error;

/// A failure from the WHEP signaling path.
///
/// `PublisherNotReady` is deliberately its own variant rather than an
/// `Http { status: 404 }`: it is the one status with retry semantics, and the
/// shells must not have to compare numbers to find it. It is produced for a
/// 404 from ANY phase of the connect (ICE discovery or the offer POST), because
/// the web's retry path classifies the whole connect attempt the same way.
#[derive(Debug, Error)]
pub enum WhepError {
    /// HTTP 404: the event path has no publisher yet (WI-39733). Retry on the
    /// [`publisher_retry_delay_ms`] schedule instead of latching an error.
    #[error("the stream publisher has not started yet")]
    PublisherNotReady,
    #[error("invalid WHEP endpoint URL: {0}")]
    InvalidEndpoint(String),
    #[error("WHEP request failed")]
    Transport(#[from] reqwest::Error),
    #[error("media server returned HTTP {status}: {detail}")]
    Http { status: u16, detail: String },
    #[error("media server returned an empty SDP answer")]
    EmptyAnswer,
}

/// One ICE server advertised by the media server's endpoint OPTIONS response.
///
/// `credential-type` is not carried: native WebRTC engines only support
/// password credentials, which is also the only value MediaMTX emits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhepIceServer {
    pub urls: String,
    pub username: Option<String>,
    pub credential: Option<String>,
}

/// The media server's accepted answer for one WHEP offer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhepAnswer {
    /// The SDP answer to apply as the peer connection's remote description.
    pub sdp: String,
    /// The session resource to DELETE on stop, resolved absolute against the
    /// endpoint. `None` when the server did not return a Location header.
    pub resource_url: Option<String>,
}

/// Peer-connection connectivity as reported by the native WebRTC engine,
/// mirroring the standard `RTCPeerConnectionState` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerConnectionState {
    New,
    Connecting,
    Connected,
    Disconnected,
    Failed,
    Closed,
}

/// Whether an ESTABLISHED session's media is gone and will not come back on
/// its own (WI-39747). Only `Failed` qualifies: `disconnected` is routinely
/// transient and ICE recovers from it, and `closed` is what a deliberate stop
/// looks like — neither may be reported as a lost stream.
pub fn is_lost_connection_state(state: PeerConnectionState) -> bool {
    matches!(state, PeerConnectionState::Failed)
}

/// Backoff for re-offering while the publisher has not started (WI-39733).
///
/// Fast at first because the common case is a buyer already in the room when
/// the seller goes live — the gap is one camera permission prompt. It then
/// widens, and it ENDS (~96s across 10 offers): a `Live` event row is not
/// proof a seller is ever coming, and an unbounded poll would have every
/// opened dead room re-offering against MediaMTX forever.
///
/// Same values as the web's `PUBLISHER_RETRY_DELAYS_MS`; a divergence here is
/// a bug in whichever side changed.
pub const PUBLISHER_RETRY_DELAYS_MS: [u64; 10] = [
    1_000, 2_000, 3_000, 5_000, 5_000, 10_000, 10_000, 15_000, 15_000, 30_000,
];

/// How long to wait before re-offering after `attempt` failed offers
/// (0-based: 0 is the delay after the first failure), or `None` once the
/// bounded schedule is spent and the shell should stop and surface
/// [`publisher_absent_message`] with an explicit retry.
pub fn publisher_retry_delay_ms(attempt: u32) -> Option<u64> {
    PUBLISHER_RETRY_DELAYS_MS.get(attempt as usize).copied()
}

/// Shown while the room is live but the seller has not gone on camera yet.
/// About the SELLER, not the media server: identical copy to the web buyer.
pub const WAITING_FOR_PUBLISHER_MESSAGE: &str = "Waiting for the seller to start their camera…";

/// Shown once the retry schedule is spent. Identical copy to the web buyer.
pub const PUBLISHER_ABSENT_MESSAGE: &str =
    "The seller has not started their camera yet. Retry once they are on.";

/// HTTP signaling against one WHEP endpoint (the `playback_url` the API
/// serves). Owns no WebRTC state; safe to share and clone.
#[derive(Debug, Clone, Default)]
pub struct WhepSignaling {
    http: Client,
}

impl WhepSignaling {
    pub fn new() -> Self {
        Self::default()
    }

    /// Discover the ICE servers the media server advertises for this endpoint
    /// (standard WHIP/WHEP `Link: <...>; rel="ice-server"` metadata from an
    /// OPTIONS request). Production advertises a TURN relay on 443 that
    /// constrained networks need — skipping this works on easy networks and
    /// silently breaks the hard ones.
    pub async fn discover_ice_servers(
        &self,
        endpoint: &str,
    ) -> Result<Vec<WhepIceServer>, WhepError> {
        let url = parse_endpoint(endpoint)?;
        let response = self
            .http
            .request(reqwest::Method::OPTIONS, url)
            .send()
            .await?;
        let status = response.status();
        if !status.is_success() {
            return Err(status_error(status, "ICE server discovery rejected".into()));
        }
        // Fetch in the browser folds repeated Link fields into one
        // comma-separated value; reqwest keeps them separate, so fold here
        // before parsing to keep one parser for both shapes.
        let header = response
            .headers()
            .get_all(reqwest::header::LINK)
            .iter()
            .filter_map(|value| value.to_str().ok())
            .collect::<Vec<_>>()
            .join(", ");
        Ok(parse_ice_server_links(&header))
    }

    /// POST the local SDP offer and apply the exchange: returns the answer SDP
    /// plus the session resource URL (absolute) for later DELETE. The shells
    /// send an offer that already carries its ICE candidates — WHEP is vanilla
    /// ICE, candidates arriving after the POST are never delivered.
    pub async fn post_offer(
        &self,
        endpoint: &str,
        offer_sdp: &str,
    ) -> Result<WhepAnswer, WhepError> {
        let url = parse_endpoint(endpoint)?;
        let response = self
            .http
            .post(url.clone())
            .header(reqwest::header::CONTENT_TYPE, "application/sdp")
            .body(offer_sdp.to_string())
            .send()
            .await?;
        let status = response.status();
        if !status.is_success() {
            return Err(status_error(status, "WHEP offer rejected".into()));
        }

        let resource_url = response
            .headers()
            .get(reqwest::header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|location| url.join(location).ok())
            .map(|resolved| resolved.to_string());

        let sdp = response.text().await?;
        if sdp.trim().is_empty() {
            return Err(WhepError::EmptyAnswer);
        }
        Ok(WhepAnswer { sdp, resource_url })
    }

    /// Delete the session resource on stop so no stale peer lingers server
    /// side. A 404 is fine — the session is already gone, which is the goal.
    pub async fn delete_resource(&self, resource_url: &str) -> Result<(), WhepError> {
        let url = parse_endpoint(resource_url)?;
        let response = self.http.delete(url).send().await?;
        let status = response.status();
        if !status.is_success() && status != StatusCode::NOT_FOUND {
            return Err(WhepError::Http {
                status: status.as_u16(),
                detail: "media session cleanup failed".into(),
            });
        }
        Ok(())
    }
}

fn parse_endpoint(endpoint: &str) -> Result<Url, WhepError> {
    Url::parse(endpoint).map_err(|error| WhepError::InvalidEndpoint(format!("{endpoint}: {error}")))
}

fn status_error(status: StatusCode, detail: String) -> WhepError {
    if status == StatusCode::NOT_FOUND {
        WhepError::PublisherNotReady
    } else {
        WhepError::Http {
            status: status.as_u16(),
            detail,
        }
    }
}

/// Parse a `Link` header's `rel="ice-server"` entries. Handles the folded
/// (comma-joined) form: links split at a comma followed by the next `<`, so a
/// quoted comma inside a credential cannot split a link.
pub fn parse_ice_server_links(link_header: &str) -> Vec<WhepIceServer> {
    split_links(link_header)
        .into_iter()
        .filter_map(|link| {
            let (url, params) = parse_link(link)?;
            let rel = param(&params, "rel")?;
            if !rel.split_whitespace().any(|token| token == "ice-server") {
                return None;
            }
            Some(WhepIceServer {
                urls: url.to_string(),
                username: param(&params, "username"),
                credential: param(&params, "credential"),
            })
        })
        .collect()
}

fn split_links(header: &str) -> Vec<&str> {
    let mut links = Vec::new();
    let mut start = 0;
    let bytes = header.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if *byte != b',' {
            continue;
        }
        let rest = &header[index + 1..];
        if rest.trim_start().starts_with('<') {
            links.push(&header[start..index]);
            start = index + 1;
        }
    }
    links.push(&header[start..]);
    links
}

/// Split one link into its `<url>` and `name=value` parameters. Values may be
/// quoted strings with `\"` / `\\` escapes (TURN credentials routinely contain
/// characters a bare token cannot carry).
fn parse_link(link: &str) -> Option<(&str, Vec<(String, String)>)> {
    let trimmed = link.trim_start();
    let inner_start = trimmed.strip_prefix('<')?;
    let close = inner_start.find('>')?;
    let url = &inner_start[..close];
    let mut params = Vec::new();
    let mut rest = inner_start[close + 1..].chars().peekable();

    // Each iteration consumes up to and including the next parameter separator.
    while rest.find(|ch| *ch == ';').is_some() {
        // Parameter name.
        let mut name = String::new();
        while let Some(&ch) = rest.peek() {
            if ch == '=' || ch == ';' {
                break;
            }
            rest.next();
            if !ch.is_whitespace() {
                name.push(ch.to_ascii_lowercase());
            }
        }
        if rest.peek() != Some(&'=') {
            if name.is_empty() && rest.peek().is_none() {
                break;
            }
            continue;
        }
        rest.next(); // consume '='
        while matches!(rest.peek(), Some(ch) if ch.is_whitespace()) {
            rest.next();
        }
        // Parameter value: quoted (with escapes) or bare token.
        let mut value = String::new();
        if rest.peek() == Some(&'"') {
            rest.next();
            while let Some(ch) = rest.next() {
                match ch {
                    '\\' => {
                        if let Some(escaped) = rest.next() {
                            value.push(escaped);
                        }
                    }
                    '"' => break,
                    other => value.push(other),
                }
            }
        } else {
            while let Some(&ch) = rest.peek() {
                if ch == ';' || ch.is_whitespace() {
                    break;
                }
                rest.next();
                value.push(ch);
            }
        }
        if !name.is_empty() {
            params.push((name, value));
        }
    }

    Some((url, params))
}

fn param(params: &[(String, String)], name: &str) -> Option<String> {
    params
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{body_string, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    const TURN_LINK: &str = concat!(
        "<turns:media.sidestage.example:443?transport=tcp>; rel=\"ice-server\"; ",
        "username=\"1700000000:test\"; credential=\"secret==\"; credential-type=\"password\"",
    );

    #[test]
    fn parses_stun_and_turn_links_like_the_web_buyer() {
        let header = format!("<stun:stun.example:3478>; rel=\"ice-server\", {TURN_LINK}");
        assert_eq!(
            parse_ice_server_links(&header),
            vec![
                WhepIceServer {
                    urls: "stun:stun.example:3478".into(),
                    username: None,
                    credential: None,
                },
                WhepIceServer {
                    urls: "turns:media.sidestage.example:443?transport=tcp".into(),
                    username: Some("1700000000:test".into()),
                    credential: Some("secret==".into()),
                },
            ],
        );
    }

    #[test]
    fn ignores_links_without_the_ice_server_rel() {
        let header = "<https://example.test/docs>; rel=\"help\"";
        assert_eq!(parse_ice_server_links(header), Vec::new());
        assert_eq!(parse_ice_server_links(""), Vec::new());
    }

    #[test]
    fn quoted_credentials_keep_separators_and_escapes() {
        let header =
            "<turn:relay.example:3478>; rel=\"ice-server\"; credential=\"a;b,c \\\"d\\\" \\\\e\"";
        let servers = parse_ice_server_links(header);
        assert_eq!(servers.len(), 1);
        assert_eq!(servers[0].credential.as_deref(), Some("a;b,c \"d\" \\e"));
    }

    #[test]
    fn rel_with_multiple_tokens_still_matches() {
        let header = "<stun:stun.example:3478>; rel=\"stun ice-server\"";
        assert_eq!(parse_ice_server_links(header).len(), 1);
    }

    #[test]
    fn retry_schedule_matches_the_web_buyer() {
        assert_eq!(publisher_retry_delay_ms(0), Some(1_000));
        assert_eq!(publisher_retry_delay_ms(9), Some(30_000));
        assert_eq!(publisher_retry_delay_ms(10), None);
        // ~96s total across 10 offers — the web's documented budget.
        assert_eq!(PUBLISHER_RETRY_DELAYS_MS.iter().sum::<u64>(), 96_000);
    }

    #[test]
    fn only_failed_counts_as_lost() {
        assert!(is_lost_connection_state(PeerConnectionState::Failed));
        for state in [
            PeerConnectionState::New,
            PeerConnectionState::Connecting,
            PeerConnectionState::Connected,
            PeerConnectionState::Disconnected,
            PeerConnectionState::Closed,
        ] {
            assert!(!is_lost_connection_state(state));
        }
    }

    #[tokio::test]
    async fn post_offer_exchanges_sdp_and_resolves_the_resource_url() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/sidestage-evt/whep"))
            .and(header("content-type", "application/sdp"))
            .and(body_string("v=0 offer"))
            .respond_with(
                ResponseTemplate::new(201)
                    .insert_header("Location", "/sidestage-evt/whep/session-1")
                    .set_body_string("v=0 answer"),
            )
            .mount(&server)
            .await;

        let answer = WhepSignaling::new()
            .post_offer(&format!("{}/sidestage-evt/whep", server.uri()), "v=0 offer")
            .await
            .expect("offer should be accepted");
        assert_eq!(answer.sdp, "v=0 answer");
        assert_eq!(
            answer.resource_url,
            Some(format!("{}/sidestage-evt/whep/session-1", server.uri())),
        );
    }

    #[tokio::test]
    async fn post_offer_404_is_publisher_not_ready() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let error = WhepSignaling::new()
            .post_offer(&format!("{}/sidestage-evt/whep", server.uri()), "v=0 offer")
            .await
            .expect_err("404 must not decode as success");
        assert!(matches!(error, WhepError::PublisherNotReady));
    }

    #[tokio::test]
    async fn post_offer_other_statuses_are_real_errors() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let error = WhepSignaling::new()
            .post_offer(&format!("{}/sidestage-evt/whep", server.uri()), "v=0 offer")
            .await
            .expect_err("500 must not decode as success");
        assert!(matches!(error, WhepError::Http { status: 500, .. }));
    }

    #[tokio::test]
    async fn post_offer_empty_answer_is_rejected() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(201).set_body_string("   \n"))
            .mount(&server)
            .await;

        let error = WhepSignaling::new()
            .post_offer(&format!("{}/sidestage-evt/whep", server.uri()), "v=0 offer")
            .await
            .expect_err("an empty answer cannot drive a peer connection");
        assert!(matches!(error, WhepError::EmptyAnswer));
    }

    #[tokio::test]
    async fn discovery_reads_folded_and_repeated_link_headers() {
        let server = MockServer::start().await;
        Mock::given(method("OPTIONS"))
            .and(path("/sidestage-evt/whep"))
            .respond_with(
                ResponseTemplate::new(204)
                    .append_header("Link", "<stun:stun.example:3478>; rel=\"ice-server\"")
                    .append_header("Link", TURN_LINK),
            )
            .mount(&server)
            .await;

        let servers = WhepSignaling::new()
            .discover_ice_servers(&format!("{}/sidestage-evt/whep", server.uri()))
            .await
            .expect("discovery should succeed");
        assert_eq!(servers.len(), 2);
        assert_eq!(servers[1].username.as_deref(), Some("1700000000:test"));
    }

    #[tokio::test]
    async fn discovery_404_is_publisher_not_ready_for_retry_parity() {
        // The web buyer classifies the WHOLE connect attempt by status, so a
        // 404 from the OPTIONS phase retries exactly like one from the POST.
        let server = MockServer::start().await;
        Mock::given(method("OPTIONS"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let error = WhepSignaling::new()
            .discover_ice_servers(&format!("{}/sidestage-evt/whep", server.uri()))
            .await
            .expect_err("404 must not decode as success");
        assert!(matches!(error, WhepError::PublisherNotReady));
    }

    #[tokio::test]
    async fn delete_tolerates_an_already_gone_session() {
        let server = MockServer::start().await;
        Mock::given(method("DELETE"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        WhepSignaling::new()
            .delete_resource(&format!("{}/sidestage-evt/whep/session-1", server.uri()))
            .await
            .expect("a 404 means the session is already gone — that is the goal");
    }

    #[tokio::test]
    async fn delete_surfaces_real_cleanup_failures() {
        let server = MockServer::start().await;
        Mock::given(method("DELETE"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let error = WhepSignaling::new()
            .delete_resource(&format!("{}/sidestage-evt/whep/session-1", server.uri()))
            .await
            .expect_err("500 is a real cleanup failure");
        assert!(matches!(error, WhepError::Http { status: 500, .. }));
    }

    #[test]
    fn invalid_endpoints_fail_before_any_request() {
        let error = match futures_util::FutureExt::now_or_never(
            WhepSignaling::new().post_offer("not a url", "v=0 offer"),
        ) {
            Some(Err(error)) => error,
            other => panic!("expected an immediate error, got {other:?}"),
        };
        assert!(matches!(error, WhepError::InvalidEndpoint(_)));
    }
}
