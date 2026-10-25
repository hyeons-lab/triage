use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use ::http::HeaderValue;
use bytes::Bytes;
use http_body_util::Full;
use hyper::{Request, Response, StatusCode, header};
use rust_embed::RustEmbed;

#[cfg(embed_packaged_client)]
#[derive(RustEmbed)]
#[folder = "dist/"]
struct WebAsset;

#[cfg(embed_real_client)]
#[derive(RustEmbed)]
#[folder = "../../flutter/triage_client/build/web/"]
struct WebAsset;

#[cfg(not(any(embed_real_client, embed_packaged_client)))]
#[derive(RustEmbed)]
#[folder = "web_fallback/"]
struct WebAsset;

#[derive(Clone)]
pub struct CachedFile {
    pub content: Bytes,
    pub compressed_content: Option<Bytes>,
    pub content_type: &'static str,
    pub etag: String,
}

pub struct WebAssetCache {
    override_dir: Option<PathBuf>,
    cache: RwLock<HashMap<String, Arc<CachedFile>>>,
}

impl WebAssetCache {
    pub fn new(override_dir: Option<PathBuf>) -> Self {
        Self {
            override_dir,
            cache: RwLock::new(HashMap::new()),
        }
    }

    pub fn reload(&self) {
        let mut cache = self.cache.write().unwrap();
        cache.clear();
        tracing::info!("Web asset cache cleared");
    }

    pub fn get(&self, path: &str) -> Option<Arc<CachedFile>> {
        if let Some(file) = self.load_override_file(path) {
            return Some(Arc::new(file));
        }

        {
            let cache = self.cache.read().unwrap();
            if let Some(file) = cache.get(path) {
                return Some(Arc::clone(file));
            }
        }

        let file = self.load_embedded_file(path)?;
        let arc_file = Arc::new(file);

        let mut cache = self.cache.write().unwrap();
        cache.insert(path.to_string(), Arc::clone(&arc_file));
        Some(arc_file)
    }

    fn load_override_file(&self, path: &str) -> Option<CachedFile> {
        if let Some(ref dir) = self.override_dir {
            let safe_path = path.replace("..", "");
            let full_path = dir.join(&safe_path);
            let content_opt = if full_path.is_file() {
                std::fs::read(&full_path).ok()
            } else {
                None
            };
            if let Some(content) = content_opt {
                return Some(cached_file_from_bytes(path, Bytes::from(content)));
            }
        }

        None
    }

    fn load_embedded_file(&self, path: &str) -> Option<CachedFile> {
        if let Some(embedded) = WebAsset::get(path) {
            let content_bytes = Bytes::from(embedded.data.into_owned());
            return Some(cached_file_from_bytes(path, content_bytes));
        }

        None
    }
}

fn cached_file_from_bytes(path: &str, content_bytes: Bytes) -> CachedFile {
    let etag = format!("\"{}\"", sha2_hash(&content_bytes));
    let compressed_content = if should_compress(path, content_bytes.len()) {
        compress_gzip(&content_bytes).ok()
    } else {
        None
    };
    CachedFile {
        content: content_bytes,
        compressed_content,
        content_type: mime_type_for_path(path),
        etag,
    }
}

fn should_compress(path: &str, size: usize) -> bool {
    size > 512
        && (path.ends_with(".html")
            || path.ends_with(".js")
            || path.ends_with(".css")
            || path.ends_with(".json")
            || path.ends_with(".wasm")
            || path.ends_with(".svg"))
}

fn compress_gzip(bytes: &[u8]) -> std::io::Result<Bytes> {
    use flate2::Compression;
    use flate2::write::GzEncoder;
    use std::io::Write;

    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(bytes)?;
    let compressed = encoder.finish()?;
    Ok(Bytes::from(compressed))
}

/// Directory where upgraded web client assets are cached, overriding the
/// embedded bundle. The daemon reads from here and the client's upgrade flow
/// writes here, so both call this one function to stay in agreement.
///
/// On Windows this is `%LOCALAPPDATA%\triage\web` (the idiomatic per-user cache
/// location); on Unix it stays `~/.local/share/triage/web`.
pub fn default_override_dir() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        let base = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("USERPROFILE")
                    .map(|home| PathBuf::from(home).join("AppData").join("Local"))
            })?;
        Some(base.join("triage").join("web"))
    }
    #[cfg(not(windows))]
    {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .ok()?;
        Some(PathBuf::from(home).join(".local/share/triage/web"))
    }
}

