use std::collections::HashMap;
use std::convert::Infallible;
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

pub fn default_override_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .ok()?;
    Some(PathBuf::from(home).join(".local/share/triage/web"))
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
    allow_pairing_approval: bool,
) -> Result<Response<Full<Bytes>>, Infallible>
where
    B: hyper::body::Body + Send + 'static,
{
    let method = req.method();
    let path = req.uri().path();

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

    if path == "/pair" || path == "/pair/" {
        if !allow_pairing_approval {
            let mut res = Response::new(Full::new(Bytes::from("Not Found")));
            *res.status_mut() = StatusCode::NOT_FOUND;
            return Ok(res);
        }
        return Ok(pairing_page_response(req.uri().query(), manager));
    }

    // 2. Resolve requested clean relative asset path
    let mut clean_path = path.trim_start_matches('/');
    if clean_path.is_empty() {
        clean_path = "index.html";
    }

    if clean_path == "flutter_service_worker.js" {
        return Ok(stale_service_worker_response());
    }

    // 3. Retrieve from cache with fallback to index.html (SPA routing)
    let (file, served_path) = match cache.get(clean_path) {
        Some(file) => (file, clean_path),
        None => match cache.get("index.html") {
            Some(file) => (file, "index.html"),
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
        header::CONTENT_TYPE,
        HeaderValue::from_static(file.content_type),
    );
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(content.len()));
    headers.insert(header::ETAG, HeaderValue::from_str(&file.etag).unwrap());

    if is_gzipped {
        headers.insert(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));
    }

    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache, no-store, must-revalidate"),
    );
    if should_clear_site_cache(served_path) {
        headers.insert("clear-site-data", HeaderValue::from_static("\"cache\""));
    }

    Ok(res)
}

const STALE_SERVICE_WORKER_CLEANUP_JS: &str = r#"self.addEventListener('install', function(event) {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', function(event) {
  event.waitUntil(
    caches.keys()
      .then(function(keys) {
        return Promise.all(keys.map(function(key) {
          return caches.delete(key);
        }));
      })
      .then(function() {
        return self.registration.unregister();
      })
  );
});
"#;

fn stale_service_worker_response() -> Response<Full<Bytes>> {
    let body = Bytes::from_static(STALE_SERVICE_WORKER_CLEANUP_JS.as_bytes());
    let mut res = Response::new(Full::new(body.clone()));
    *res.status_mut() = StatusCode::OK;
    let headers = res.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/javascript; charset=utf-8"),
    );
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(body.len()));
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache, no-store, must-revalidate"),
    );
    headers.insert("clear-site-data", HeaderValue::from_static("\"cache\""));
    res
}

fn should_clear_site_cache(path: &str) -> bool {
    matches!(
        path,
        "index.html" | "flutter_bootstrap.js" | "flutter_service_worker.js"
    )
}

fn pairing_page_response(
    query: Option<&str>,
    manager: Arc<crate::session::SessionManager>,
) -> Response<Full<Bytes>> {
    let device_code = query.and_then(|query| query_param(query, "device_code"));
    let (status, body) = match device_code {
        Some(device_code) if !device_code.trim().is_empty() => {
            match manager.approve_pairing_device_code(&device_code) {
                Ok(pin) => (
                    StatusCode::OK,
                    render_pairing_pin_page(&pin.pin, pin.expires_at),
                ),
                Err(error) => (
                    StatusCode::BAD_REQUEST,
                    render_pairing_error_page(&error.to_string()),
                ),
            }
        }
        _ => (StatusCode::OK, render_pairing_form_page(None)),
    };

    let body = Bytes::from(body);
    let mut res = Response::new(Full::new(body.clone()));
    *res.status_mut() = status;
    let headers = res.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(body.len()));
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache, no-store, must-revalidate"),
    );
    res
}

fn query_param(query: &str, name: &str) -> Option<String> {
    query.split('&').find_map(|part| {
        let mut pieces = part.splitn(2, '=');
        let key = pieces.next()?;
        let value = pieces.next().unwrap_or_default();
        if key == name {
            Some(percent_decode_query_value(value))
        } else {
            None
        }
    })
}

