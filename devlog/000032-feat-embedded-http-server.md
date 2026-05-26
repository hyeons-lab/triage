# Devlog — feat/embedded-http-server

## Agent
- **Name**: Antigravity (Gemini 3.5 Flash)
- **Role**: AI Software Engineer Pair

## Intent
Implement an embedded HTTP server using Hyper v1.x in the Triage daemon (`triaged`) to serve the Flutter client web interface natively. 
Support dynamic user upgrades of the client files via a local override directory (`~/.local/share/triage/web/`) and an in-memory asset cache with on-the-fly IPC reloading (`ReloadClientAssets`), while completely preserving the zero-downtime Unix process socket handover.

## Progress
- [x] Initialize branch devlog and plan.
- [x] Add `rust-embed`, `hyper`, `hyper-util`, `http-body-util`, and `http` to `crates/triaged/Cargo.toml`.
- [x] Add configuration validation for `web_assets_path` in `triage-core`.
- [x] Create compilation guard script `crates/triaged/build.rs` and fallback page `crates/triaged/web_fallback/index.html`.
- [x] Implement `WebAssetCache` and Hyper static asset router in `crates/triaged/src/http.rs`.
- [x] Implement dynamic Gzip HTTP asset compression using `flate2` for enhanced performance.
- [x] Implement native WebSocket connection upgrading using `hyper::upgrade::on` and `tokio-tungstenite`.
- [x] Update `crates/triaged/src/ws.rs` and `crates/triaged/src/main.rs` to launch the multiplexed server.
- [x] Add `ReloadClientAssets` IPC command to `crates/triaged/src/ipc.rs`.
- [x] Add `triage client reload` and `triage client upgrade` CLI subcommands in `crates/triage/src/main.rs`.
- [x] Verify functionality via automated tests, clippy lints, and cargo workspace checks.

## Decisions
- Adopted Option 2 (Hyper v1.x + http-body-util) to ensure maximum protocol correctness, concurrency safety, and a highly optimized dependency footprint for the terminal daemon.
- Implemented dynamically negotiated dynamic Gzip HTTP asset compression using the `flate2` crate for files exceeding 512 bytes with compressible mime-types.

## Next Steps
- Commit the amended changes to git.
- Draft and create the pull request.

## Commits
- HEAD — feat(web): implement embedded HTTP server with dynamic override upgrades and asset compression