pub(crate) fn mime_type_for_path(path: &str) -> &'static str {
    if path.ends_with(".html") {
        "text/html; charset=utf-8"
    } else if path.ends_with(".css") {
        "text/css; charset=utf-8"
    } else if path.ends_with(".js") {
        "application/javascript; charset=utf-8"
    } else if path.ends_with(".json") {
        "application/json; charset=utf-8"
    } else if path.ends_with(".png") {
        "image/png"
    } else if path.ends_with(".jpg") || path.ends_with(".jpeg") {
        "image/jpeg"
    } else if path.ends_with(".gif") {
        "image/gif"
    } else if path.ends_with(".svg") {
        "image/svg+xml"
    } else if path.ends_with(".wasm") {
        "application/wasm"
    } else if path.ends_with(".ico") {
        "image/x-icon"
    } else {
        "application/octet-stream"
    }
}

fn sha2_hash(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

pub async fn serve_http<B>(
    req: Request<B>,
    cache: Arc<WebAssetCache>,
    manager: Arc<crate::session::SessionManager>,
) -> Result<Response<Full<Bytes>>, Infallible>
where
    B: hyper::body::Body + Send + 'static,
{
    let method = req.method().clone();
    let path = req.uri().path().to_string();

    if let Some(raw_session_id) = parse_history_session_id(&path) {
        return Ok(handle_session_history_http(req, manager, raw_session_id).await);
    }

    if method != hyper::Method::GET {
        let mut res = Response::new(Full::new(Bytes::from("Method Not Allowed")));
        *res.status_mut() = StatusCode::METHOD_NOT_ALLOWED;
        return Ok(res);
    }

    // 1. WebSocket upgrade
    if (path == "/ws" || path == "/ws/")
        && req
            .headers()
            .get(header::UPGRADE)
            .is_some_and(|val| val == "websocket")
    {
        return Ok(handle_ws_upgrade(req, manager));
    }

    // 2. Resolve requested clean relative asset path
    let mut clean_path = path.trim_start_matches('/');
    if clean_path.is_empty() {
        clean_path = "index.html";
    }

    // 3. Retrieve from cache with fallback to index.html (SPA routing)
    let file = match cache.get(clean_path) {
        Some(file) => file,
        None => match cache.get("index.html") {
            Some(file) => file,
            None => {
                let mut res = Response::new(Full::new(Bytes::from("Not Found")));
                *res.status_mut() = StatusCode::NOT_FOUND;
                return Ok(res);
            }
        },
    };

    // 4. ETag validation
    if req
        .headers()
        .get(header::IF_NONE_MATCH)
        .is_some_and(|val| val == file.etag.as_str())
    {
        let mut res = Response::new(Full::new(Bytes::new()));
        *res.status_mut() = StatusCode::NOT_MODIFIED;
        return Ok(res);
    }

    // 5. Build HTTP response
    let accept_encoding = req
        .headers()
        .get(header::ACCEPT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    let use_gzip = accept_encoding.contains("gzip") && file.compressed_content.is_some();

    let (content, is_gzipped) = if use_gzip {
        (file.compressed_content.as_ref().unwrap().clone(), true)
    } else {
        (file.content.clone(), false)
    };

    let mut res = Response::new(Full::new(content.clone()));
    *res.status_mut() = StatusCode::OK;

    let headers = res.headers_mut();
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache, must-revalidate"),
    );
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(file.content_type),
    );
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(content.len()));
    headers.insert(header::ETAG, HeaderValue::from_str(&file.etag).unwrap());

    if is_gzipped {
        headers.insert(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));
    }

    Ok(res)
}

