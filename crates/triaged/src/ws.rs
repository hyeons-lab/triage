use std::collections::HashMap;
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use hyper::server::conn::http1;
use hyper_util::rt::TokioIo;
use serde::Deserialize;
use tokio::net::TcpListener;
use tokio::process::Command;
use tokio::sync::Semaphore;
use tokio_tungstenite::tungstenite::Message;
use triage_transport_ws::{
    ProtocolError, ServerMessage, WebSocketSessionConnection, flatbuffers_proto,
};

use crate::http::WebAssetCache;
use crate::session::SessionManager;

/// Start the multiplexed HTTP and WebSocket server using a dedicated Tokio runtime.
pub fn start_websocket_server(
    manager: Arc<SessionManager>,
    listener: std::net::TcpListener,
    cache: Arc<WebAssetCache>,
    pair_approval_tailnet_users: Vec<String>,
) -> Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("triage-ws-runtime")
        .build()
        .context("building Tokio runtime for multiplexed HTTP server")?;

    let pair_approval = PairApproval::new(pair_approval_tailnet_users);
    if pair_approval.allowlist.is_empty() {
        tracing::info!("Pairing approval restricted to loopback / same-host peers");
    } else {
        tracing::info!(
            tailnet_users = pair_approval.allowlist.len(),
            "Pairing approval also permitted for configured tailnet identities"
        );
    }

    rt.block_on(async move {
        listener.set_nonblocking(true).context("setting socket to non-blocking")?;
        let listener = TcpListener::from_std(listener)
            .context("converting std TcpListener to Tokio TcpListener")?;
        let bind_addr = listener.local_addr().ok();
        tracing::info!(bind_addr = ?bind_addr, "Multiplexed HTTP + WebSocket server listening");

        loop {
            match listener.accept().await {
                Ok((stream, addr)) => {
                    tracing::debug!(client_addr = %addr, "Accepted TCP connection");
                    let manager = Arc::clone(&manager);
                    let cache = Arc::clone(&cache);
                    let pair_approval = pair_approval.clone();
                    tokio::spawn(async move {
                        tracing::debug!(client_addr = %addr, "Spawning HTTP/WebSocket handler");
                        let io = TokioIo::new(stream);
                        let service = hyper::service::service_fn(move |req| {
                            let cache = Arc::clone(&cache);
                            let manager = Arc::clone(&manager);
                            let pair_approval = pair_approval.clone();
                            tracing::debug!(
                                method = %req.method(),
                                path = %req.uri().path(),
                                "Received HTTP request"
                            );
                            async move {
                                // `serve_http` owns the `/pair` route and invokes
                                // this authorizer lazily — only for a GET to the
                                // pairing page, after its own method check — so
                                // non-pairing and non-GET requests never trigger
                                // a `tailscale whois` lookup.
                                crate::http::serve_http(req, cache, manager, move || {
                                    pair_approval.allow(addr, bind_addr)
                                })
                                .await
                            }
                        });

                        if let Err(error) = http1::Builder::new()
                            .serve_connection(io, service)
                            .with_upgrades()
                            .await
                        {
                            tracing::debug!(error = ?error, client_addr = %addr, "HTTP/WebSocket connection finished or closed");
                        }
                    });
                }
                Err(error) => {
                    tracing::warn!(error = ?error, "failed to accept TCP connection");
                }
            }
        }
    })
}

const TAILSCALE_WHOIS_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a resolved (or failed) `tailscale whois` result is reused before a
/// fresh lookup. Short enough that allowlist/identity changes take effect
/// quickly, long enough that a burst of `/pair` requests from one peer triggers
/// at most one subprocess.
const WHOIS_CACHE_TTL: Duration = Duration::from_secs(10);
/// Upper bound on cached peer entries; stale entries are pruned past this.
const WHOIS_CACHE_MAX_ENTRIES: usize = 1024;
/// Maximum concurrent `tailscale whois` subprocesses across all connections.
const MAX_CONCURRENT_WHOIS: usize = 4;

