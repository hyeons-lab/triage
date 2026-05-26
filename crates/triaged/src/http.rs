use std::collections::HashMap;
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use ::http::HeaderValue;
use bytes::Bytes;
use http_body_util::Full;
use hyper::{Request, Response, StatusCode, header};
use rust_embed::RustEmbed;

#[cfg(embed_real_client)]
#[derive(RustEmbed)]
#[folder = "../../flutter/triage_client/build/web/"]
struct WebAsset;

#[cfg(not(embed_real_client))]
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
        {
            let cache = self.cache.read().unwrap();
            if let Some(file) = cache.get(path) {
                return Some(Arc::clone(file));
            }
        }

        let file = self.load_file(path)?;
        let arc_file = Arc::new(file);

        let mut cache = self.cache.write().unwrap();
        cache.insert(path.to_string(), Arc::clone(&arc_file));
        Some(arc_file)
    }

    fn load_file(&self, path: &str) -> Option<CachedFile> {
        // 1. Try override directory
        if let Some(ref dir) = self.override_dir {
            let safe_path = path.replace("..", "");
            let full_path = dir.join(&safe_path);
            let content_opt = if full_path.is_file() {
                std::fs::read(&full_path).ok()
            } else {
                None
            };
            if let Some(content) = content_opt {
                let content_bytes = Bytes::from(content);
                let etag = format!("\"{}\"", sha2_hash(&content_bytes));
                let compressed_content = if should_compress(path, content_bytes.len()) {
                    compress_gzip(&content_bytes).ok()
                } else {
                    None
                };
                return Some(CachedFile {
                    content: content_bytes,
                    compressed_content,
                    content_type: mime_type_for_path(path),
                    etag,
                });
            }
        }

        // 2. Try embedded assets
        if let Some(embedded) = WebAsset::get(path) {
            let content_bytes = Bytes::from(embedded.data.into_owned());
            let etag = format!("\"{}\"", sha2_hash(&content_bytes));
            let compressed_content = if should_compress(path, content_bytes.len()) {
                compress_gzip(&content_bytes).ok()
            } else {
                None
            };
            return Some(CachedFile {
                content: content_bytes,
                compressed_content,
                content_type: mime_type_for_path(path),
                etag,
            });
        }

        None
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

    // 2. Resolve requested clean relative asset path
    let mut clean_path = path.trim_start_matches('/');
    if clean_path.is_empty() {
        clean_path = "index.html";
    }

    // 3. Retrieve from cache with fallback to index.html (SPA routing)
    let (file, is_fallback) = match cache.get(clean_path) {
        Some(file) => (file, false),
        None => match cache.get("index.html") {
            Some(file) => (file, true),
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

    if clean_path == "index.html" || is_fallback {
        headers.insert(
            header::CACHE_CONTROL,
            HeaderValue::from_static("no-cache, no-store, must-revalidate"),
        );
    } else {
        headers.insert(
            header::CACHE_CONTROL,
            HeaderValue::from_static("public, max-age=31536000"),
        );
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

    // Subprotocol negotiation
    let requested_protocols = req
        .headers()
        .get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    let mut selected_format = triage_transport_ws::ProtocolFormat::Json;
    let mut selected_proto_header = None;

    if requested_protocols.contains("triage-flatbuffers") {
        selected_format = triage_transport_ws::ProtocolFormat::Flatbuffers;
        selected_proto_header = Some(HeaderValue::from_static("triage-flatbuffers"));
    } else if requested_protocols.contains("triage-json") {
        selected_format = triage_transport_ws::ProtocolFormat::Json;
        selected_proto_header = Some(HeaderValue::from_static("triage-json"));
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