fn handle_ws_upgrade<B>(
    req: Request<B>,
    manager: Arc<crate::session::SessionManager>,
) -> Response<Full<Bytes>>
where
    B: hyper::body::Body + Send + 'static,
{
    let key = match req.headers().get("sec-websocket-key") {
        Some(val) => val,
        None => {
            let mut res = Response::new(Full::new(Bytes::from("Bad Request")));
            *res.status_mut() = StatusCode::BAD_REQUEST;
            return res;
        }
    };

    // Subprotocol negotiation per RFC 6455.
    // Default to FlatBuffers for performance. The client can negotiate JSON
    // by explicitly requesting triage-json without triage-flatbuffers.
    let mut selected_format = triage_transport_ws::ProtocolFormat::Flatbuffers;
    let mut selected_proto_header = None;

    if let Some(protocol_header) = req
        .headers()
        .get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok())
    {
        let mut has_fb = false;
        let mut has_json = false;
        for token in protocol_header.split(',') {
            match token.trim() {
                "triage-flatbuffers" => has_fb = true,
                "triage-json" => has_json = true,
                _ => {}
            }
        }

        if has_fb {
            selected_format = triage_transport_ws::ProtocolFormat::Flatbuffers;
            selected_proto_header = Some(HeaderValue::from_static("triage-flatbuffers"));
        } else if has_json {
            selected_format = triage_transport_ws::ProtocolFormat::Json;
            selected_proto_header = Some(HeaderValue::from_static("triage-json"));
        } else {
            selected_format = triage_transport_ws::ProtocolFormat::Flatbuffers;
        }
    }

    let accept = tokio_tungstenite::tungstenite::handshake::derive_accept_key(key.as_bytes());

    let mut res = Response::new(Full::new(Bytes::new()));
    *res.status_mut() = StatusCode::SWITCHING_PROTOCOLS;

    let headers = res.headers_mut();
    headers.insert(header::UPGRADE, HeaderValue::from_static("websocket"));
    headers.insert(header::CONNECTION, HeaderValue::from_static("Upgrade"));
    headers.insert(
        "sec-websocket-accept",
        HeaderValue::from_str(&accept).unwrap(),
    );
    if let Some(proto) = selected_proto_header {
        headers.insert("sec-websocket-protocol", proto);
    }

    // The accept loop stashes the peer address in the request extensions (see
    // `ws.rs`); read it before the upgrade consumes the request. Absent in
    // unit tests, which never upgrade — the connection then fails closed on
    // Tailscale-identity pairing for lack of a peer to whois.
    let peer_addr = req.extensions().get::<SocketAddr>().copied();
    tokio::spawn(async move {
        match hyper::upgrade::on(req).await {
            Ok(upgraded) => {
                let io = hyper_util::rt::TokioIo::new(upgraded);
                let ws_stream = tokio_tungstenite::WebSocketStream::from_raw_socket(
                    io,
                    tokio_tungstenite::tungstenite::protocol::Role::Server,
                    None,
                )
                .await;
                if let Err(error) =
                    crate::ws::handle_upgraded_ws(manager, ws_stream, selected_format, peer_addr)
                        .await
                {
                    tracing::warn!(error = ?error, "Upgraded WebSocket connection failed");
                }
            }
            Err(err) => {
                tracing::warn!(error = ?err, "Failed to upgrade connection to WebSocket");
            }
        }
    });

    res
}

pub const HISTORY_FRAME_MAGIC: &[u8; 4] = b"THS1";
pub const HISTORY_CONTENT_TYPE: &str = "application/x-triage-history";

fn parse_history_session_id(path: &str) -> Option<String> {
    let rest = path.strip_prefix("/api/sessions/")?;
    let raw_id = rest.strip_suffix("/history")?;
    if raw_id.is_empty() || raw_id.contains('/') {
        return None;
    }
    Some(percent_decode(raw_id))
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(hi), Some(lo)) = (hex_nibble(bytes[i + 1]), hex_nibble(bytes[i + 2]))
        {
            out.push((hi << 4) | lo);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn apply_history_cors_headers(headers: &mut header::HeaderMap) {
    headers.insert(
        header::ACCESS_CONTROL_ALLOW_ORIGIN,
        HeaderValue::from_static("*"),
    );
    headers.insert(
        header::ACCESS_CONTROL_ALLOW_METHODS,
        HeaderValue::from_static("GET, OPTIONS"),
    );
    headers.insert(
        header::ACCESS_CONTROL_ALLOW_HEADERS,
        HeaderValue::from_static("Authorization, X-Triage-Client-Id, Accept"),
    );
    headers.insert(
        header::ACCESS_CONTROL_MAX_AGE,
        HeaderValue::from_static("86400"),
    );
}

fn json_error_response(status: StatusCode, code: &str, message: &str) -> Response<Full<Bytes>> {
    let body = serde_json::json!({
        "error": {
            "code": code,
            "message": message,
        }
    });
    let bytes = Bytes::from(serde_json::to_vec(&body).unwrap_or_default());
    let mut res = Response::new(Full::new(bytes.clone()));
    *res.status_mut() = status;
    let headers = res.headers_mut();
    apply_history_cors_headers(headers);
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, no-cache, must-revalidate"),
    );
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json; charset=utf-8"),
    );
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(bytes.len()));
    res
}