/// Decides whether a peer may open the `/pair` approval page.
///
/// The tailnet allowlist is normalized once at construction; per-peer
/// `tailscale whois` results are cached for a short TTL and the number of
/// concurrent subprocesses is bounded, so an unauthenticated peer hammering
/// `/pair` cannot amplify into an unbounded fork/exec load.
#[derive(Clone)]
struct PairApproval {
    /// Allowlisted tailnet logins, normalized and de-duplicated once.
    allowlist: Arc<Vec<String>>,
    /// Short-TTL cache of `tailscale whois` results, keyed by peer IP.
    cache: Arc<Mutex<HashMap<IpAddr, CachedLogin>>>,
    /// Bounds the number of concurrent `tailscale whois` subprocesses.
    whois_limit: Arc<Semaphore>,
}

struct CachedLogin {
    resolved_at: Instant,
    login: Option<String>,
}

impl PairApproval {
    fn new(tailnet_users: Vec<String>) -> Self {
        let mut allowlist: Vec<String> = tailnet_users
            .iter()
            .filter_map(|user| normalize_tailnet_login(user))
            .collect();
        allowlist.sort();
        allowlist.dedup();
        Self {
            allowlist: Arc::new(allowlist),
            cache: Arc::new(Mutex::new(HashMap::new())),
            whois_limit: Arc::new(Semaphore::new(MAX_CONCURRENT_WHOIS)),
        }
    }

    async fn allow(self, peer_addr: SocketAddr, listener_addr: Option<SocketAddr>) -> bool {
        allow_pairing_approval_with_resolver(peer_addr, listener_addr, &self.allowlist, |addr| {
            self.resolve_login(addr)
        })
        .await
    }

    /// Resolve a peer's tailnet login, reusing a recent cached result and
    /// bounding concurrent subprocesses.
    async fn resolve_login(&self, peer_addr: SocketAddr) -> Option<String> {
        let peer_ip = peer_addr.ip();
        if let Some(login) = self.cached_login(peer_ip) {
            return login;
        }

        // Bound concurrent subprocesses. `acquire` only errors if the semaphore
        // is closed, which never happens here.
        let _permit = self.whois_limit.acquire().await.ok()?;
        let login = tailscale_whois_login(peer_addr, TAILSCALE_WHOIS_TIMEOUT).await;
        drop(_permit);
        self.store_login(peer_ip, login.clone());
        login
    }

    fn cached_login(&self, peer_ip: IpAddr) -> Option<Option<String>> {
        // Recover from a poisoned lock instead of panicking, so a prior panic
        // elsewhere never crashes pairing — at worst we lose a cache entry.
        let cache = self
            .cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        cache
            .get(&peer_ip)
            .filter(|entry| entry.resolved_at.elapsed() < WHOIS_CACHE_TTL)
            .map(|entry| entry.login.clone())
    }

    fn store_login(&self, peer_ip: IpAddr, login: Option<String>) {
        let mut cache = self
            .cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if cache.len() >= WHOIS_CACHE_MAX_ENTRIES {
            // Drop expired entries first; if every entry is still fresh (a flood
            // of unique peers), evict the oldest so the map stays capped.
            cache.retain(|_, entry| entry.resolved_at.elapsed() < WHOIS_CACHE_TTL);
            while cache.len() >= WHOIS_CACHE_MAX_ENTRIES {
                let Some(oldest) = cache
                    .iter()
                    .min_by_key(|(_, entry)| entry.resolved_at)
                    .map(|(ip, _)| *ip)
                else {
                    break;
                };
                cache.remove(&oldest);
            }
        }
        cache.insert(
            peer_ip,
            CachedLogin {
                resolved_at: Instant::now(),
                login,
            },
        );
    }
}

async fn allow_pairing_approval_with_resolver<R, Fut>(
    peer_addr: SocketAddr,
    listener_addr: Option<SocketAddr>,
    tailnet_allowlist: &[String],
    resolve_tailnet_login: R,
) -> bool
where
    R: FnOnce(SocketAddr) -> Fut,
    Fut: Future<Output = Option<String>>,
{
    if is_local_pairing_peer(peer_addr, listener_addr) {
        return true;
    }

    if tailnet_allowlist.is_empty() {
        return false;
    }

    let Some(login) = resolve_tailnet_login(peer_addr).await else {
        return false;
    };

    tailnet_login_is_allowed(&login, tailnet_allowlist)
}