fn percent_decode_query_value(value: &str) -> String {
    let mut output = Vec::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => {
                output.push(b' ');
                index += 1;
            }
            b'%' if index + 2 < bytes.len() => {
                if let (Some(high), Some(low)) =
                    (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
                {
                    output.push((high << 4) | low);
                    index += 3;
                } else {
                    output.push(bytes[index]);
                    index += 1;
                }
            }
            byte => {
                output.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn render_pairing_form_page(error: Option<&str>) -> String {
    let error_html = error.map_or_else(String::new, |message| {
        format!("<p class=\"error\">{}</p>", html_escape(message))
    });
    format!(
        "{}{}{}{}",
        pairing_page_prefix("Pair Triage Device"),
        error_html,
        r#"
      <p>Enter the device code shown by the Triage client to create a pairing PIN for that device.</p>
      <form method="get" action="/pair">
        <label for="device_code">Device code</label>
        <input id="device_code" name="device_code" autocomplete="one-time-code" autofocus required />
        <button type="submit">Get PIN</button>
      </form>
"#,
        pairing_page_suffix()
    )
}

fn render_pairing_pin_page(pin: &str, expires_at: u64) -> String {
    let pin = html_escape(pin);
    format!(
        r#"{}
      <p>Enter this PIN in the Triage client that showed the device code.</p>
      <div class="pin">{}</div>
      <p class="muted">This PIN expires at Unix time {}.</p>
      <a href="/pair">Pair another device</a>
{}"#,
        pairing_page_prefix("Pairing PIN"),
        pin,
        expires_at,
        pairing_page_suffix()
    )
}

fn render_pairing_error_page(message: &str) -> String {
    render_pairing_form_page(Some(message))
}

fn pairing_page_prefix(title: &str) -> String {
    let title = html_escape(title);
    format!(
        r#"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{}</title>
  <style>
    :root {{ color-scheme: dark; font-family: Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    body {{ margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0f1416; color: #edf7f6; }}
    main {{ width: min(92vw, 440px); padding: 28px; border: 1px solid #2a3437; border-radius: 8px; background: #161b1d; }}
    h1 {{ margin: 0 0 16px; font-size: 24px; }}
    p {{ color: #a5b1b4; line-height: 1.45; }}
    label {{ display: block; margin: 20px 0 8px; color: #cdd7d6; }}
    input {{ box-sizing: border-box; width: 100%; padding: 13px 14px; border: 1px solid #344145; border-radius: 6px; background: #101517; color: #edf7f6; font-size: 20px; letter-spacing: 4px; text-transform: uppercase; }}
    button {{ margin-top: 16px; width: 100%; padding: 12px 14px; border: 0; border-radius: 6px; background: #2b6f6f; color: #fff; font-weight: 700; cursor: pointer; }}
    a {{ color: #7fd1c7; }}
    .pin {{ margin: 20px 0; padding: 18px; border: 1px solid #344145; border-radius: 8px; background: #101517; color: #7fd1c7; font-size: 34px; font-weight: 800; letter-spacing: 8px; text-align: center; }}
    .muted {{ font-size: 13px; }}
    .error {{ color: #ff8a8a; }}
  </style>
</head>
<body>
  <main>
    <h1>{}</h1>
"#,
        title, title
    )
}

fn pairing_page_suffix() -> &'static str {
    "  </main>\n</body>\n</html>\n"
}

fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
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

    // Subprotocol negotiation per RFC 6455
    let mut selected_format = triage_transport_ws::ProtocolFormat::Json;
    let mut selected_proto_header = None;

    if let Some(protocol_header) = req
        .headers()
        .get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok())
    {
        for token in protocol_header.split(',') {
            let trimmed = token.trim();
            if trimmed == "triage-flatbuffers" {
                selected_format = triage_transport_ws::ProtocolFormat::Flatbuffers;
                selected_proto_header = Some(HeaderValue::from_static("triage-flatbuffers"));
                break;
            } else if trimmed == "triage-json" {
                selected_format = triage_transport_ws::ProtocolFormat::Json;
                selected_proto_header = Some(HeaderValue::from_static("triage-json"));
                break;
            }
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
                    crate::ws::handle_upgraded_ws(manager, ws_stream, selected_format).await
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