fn extract_bearer_token(headers: &header::HeaderMap) -> Option<&str> {
    let raw = headers.get(header::AUTHORIZATION)?.to_str().ok()?.trim();
    if raw.len() > 7 && raw[..7].eq_ignore_ascii_case("bearer ") {
        let token = raw[7..].trim();
        if !token.is_empty() {
            return Some(token);
        }
    }
    None
}

pub fn encode_history_frame(meta: &serde_json::Value, prefix: &[u8], raw: &[u8]) -> Bytes {
    let meta_bytes = serde_json::to_vec(meta).unwrap_or_else(|_| b"{}".to_vec());
    let meta_len = meta_bytes.len() as u32;
    let prefix_len = prefix.len() as u32;
    let raw_len = raw.len() as u32;
    let mut out = Vec::with_capacity(16 + meta_bytes.len() + prefix.len() + raw.len());
    out.extend_from_slice(HISTORY_FRAME_MAGIC);
    out.extend_from_slice(&meta_len.to_le_bytes());
    out.extend_from_slice(&prefix_len.to_le_bytes());
    out.extend_from_slice(&raw_len.to_le_bytes());
    out.extend_from_slice(&meta_bytes);
    out.extend_from_slice(prefix);
    out.extend_from_slice(raw);
    Bytes::from(out)
}