async fn tailscale_whois_login(addr: SocketAddr, timeout: Duration) -> Option<String> {
    let mut command = Command::new("tailscale");
    command
        .arg("whois")
        .arg("--json")
        .arg(whois_addr_arg(addr))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            tracing::debug!(error = ?error, "failed to start tailscale whois");
            return None;
        }
    };

    let output = match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => {
            tracing::debug!(error = ?error, "tailscale whois failed");
            return None;
        }
        Err(_) => {
            tracing::debug!(client_addr = %addr, "tailscale whois timed out");
            return None;
        }
    };

    if !output.status.success() {
        tracing::debug!(
            client_addr = %addr,
            status = ?output.status.code(),
            stderr = %String::from_utf8_lossy(&output.stderr).trim(),
            "tailscale whois returned non-zero status"
        );
        return None;
    }

    let login = parse_tailscale_whois_login(&output.stdout);
    if login.is_none() {
        tracing::debug!(
            client_addr = %addr,
            "tailscale whois response did not include UserProfile.LoginName"
        );
    }
    login
}

#[derive(Debug, Deserialize)]
struct TailscaleWhois {
    #[serde(rename = "UserProfile")]
    user_profile: Option<TailscaleUserProfile>,
}

#[derive(Debug, Deserialize)]
struct TailscaleUserProfile {
    #[serde(rename = "LoginName")]
    login_name: Option<String>,
}

fn parse_tailscale_whois_login(input: &[u8]) -> Option<String> {
    let whois: TailscaleWhois = serde_json::from_slice(input).ok()?;
    whois
        .user_profile?
        .login_name
        .and_then(|login| normalize_tailnet_login(&login))
}

fn normalize_tailnet_login(login: &str) -> Option<String> {
    let login = login.trim().to_lowercase();
    (!login.is_empty()).then_some(login)
}

/// Check a resolved login against the allowlist. The allowlist entries are
/// already normalized (see [`PairApproval::new`]); only the incoming login is
/// normalized here.
fn tailnet_login_is_allowed(login: &str, tailnet_allowlist: &[String]) -> bool {
    let Some(login) = normalize_tailnet_login(login) else {
        return false;
    };

    tailnet_allowlist.iter().any(|allowed| allowed == &login)
}

/// Build the address argument for `tailscale whois`. An IPv4-mapped IPv6 peer
/// address (e.g. a v4 tailnet client accepted on a dual-stack `[::]` listener)
/// is unmapped to its canonical IPv4 form, which is what `tailscale whois`
/// recognizes; real IPv6 and IPv4 addresses pass through unchanged.
fn whois_addr_arg(addr: SocketAddr) -> String {
    match addr.ip() {
        IpAddr::V6(ip) => match ip.to_ipv4_mapped() {
            Some(v4) => SocketAddr::new(IpAddr::V4(v4), addr.port()).to_string(),
            None => addr.to_string(),
        },
        IpAddr::V4(_) => addr.to_string(),
    }
}

fn is_local_pairing_peer(peer_addr: SocketAddr, listener_addr: Option<SocketAddr>) -> bool {
    let peer_ip = peer_addr.ip();
    if is_loopback_ip(peer_ip) {
        return true;
    }

    listener_addr.is_some_and(|listener_addr| {
        let listener_ip = listener_addr.ip();
        !is_unspecified_ip(listener_ip) && same_ip_address(peer_ip, listener_ip)
    })
}

fn is_loopback_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_loopback(),
        IpAddr::V6(ip) => {
            ip.is_loopback() || ip.to_ipv4_mapped().is_some_and(|ip| ip.is_loopback())
        }
    }
}

fn is_unspecified_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_unspecified(),
        IpAddr::V6(ip) => ip.is_unspecified(),
    }
}

fn same_ip_address(left: IpAddr, right: IpAddr) -> bool {
    left == right
        || mapped_ipv4(left)
            .zip(mapped_ipv4(right))
            .is_some_and(|(left, right)| left == right)
}

fn mapped_ipv4(ip: IpAddr) -> Option<Ipv4Addr> {
    match ip {
        IpAddr::V4(ip) => Some(ip),
        IpAddr::V6(ip) => ip.to_ipv4_mapped(),
    }
}

