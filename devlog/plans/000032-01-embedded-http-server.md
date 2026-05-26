# Plan — Embedded HTTP Server with Dynamic Client Upgrades

## Thinking
To serve the Triage Flutter client web files directly from the `triaged` daemon, we must implement a performant, multiplexed web server that sits on the same TCP port as Triage's WebSocket server. We will use **Hyper v1.x** with `hyper-util` and `http-body-util` for a robust, production-grade implementation.
To support zero-downtime upgrades of the client assets independent of the daemon:
1. At compilation time, we will check if the compiled Flutter web files exist in `flutter/triage_client/build/web`.
2. If they do, we will embed them using `rust-embed`.
3. If they don't, we will fall back to a beautifully styled fallback HTML page so developers can compile cleanly without build errors.
4. At runtime, the daemon will check an override directory (e.g. `~/.local/share/triage/web` or a user-configured path). 
5. To be highly performant, all assets (both overridden from disk and embedded) will be cached in an in-memory `RwLock<HashMap<String, CachedFile>>`.
6. We will add a new IPC command `ReloadClientAssets` so that when a user runs `triage client reload` or `triage client upgrade`, Triage re-reads the override directory and clears its in-memory cache instantly with zero restart downtime.
7. WebSockets will be natively multiplexed on the same port by handling HTTP standard upgrade handshakes in Hyper, then passing the upgraded stream to `tokio-tungstenite`.

## Plan
1. **Add Dependencies**:
   Update `crates/triaged/Cargo.toml` to add `hyper = { version = "1", features = ["server", "http1"] }`, `hyper-util = { version = "0.1", features = ["server-auto", "tokio"] }`, `http-body-util = "0.1"`, and `rust-embed` with compression enabled.
2. **Add Configuration**:
   Update `crates/triage-core/src/config.rs` to expose `web_assets_path: Option<String>` in `RemoteConfig` and implement validation.
3. **Build Guard & Web Fallback**:
   - Create `crates/triaged/build.rs` to output a `cargo:rustc-cfg=embed_real_client` configuration if the built client is found.
   - Create `crates/triaged/web_fallback/index.html` with basic instructions.
4. **Implement HTTP Server & Cache**:
   - Implement `crates/triaged/src/http.rs` to define the Hyper service routing, directory lookup, caching headers (ETag, Content-Length, Cache-Control), and SPA routing fallback.
   - Implement WebSocket extraction via `hyper::upgrade::on` and standard `tokio-tungstenite` wrapping.
5. **Integrate Server**:
   - Update `crates/triaged/src/ws.rs` and `crates/triaged/src/main.rs` to start the Hyper server.
6. **Implement IPC Reloading**:
   - Add the `ReloadClientAssets` request type in `crates/triaged/src/ipc.rs` and clear the cache upon receipt.
7. **Implement CLI Commands**:
   - Add `triage client reload` and `triage client upgrade` in `crates/triage/src/main.rs` to allow control.
8. **Testing and Verification**:
   - Run standard cargo workspace checks, formatting, and unit tests to ensure compatibility and correctness.