async fn handle_session_history_http<B>(
    req: Request<B>,
    manager: Arc<crate::session::SessionManager>,
    raw_session_id: String,
) -> Response<Full<Bytes>>
where
    B: hyper::body::Body + Send + 'static,
{
    use triage_transport_ws::WebSocketAuthenticator;

    if req.method() == hyper::Method::OPTIONS {
        let mut res = Response::new(Full::new(Bytes::new()));
        *res.status_mut() = StatusCode::NO_CONTENT;
        apply_history_cors_headers(res.headers_mut());
        return res;
    }

    if req.method() != hyper::Method::GET {
        return json_error_response(
            StatusCode::METHOD_NOT_ALLOWED,
            "method_not_allowed",
            "only GET and OPTIONS are supported",
        );
    }

    if manager.require_pairing() {
        let Some(token) = extract_bearer_token(req.headers()) else {
            return json_error_response(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "missing or invalid Authorization bearer token",
            );
        };
        let Some(raw_client_id) = req
            .headers()
            .get("x-triage-client-id")
            .and_then(|v| v.to_str().ok())
            .map(str::trim)
            .filter(|v| !v.is_empty())
        else {
            return json_error_response(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "missing X-Triage-Client-Id header",
            );
        };
        let Ok(client_id) = triage_core::session::ClientId::new(raw_client_id) else {
            return json_error_response(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "invalid X-Triage-Client-Id header",
            );
        };
        match manager.authenticate(&client_id, token) {
            Ok(true) => {}
            Ok(false) | Err(_) => {
                return json_error_response(
                    StatusCode::UNAUTHORIZED,
                    "unauthorized",
                    "invalid client credentials",
                );
            }
        }
    }

    let Ok(session_id) = triage_core::session::SessionId::new(raw_session_id) else {
        return json_error_response(
            StatusCode::BAD_REQUEST,
            "invalid_session_id",
            "invalid session_id",
        );
    };

    let mut window_bytes = None;
    let mut after_byte = None;
    let mut after_seq = None;
    let mut before_byte = None;
    if let Some(query_str) = req.uri().query() {
        for pair in query_str.split('&').filter(|s| !s.is_empty()) {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            match key {
                "window_bytes" => match value.parse::<u64>() {
                    Ok(v) => window_bytes = Some(v),
                    Err(_) => {
                        return json_error_response(
                            StatusCode::BAD_REQUEST,
                            "invalid_query",
                            "invalid window_bytes query parameter",
                        );
                    }
                },
                "after_byte" => match value.parse::<u64>() {
                    Ok(v) => after_byte = Some(v),
                    Err(_) => {
                        return json_error_response(
                            StatusCode::BAD_REQUEST,
                            "invalid_query",
                            "invalid after_byte query parameter",
                        );
                    }
                },
                "after_seq" => match value.parse::<u64>() {
                    Ok(v) => after_seq = Some(v),
                    Err(_) => {
                        return json_error_response(
                            StatusCode::BAD_REQUEST,
                            "invalid_query",
                            "invalid after_seq query parameter",
                        );
                    }
                },
                "before_byte" => match value.parse::<u64>() {
                    Ok(v) => before_byte = Some(v),
                    Err(_) => {
                        return json_error_response(
                            StatusCode::BAD_REQUEST,
                            "invalid_query",
                            "invalid before_byte query parameter",
                        );
                    }
                },
                _ => {}
            }
        }
    }

    let accept_gzip = req
        .headers()
        .get(header::ACCEPT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.contains("gzip"));

    let query = crate::session::SessionHistoryQuery {
        session_id,
        window_bytes,
        after_byte,
        after_seq,
        before_byte,
    };

    let blocking = tokio::task::spawn_blocking(move || {
        let history = manager.fetch_session_history(&query)?;
        let meta = serde_json::json!({
            "session_id": history.session_id.as_str(),
            "output_seq": history.output_seq,
            "bytes_logged": history.bytes_logged,
            "raw_output_start": history.raw_output_start,
            "raw_output_end": history.raw_output_end,
            "raw_output_truncated": history.raw_output_truncated,
            "size": {
                "rows": history.size.rows,
                "cols": history.size.cols,
                "pixel_width": history.size.pixel_width,
                "pixel_height": history.size.pixel_height,
                "dpi": history.size.dpi,
            },
            "exited": history.exited,
            "bracketed_paste_enabled": history.bracketed_paste_enabled,
            "current_working_directory": history
                .current_working_directory
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            "context": history.context.as_ref().map(|ctx| serde_json::json!({
                "repository_root": ctx.repository_root.as_ref().map(|p| p.to_string_lossy().into_owned()),
                "worktree_root": ctx.worktree_root.as_ref().map(|p| p.to_string_lossy().into_owned()),
                "branch": ctx.branch_name(),
            })),
            "snippet": history.snippet,
            "snippet_detail": history.snippet_detail,
        });
        let frame = encode_history_frame(&meta, &history.raw_output_prefix, &history.raw_output);
        if accept_gzip
            && frame.len() > 256
            && let Ok(compressed) = compress_gzip(&frame)
        {
            return Ok::<(Bytes, bool), anyhow::Error>((compressed, true));
        }
        Ok((frame, false))
    })
    .await;

    let (body, is_gzipped) = match blocking {
        Ok(Ok(pair)) => pair,
        Ok(Err(error)) => {
            let msg = error.to_string();
            let status = if msg.contains("not found") {
                StatusCode::NOT_FOUND
            } else {
                StatusCode::BAD_REQUEST
            };
            return json_error_response(status, "history_error", &msg);
        }
        Err(join_error) => {
            return json_error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                &join_error.to_string(),
            );
        }
    };

    let mut res = Response::new(Full::new(body.clone()));
    *res.status_mut() = StatusCode::OK;
    let headers = res.headers_mut();
    apply_history_cors_headers(headers);
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, no-cache, must-revalidate"),
    );
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(HISTORY_CONTENT_TYPE),
    );
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(body.len()));
    if is_gzipped {
        headers.insert(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));
    }
    res
}

#[cfg(all(test, any(embed_real_client, embed_packaged_client)))]
mod tests {
    use super::*;

