#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Arc;

    use bytes::Bytes;
    use http_body_util::Empty;
    use hyper::Request;
    use triage_core::session::ClientId;
    use triage_transport_ws::WebSocketAuthenticator;

    use crate::http::{WebAssetCache, mime_type_for_path, serve_http};
    use crate::session::{SessionManager, SessionManagerConfig};

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> std::io::Result<Self> {
            let num: u64 = rand::random();
            let path = std::env::temp_dir().join(format!("triage-http-test-{}", num));
            std::fs::create_dir_all(&path)?;
            Ok(Self { path })
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn test_mime_type_resolution() {
        assert_eq!(mime_type_for_path("index.html"), "text/html; charset=utf-8");
        assert_eq!(mime_type_for_path("style.css"), "text/css; charset=utf-8");
        assert_eq!(
            mime_type_for_path("main.js"),
            "application/javascript; charset=utf-8"
        );
        assert_eq!(
            mime_type_for_path("data.json"),
            "application/json; charset=utf-8"
        );
        assert_eq!(mime_type_for_path("image.png"), "image/png");
        assert_eq!(mime_type_for_path("file.wasm"), "application/wasm");
        assert_eq!(
            mime_type_for_path("unknown.txt"),
            "application/octet-stream"
        );
    }

    #[test]
    fn test_web_asset_cache_fallback_and_embedding() {
        let temp_dir = TempDir::new().unwrap();
        let cache = WebAssetCache::new(Some(temp_dir.path.clone()));

        // Since the override folder is empty, requesting a nonexistent file should fall back to embedded fallback index.html
        let nonexistent = cache.get("nonexistent.js");
        assert!(nonexistent.is_none());

        // Get index.html (which is embedded by default in web_fallback)
        let index = cache.get("index.html");
        assert!(index.is_some());
        let index_file = index.unwrap();
        assert_eq!(index_file.content_type, "text/html; charset=utf-8");
        assert!(!index_file.content.is_empty());

        let body_str = String::from_utf8_lossy(&index_file.content);
        assert!(
            body_str.contains("Triage Web Client")
                || body_str.contains("Triage Client")
                || body_str.contains("Flutter Client")
        );
    }

    #[test]
    fn test_web_asset_cache_override_updates_without_reload() {
        let temp_dir = TempDir::new().unwrap();
        let cache = WebAssetCache::new(Some(temp_dir.path.clone()));

        // Create override index.html
        let override_file = temp_dir.path.join("index.html");
        let custom_content = b"CUSTOM OVERRIDE INDEX";
        std::fs::write(&override_file, custom_content).unwrap();

        // 1. Fetch index.html -> should yield our custom override content!
        let index = cache.get("index.html").unwrap();
        assert_eq!(index.content.as_ref(), custom_content);

        // 2. Modify override file on disk
        let updated_content = b"UPDATED OVERRIDE INDEX";
        std::fs::write(&override_file, updated_content).unwrap();

        // 3. Fetch again -> should yield updated content without a manual reload.
        let index2 = cache.get("index.html").unwrap();
        assert_eq!(index2.content.as_ref(), updated_content);

        // 4. Trigger reload; override files still read current bytes.
        cache.reload();

        // 5. Fetch again -> should yield updated custom content.
        let index3 = cache.get("index.html").unwrap();
        assert_eq!(index3.content.as_ref(), updated_content);
    }

    #[tokio::test]
    async fn test_serve_http_routing_and_headers() {
        let temp_dir = TempDir::new().unwrap();
        let cache = Arc::new(WebAssetCache::new(Some(temp_dir.path.clone())));

        let config = SessionManagerConfig::new(temp_dir.path.clone());
        let manager = Arc::new(SessionManager::new(config));

        // Create a custom script to serve in the override directory
        let script_file = temp_dir.path.join("script.js");
        let content_bytes = b"console.log('hello Triage');";
        std::fs::write(&script_file, content_bytes).unwrap();

        // 1. Send GET /script.js
        let req = Request::builder()
            .method("GET")
            .uri("/script.js")
            .body(Empty::<Bytes>::new())
            .unwrap();

        let response = serve_http(req, Arc::clone(&cache), Arc::clone(&manager), true)
            .await
            .unwrap();

        assert_eq!(response.status(), hyper::StatusCode::OK);
        assert_eq!(
            response.headers().get(hyper::header::CONTENT_TYPE).unwrap(),
            "application/javascript; charset=utf-8"
        );
        assert_eq!(
            response
                .headers()
                .get(hyper::header::CACHE_CONTROL)
                .unwrap(),
            "no-cache, no-store, must-revalidate"
        );

        // Verify body content
        use http_body_util::BodyExt;
        let body_bytes = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body_bytes.as_ref(), content_bytes);
    }

    #[tokio::test]
    async fn test_serve_http_spa_fallback_routing() {
        let temp_dir = TempDir::new().unwrap();
        let cache = Arc::new(WebAssetCache::new(Some(temp_dir.path.clone())));

        let config = SessionManagerConfig::new(temp_dir.path.clone());
        let manager = Arc::new(SessionManager::new(config));

        // Send GET /some/nested/page (unknown asset)
        let req = Request::builder()
            .method("GET")
            .uri("/some/nested/page")
            .body(Empty::<Bytes>::new())
            .unwrap();

        let response = serve_http(req, Arc::clone(&cache), Arc::clone(&manager), true)
            .await
            .unwrap();

        // Should return 200 OK because of the SPA fallback (returns fallback index.html)
        assert_eq!(response.status(), hyper::StatusCode::OK);
        assert_eq!(
            response.headers().get(hyper::header::CONTENT_TYPE).unwrap(),
            "text/html; charset=utf-8"
        );
        assert_eq!(
            response
                .headers()
                .get(hyper::header::CACHE_CONTROL)
                .unwrap(),
            "no-cache, no-store, must-revalidate"
        );
        assert_eq!(
            response.headers().get("clear-site-data").unwrap(),
            "\"cache\""
        );
    }

    #[tokio::test]
    async fn test_serve_http_stale_service_worker_cleanup() {
        let temp_dir = TempDir::new().unwrap();
        let cache = Arc::new(WebAssetCache::new(Some(temp_dir.path.clone())));

        let config = SessionManagerConfig::new(temp_dir.path.clone());
        let manager = Arc::new(SessionManager::new(config));

        let req = Request::builder()
            .method("GET")
            .uri("/flutter_service_worker.js")
            .body(Empty::<Bytes>::new())
            .unwrap();

        let response = serve_http(req, Arc::clone(&cache), Arc::clone(&manager), true)
            .await
            .unwrap();

        assert_eq!(response.status(), hyper::StatusCode::OK);
        assert_eq!(
            response.headers().get(hyper::header::CONTENT_TYPE).unwrap(),
            "application/javascript; charset=utf-8"
        );
        assert_eq!(
            response
                .headers()
                .get(hyper::header::CACHE_CONTROL)
                .unwrap(),
            "no-cache, no-store, must-revalidate"
        );
        assert_eq!(
            response.headers().get("clear-site-data").unwrap(),
            "\"cache\""
        );

        use http_body_util::BodyExt;
        let body_bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body = String::from_utf8(body_bytes.to_vec()).expect("utf8 body");
        assert!(body.contains("registration.unregister"));
        assert!(body.contains("caches.delete"));
    }

    #[tokio::test]
    async fn test_serve_http_gzip_compression() {
        let temp_dir = TempDir::new().unwrap();
        let cache = Arc::new(WebAssetCache::new(Some(temp_dir.path.clone())));

        let config = SessionManagerConfig::new(temp_dir.path.clone());
        let manager = Arc::new(SessionManager::new(config));

        // Create a custom large script to serve in the override directory (needs to be > 512 bytes to trigger Gzip)
        let script_file = temp_dir.path.join("script.js");
        let content_string = "console.log('hello Triage compression');\n".repeat(20);
        let content_bytes = content_string.as_bytes();
        std::fs::write(&script_file, content_bytes).unwrap();

        // 1. Send GET /script.js WITH Accept-Encoding: gzip
        let req = Request::builder()
            .method("GET")
            .uri("/script.js")
            .header(hyper::header::ACCEPT_ENCODING, "gzip, deflate")
            .body(Empty::<Bytes>::new())
            .unwrap();

        let response = serve_http(req, Arc::clone(&cache), Arc::clone(&manager), true)
            .await
            .unwrap();

        assert_eq!(response.status(), hyper::StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get(hyper::header::CONTENT_ENCODING)
                .unwrap(),
            "gzip"
        );

        // Verify that the body is indeed compressed and smaller than original
        use http_body_util::BodyExt;
        let body_bytes = response.into_body().collect().await.unwrap().to_bytes();
        assert!(body_bytes.len() < content_bytes.len());

        // 2. Send GET /script.js WITHOUT Accept-Encoding: gzip
        let req_raw = Request::builder()
            .method("GET")
            .uri("/script.js")
            .body(Empty::<Bytes>::new())
            .unwrap();

        let response_raw = serve_http(req_raw, Arc::clone(&cache), Arc::clone(&manager), true)
            .await
            .unwrap();

        assert_eq!(response_raw.status(), hyper::StatusCode::OK);
        assert!(
            response_raw
                .headers()
                .get(hyper::header::CONTENT_ENCODING)
                .is_none()
        );

        let body_bytes_raw = response_raw.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body_bytes_raw.as_ref(), content_bytes);
    }

    #[tokio::test]
    async fn test_pair_page_issues_device_bound_pin() {
        let temp_dir = TempDir::new().unwrap();
        let cache = Arc::new(WebAssetCache::new(Some(temp_dir.path.clone())));
        let manager = Arc::new(SessionManager::new(SessionManagerConfig::new(
            temp_dir.path.clone(),
        )));
        let client_id = ClientId::new("browser-a").unwrap();
        let other_client_id = ClientId::new("browser-b").unwrap();
        let challenge = manager
            .request_pairing_challenge(&client_id)
            .expect("request pairing challenge");

        let req = Request::builder()
            .method("GET")
            .uri(format!("/pair?device_code={}", challenge.device_code))
            .body(Empty::<Bytes>::new())
            .unwrap();

        let response = serve_http(req, Arc::clone(&cache), Arc::clone(&manager), true)
            .await
            .unwrap();

        assert_eq!(response.status(), hyper::StatusCode::OK);

        use http_body_util::BodyExt;
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let body = String::from_utf8(body.to_vec()).expect("utf8 body");
        let pin = body
            .split("<div class=\"pin\">")
            .nth(1)
            .and_then(|rest| rest.split("</div>").next())
            .expect("pin in pairing page")
            .to_string();

        assert!(WebSocketAuthenticator::pair(manager.as_ref(), &pin, &other_client_id).is_err());
        WebSocketAuthenticator::pair(manager.as_ref(), &pin, &client_id)
            .expect("pin pairs intended client");
    }

    #[tokio::test]
    async fn test_pair_page_is_not_served_to_non_local_peers() {
        let temp_dir = TempDir::new().unwrap();
        let cache = Arc::new(WebAssetCache::new(Some(temp_dir.path.clone())));
        let manager = Arc::new(SessionManager::new(SessionManagerConfig::new(
            temp_dir.path.clone(),
        )));
        let client_id = ClientId::new("browser-a").unwrap();
        let challenge = manager
            .request_pairing_challenge(&client_id)
            .expect("request pairing challenge");

        let req = Request::builder()
            .method("GET")
            .uri(format!("/pair?device_code={}", challenge.device_code))
            .body(Empty::<Bytes>::new())
            .unwrap();

        let response = serve_http(req, Arc::clone(&cache), Arc::clone(&manager), false)
            .await
            .unwrap();

        assert_eq!(response.status(), hyper::StatusCode::NOT_FOUND);
    }
}
