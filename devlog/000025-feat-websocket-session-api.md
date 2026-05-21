# feat/websocket-session-api

## Agent

- Codex, 2026-05-20T19:20-0700

## Intent

- Add the first narrow WebSocket transport for remote Argus clients.
- Keep the transport bound to the existing session API so remote clients do not create new session semantics.

## Decisions

- Start with JSON over WebSocket and no authentication or TLS in this branch.
- Cover the browser-critical session path first: listing, attaching, event subscription, writing input, resizing, snapshots, styled rows, and lease operations.
- Keep terminal rendering and Flutter client work out of scope for this transport slice.
- Rename the empty `argus-web` crate to `argus-transport-ws` before implementation because the transport is shared by browser, mobile, and optional desktop clients.

## What Changed

- Renamed the empty `argus-web` crate to `argus-transport-ws`.
- Added a JSON request/response/event protocol layer for remote session clients.
- Added per-connection subscription tracking with nonblocking event draining and closed-subscription notifications.
- Covered the protocol with focused fake-API tests for hello, listing, input writes, subscription events, invalid JSON, and attach request encoding.

## Progress

- 2026-05-20T19:20-0700 — Created `feat/websocket-session-api` worktree from `origin/main`, unset upstream, and started the Phase 6 transport slice.
- 2026-05-20T19:26-0700 — Renamed the transport crate and implemented the first JSON protocol handler against `SessionApi`. Validated the touched crate with `cargo test -p argus-transport-ws`.
- 2026-05-20T19:29-0700 — Completed branch validation with `cargo fmt --all -- --check`, `cargo check --workspace`, `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`, and `cargo test --workspace`.

## Commits

- HEAD — feat: add websocket session api

## Next Steps

- Define a small request/response/event envelope for WebSocket clients.
- Implement the transport adapter in `argus-transport-ws` against `SessionApi`.
- Add focused tests with fake session APIs before wiring daemon runtime entrypoints.