    #[test]
    fn embedded_web_assets_contain_main_dart_js() {
        let file = WebAsset::get("main.dart.js").expect("main.dart.js must be embedded");
        eprintln!("main.dart.js length: {}", file.data.len());
        eprintln!("main.dart.js etag sha256: {}", sha2_hash(&file.data));
        let font =
            WebAsset::get("assets/fonts/MaterialIcons-Regular.otf").expect("font must be embedded");
        eprintln!("MaterialIcons length: {}", font.data.len());
    }
}

#[cfg(test)]
mod history_http_tests {
    use super::*;
    use crate::session::{LEASE_PROBE_HISTORY_BYTES, SessionManager, SessionManagerConfig};
    use http_body_util::BodyExt;
    use std::time::{Duration, Instant};
    use triage_core::session::{
        AttachMode, AttachSessionRequest, ClientId, SessionApi, SessionSize, StartSessionRequest,
    };
    use triage_transport_ws::WebSocketAuthenticator;

    fn decode_test_frame(bytes: &[u8]) -> (serde_json::Value, Vec<u8>, Vec<u8>) {
        assert!(bytes.len() >= 16);
        assert_eq!(&bytes[0..4], HISTORY_FRAME_MAGIC);
        let meta_len = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
        let prefix_len = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
        let raw_len = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        assert_eq!(bytes.len(), 16 + meta_len + prefix_len + raw_len);
        let meta: serde_json::Value =
            serde_json::from_slice(&bytes[16..16 + meta_len]).expect("meta json");
        let prefix_start = 16 + meta_len;
        let raw_start = prefix_start + prefix_len;
        let prefix = bytes[prefix_start..raw_start].to_vec();
        let raw = bytes[raw_start..raw_start + raw_len].to_vec();
        (meta, prefix, raw)
    }