/// Handle upgraded WebSocket connections on the Hyper multiplexed port.
pub async fn handle_upgraded_ws<S>(
    manager: Arc<SessionManager>,
    ws_stream: tokio_tungstenite::WebSocketStream<S>,
    format: triage_transport_ws::ProtocolFormat,
) -> Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    tracing::debug!(?format, "Upgraded WebSocket client connected");

    let (mut ws_sender, mut ws_receiver) = ws_stream.split();
    let global_rx = manager.register_global_receiver();
    let mut conn =
        WebSocketSessionConnection::with_authenticator(Arc::clone(&manager), Arc::clone(&manager))
            .with_format(format)
            .with_global_receiver(global_rx);

    let mut next_msg = ws_receiver.next();

    loop {
        tokio::select! {
            maybe_msg = &mut next_msg => {
                match maybe_msg {
                    Some(Ok(msg)) => {
                        match msg {
                            Message::Text(text) => {
                                if format == triage_transport_ws::ProtocolFormat::Json {
                                    let response = conn.handle_text_message(&text);
                                    if ws_sender.send(Message::Text(response)).await.is_err() {
                                        break;
                                    }
                                } else {
                                    let err_response = ServerMessage::Error {
                                        id: None,
                                        error: ProtocolError::new("invalid_frame_type", "Expected binary frame for FlatBuffers subprotocol"),
                                    };
                                    let bytes = flatbuffers_proto::serialize_server_message(&err_response);
                                    let _ = ws_sender.send(Message::Binary(bytes)).await;
                                    break;
                                }
                            }
                            Message::Binary(bytes) => {
                                if format == triage_transport_ws::ProtocolFormat::Flatbuffers {
                                    let response = conn.handle_binary_message(&bytes);
                                    if ws_sender.send(Message::Binary(response)).await.is_err() {
                                        break;
                                    }
                                } else {
                                    let err_response = ServerMessage::Error {
                                        id: None,
                                        error: ProtocolError::new("invalid_frame_type", "Expected text frame for JSON subprotocol"),
                                    };
                                    if let Ok(text) = serde_json::to_string(&err_response) {
                                        let _ = ws_sender.send(Message::Text(text)).await;
                                    }
                                    break;
                                }
                            }
                            Message::Close(_) => {
                                tracing::debug!("WebSocket client disconnected");
                                break;
                            }
                            _ => {}
                        }
                    }
                    Some(Err(err)) => {
                        tracing::debug!(error = ?err, "WebSocket client connection error");
                        break;
                    }
                    None => {
                        tracing::debug!("WebSocket client connection closed");
                        break;
                    }
                }
                next_msg = ws_receiver.next();
            }
            _ = tokio::time::sleep(Duration::from_millis(10)) => {
                let messages = conn.drain_events();
                let mut send_failed = false;
                for msg in messages {
                    match format {
                        triage_transport_ws::ProtocolFormat::Json => {
                            let serialized = serde_json::to_string(&msg)
                                .context("serializing session event")?;
                            if ws_sender.send(Message::Text(serialized)).await.is_err() {
                                send_failed = true;
                                break;
                            }
                        }
                        triage_transport_ws::ProtocolFormat::Flatbuffers => {
                            let serialized = triage_transport_ws::flatbuffers_proto::serialize_server_message(&msg);
                            if ws_sender.send(Message::Binary(serialized)).await.is_err() {
                                send_failed = true;
                                break;
                            }
                        }
                    }
                }
                if send_failed {
                    break;
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_pairing_peer_accepts_loopback_peer() {
        assert!(is_local_pairing_peer(
            "127.0.0.1:50123".parse().unwrap(),
            Some("0.0.0.0:7777".parse().unwrap())
        ));
        assert!(is_local_pairing_peer(
            "[::ffff:127.0.0.1]:50123".parse().unwrap(),
            Some("[::]:7777".parse().unwrap())
        ));
    }

    #[test]
    fn local_pairing_peer_accepts_same_concrete_listener_address() {
        assert!(is_local_pairing_peer(
            "192.168.1.10:50123".parse().unwrap(),
            Some("192.168.1.10:7777".parse().unwrap())
        ));
    }

    #[test]
    fn local_pairing_peer_rejects_remote_peer_on_concrete_or_wildcard_listener() {
        assert!(!is_local_pairing_peer(
            "192.168.1.11:50123".parse().unwrap(),
            Some("192.168.1.10:7777".parse().unwrap())
        ));
        assert!(!is_local_pairing_peer(
            "192.168.1.11:50123".parse().unwrap(),
            Some("0.0.0.0:7777".parse().unwrap())
        ));
    }

    #[tokio::test]
    async fn pairing_approval_empty_allowlist_rejects_without_whois() {
        let mut called = false;
        let allowed = allow_pairing_approval_with_resolver(
            "192.168.1.11:50123".parse().unwrap(),
            Some("0.0.0.0:7777".parse().unwrap()),
            &[],
            |_addr| {
                called = true;
                async { Some("alice@example.com".to_string()) }
            },
        )
        .await;

        assert!(!allowed);
        assert!(!called);
    }

    #[tokio::test]
    async fn pairing_approval_accepts_allowlisted_tailnet_login() {
        // The allowlist is pre-normalized (see PairApproval::new); the resolver
        // here returns an un-normalized login to exercise input normalization.
        let allowlist = vec!["alice@example.com".to_string()];
        let allowed = allow_pairing_approval_with_resolver(
            "100.100.100.50:50123".parse().unwrap(),
            Some("0.0.0.0:7777".parse().unwrap()),
            &allowlist,
            |_addr| async { Some(" Alice@Example.com ".to_string()) },
        )
        .await;

        assert!(allowed);
    }

    #[test]
    fn pair_approval_normalizes_and_dedupes_allowlist() {
        let approval = PairApproval::new(vec![
            "  Alice@Example.com ".to_string(),
            "alice@example.com".to_string(),
            "BOB@example.com".to_string(),
            "   ".to_string(),
        ]);

        assert_eq!(
            approval.allowlist.as_slice(),
            [
                "alice@example.com".to_string(),
                "bob@example.com".to_string()
            ]
        );
    }

    #[test]
    fn whois_addr_arg_unmaps_v4_mapped_v6() {
        assert_eq!(
            whois_addr_arg("[::ffff:100.100.100.50]:50123".parse().unwrap()),
            "100.100.100.50:50123"
        );
        assert_eq!(
            whois_addr_arg("100.100.100.50:50123".parse().unwrap()),
            "100.100.100.50:50123"
        );
        assert_eq!(
            whois_addr_arg("[fd7a:115c:a1e0::1]:50123".parse().unwrap()),
            "[fd7a:115c:a1e0::1]:50123"
        );
    }

    #[tokio::test]
    async fn pair_approval_caches_whois_per_peer() {
        let approval = PairApproval::new(vec!["alice@example.com".to_string()]);
        let peer: SocketAddr = "100.100.100.50:50123".parse().unwrap();

        // First lookup misses the cache and runs the (here, synthetic) resolver.
        approval.store_login(peer.ip(), Some("alice@example.com".to_string()));
        assert_eq!(
            approval.cached_login(peer.ip()),
            Some(Some("alice@example.com".to_string()))
        );

        // A different peer is not served from another peer's entry.
        assert_eq!(
            approval.cached_login("100.100.100.51:1".parse::<SocketAddr>().unwrap().ip()),
            None
        );
    }

    #[test]
    fn pair_approval_cache_stays_capped_under_unique_peers() {
        let approval = PairApproval::new(vec!["alice@example.com".to_string()]);
        // More unique, still-fresh peers than the cap; the map must not grow
        // past WHOIS_CACHE_MAX_ENTRIES.
        for i in 0..(WHOIS_CACHE_MAX_ENTRIES + 50) {
            let ip = IpAddr::V4(Ipv4Addr::new(100, 100, (i / 256) as u8, (i % 256) as u8));
            approval.store_login(ip, None);
        }
        let len = approval.cache.lock().unwrap().len();
        assert!(len <= WHOIS_CACHE_MAX_ENTRIES, "cache grew to {len}");
    }

    #[tokio::test]
    async fn pairing_approval_rejects_non_allowlisted_tailnet_login() {
        let allowlist = vec!["alice@example.com".to_string()];
        let allowed = allow_pairing_approval_with_resolver(
            "100.100.100.50:50123".parse().unwrap(),
            Some("0.0.0.0:7777".parse().unwrap()),
            &allowlist,
            |_addr| async { Some("bob@example.com".to_string()) },
        )
        .await;

        assert!(!allowed);
    }

    #[test]
    fn tailscale_whois_login_parser_extracts_login_name() {
        let json = br#"{
            "Node": {"ComputedName": "phone"},
            "UserProfile": {
                "ID": 1,
                "LoginName": " Alice@Example.com ",
                "DisplayName": "Alice"
            }
        }"#;

        assert_eq!(
            parse_tailscale_whois_login(json),
            Some("alice@example.com".to_string())
        );
    }
}
