# Devlog 000187: feat/mcp-templates-and-remote

**Agent:** Codex @ triage branch `feat/mcp-templates-and-remote`
**Agent (2026-11-15T15:23-0800):** Gemini @ triage branch `feat/mcp-templates-and-remote` (resumed verification and commit)

## Intent

Add reusable Markdown worker role templates and configured cross-host daemon delegation to `triage-mcp` and `triaged`:

1. Load role templates from `$TRIAGE_TEMPLATES_DIR`, `$XDG_CONFIG_HOME/triage/templates/<name>.md`, or `~/.config/triage/templates/<name>.md`, expose `list_templates`, and support `template` / `task` arguments on `start_session`.
2. Add an authenticated HTTP `/rpc` endpoint in `triaged` reusing the existing `WireRequest`/`WireResponse` protocol and bearer-token pairing verification, plus configured remote host routing in `triage-mcp` (`hosts.toml`, `list_hosts`, and optional `host` parameter across session tools).

## Progress

- [x] Create stacked worktree `feat/mcp-templates-and-remote` on `feat/mcp-worker-lifecycle`
- [x] Write branch devlog and plan (`devlog/plans/000187-01-role-templates-and-remote-hosts.md`)
- [x] Add `triaged` `/rpc` endpoint over existing HTTP listener + bearer-token verification
- [x] Add Markdown role template loader, `list_templates`, and `template`/`task` resolution in `triage-mcp`
- [x] Add remote host registry (`hosts.toml`), `list_hosts`, HTTP RPC `SessionApi` client, and optional `host` routing across `triage-mcp` tools
- [x] Add tests and verify `cargo fmt`, `clippy`, and `cargo test --workspace`

## What Changed

- `2026-11-15T15:23-0800 crates/triaged/src/ipc.rs`: Extracted shared `WireRoundTrip` + `impl_wire_session_api_methods!()` for `IpcClient` and `WireRpcClient<T>`, added `WireRpcTransport`, `REMOTE_RPC_PATH` (`"/rpc"`), `handle_session_rpc_request`, and `handle_remote_rpc_json` while rejecting control-only and streaming wire variants over HTTP.
- `2026-11-15T15:23-0800 crates/triaged/src/http.rs`: Routed `POST /rpc` to `handle_rpc_http` (2 MiB capped body, `spawn_blocking` RPC execution), extracted shared `authorize_pairing_headers` used by both `/rpc` and session history HTTP routes, and added `rpc_http_endpoint_enforces_auth_and_round_trips_wire_requests`.
- `2026-11-15T15:23-0800 crates/triage-mcp/Cargo.toml`, `crates/triage-mcp/src/templates.rs`, `crates/triage-mcp/src/hosts.rs`, `crates/triage-mcp/src/main.rs`: Added Markdown role template parsing and prompt interpolation (`list_templates`, `start_session` `template`/`task`), TOML host registry and `WireRpcClient`-backed HTTP transport (`list_hosts`, optional `host` routing across all 10 session tools), and unit tests for templates, redacted host listings, and host routing.

## Decisions

- `2026-11-15T15:23-0800 Decision`: Reuse `WireRequest`/`WireResponse` over `POST /rpc` with pairing bearer auth instead of duplicating a REST schema; rejects handover/streaming/control variants (`SubscribeSessionEvents`, `Handover`, `HandoverV2`, `HandoverProbe`, `ReloadClientAssets`, `DisableShutdownRescue`, `ApprovePairingDeviceCode`) at the HTTP boundary.
- `2026-11-15T15:23-0800 Decision`: Validate `start_session` parameters (such as explicit `null` `cwd` or explicit blank `command`) before merging template defaults so invalid caller overrides never silently fall back to template values.

## Commits

- `HEAD`: `feat(mcp): add role templates and remote host delegation`