    #[tokio::test]
    async fn history_http_endpoint_enforces_auth_and_serves_tail_delta_and_backward_pages() {
        let log_dir = std::env::temp_dir().join(format!(
            "triage-http-history-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let config = SessionManagerConfig::new(log_dir.clone());
        let manager = Arc::new(SessionManager::new(config));
        let cache = Arc::new(WebAssetCache::new(None));

        let client_id = ClientId::new("http-test-client").unwrap();
        let challenge = manager.request_pairing_challenge(&client_id).unwrap();
        let pin = manager
            .approve_pairing_device_code(&challenge.device_code)
            .unwrap();
        let token = manager.pair(&pin.pin, &client_id).expect("pair client");

        let session_id = manager
            .start_session(StartSessionRequest {
                command: "sh".to_string(),
                args: vec![
                    "-c".to_string(),
                    "printf '0123456789abcdef'; sleep 30".to_string(),
                ],
                cwd: None,
                size: SessionSize::default(),
            })
            .expect("start session");

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let snap = manager.snapshot_session(session_id.clone()).unwrap();
            if snap.bytes_logged >= 16 {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for session output"
            );
            std::thread::sleep(Duration::from_millis(20));
        }

        // 1. Missing auth returns 401 Unauthorized.
        let unauth_req = Request::builder()
            .method("GET")
            .uri(format!("/api/sessions/{session_id}/history?window_bytes=6"))
            .body(Full::new(Bytes::new()))
            .unwrap();
        let unauth_res = serve_http(unauth_req, cache.clone(), manager.clone())
            .await
            .unwrap();
        assert_eq!(unauth_res.status(), StatusCode::UNAUTHORIZED);

        // 2. Lease probe attach (1024) skips visible_rows, styled_rows, and raw_output.
        let probe_attach = manager
            .attach_session(AttachSessionRequest {
                session_id: session_id.clone(),
                client_id: client_id.clone(),
                mode: AttachMode::Observer,
                history_bytes: Some(LEASE_PROBE_HISTORY_BYTES),
            })
            .expect("metadata probe attach");
        assert!(probe_attach.snapshot.visible_rows.is_empty());
        assert!(probe_attach.snapshot.styled_rows.is_empty());
        assert!(probe_attach.snapshot.raw_output.is_empty());
        assert_eq!(probe_attach.snapshot.raw_output_start, 16);

        // 3. Tail window mode returns the trailing 6 bytes ("abcdef").
        let tail_req = Request::builder()
            .method("GET")
            .uri(format!("/api/sessions/{session_id}/history?window_bytes=6"))
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header("x-triage-client-id", client_id.as_str())
            .body(Full::new(Bytes::new()))
            .unwrap();
        let tail_res = serve_http(tail_req, cache.clone(), manager.clone())
            .await
            .unwrap();
        assert_eq!(tail_res.status(), StatusCode::OK);
        let tail_bytes = tail_res.into_body().collect().await.unwrap().to_bytes();
        let (tail_meta, tail_prefix, tail_raw) = decode_test_frame(&tail_bytes);
        assert!(tail_prefix.is_empty());
        assert_eq!(tail_raw, b"abcdef");
        assert_eq!(tail_meta["raw_output_start"].as_u64(), Some(10));
        assert_eq!(tail_meta["raw_output_end"].as_u64(), Some(16));
        assert_eq!(tail_meta["raw_output_truncated"].as_bool(), Some(false));

        // 4. Forward delta mode when unchanged returns 0 bytes at raw_output_start == 16.
        let idle_delta_req = Request::builder()
            .method("GET")
            .uri(format!(
                "/api/sessions/{session_id}/history?window_bytes=64&after_byte=16&after_seq=1"
            ))
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header("x-triage-client-id", client_id.as_str())
            .body(Full::new(Bytes::new()))
            .unwrap();
        let idle_delta_res = serve_http(idle_delta_req, cache.clone(), manager.clone())
            .await
            .unwrap();
        assert_eq!(idle_delta_res.status(), StatusCode::OK);
        let idle_delta_bytes = idle_delta_res
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes();
        let (idle_meta, _, idle_raw) = decode_test_frame(&idle_delta_bytes);
        assert!(idle_raw.is_empty());
        assert_eq!(idle_meta["raw_output_start"].as_u64(), Some(16));
        assert_eq!(idle_meta["raw_output_end"].as_u64(), Some(16));
        assert_eq!(idle_meta["raw_output_truncated"].as_bool(), Some(false));

        // 5. Forward delta mode when behind returns only the missing slice [12..16] ("cdef").
        let slice_delta_req = Request::builder()
            .method("GET")
            .uri(format!(
                "/api/sessions/{session_id}/history?window_bytes=64&after_byte=12&after_seq=1"
            ))
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header("x-triage-client-id", client_id.as_str())
            .body(Full::new(Bytes::new()))
            .unwrap();
        let slice_delta_res = serve_http(slice_delta_req, cache.clone(), manager.clone())
            .await
            .unwrap();
        let slice_delta_bytes = slice_delta_res
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes();
        let (slice_meta, _, slice_raw) = decode_test_frame(&slice_delta_bytes);
        assert_eq!(slice_raw, b"cdef");
        assert_eq!(slice_meta["raw_output_start"].as_u64(), Some(12));
        assert_eq!(slice_meta["raw_output_end"].as_u64(), Some(16));
        assert_eq!(slice_meta["raw_output_truncated"].as_bool(), Some(false));

        // 6. Backward page mode returns only the older slice [4..10] ("456789") when holding [10..16]
        //    with window_bytes=12.
        let back_req = Request::builder()
            .method("GET")
            .uri(format!(
                "/api/sessions/{session_id}/history?window_bytes=12&before_byte=10&after_byte=16&after_seq=1"
            ))
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header("x-triage-client-id", client_id.as_str())
            .body(Full::new(Bytes::new()))
            .unwrap();
        let back_res = serve_http(back_req, cache.clone(), manager.clone())
            .await
            .unwrap();
        let back_bytes = back_res.into_body().collect().await.unwrap().to_bytes();
        let (back_meta, _, back_raw) = decode_test_frame(&back_bytes);
        assert_eq!(back_raw, b"456789");
        assert_eq!(back_meta["raw_output_start"].as_u64(), Some(4));
        assert_eq!(back_meta["raw_output_end"].as_u64(), Some(10));
        assert_eq!(back_meta["raw_output_truncated"].as_bool(), Some(true));

        let _ = manager.shutdown_session(session_id);
        let _ = std::fs::remove_dir_all(&log_dir);
    }
}
