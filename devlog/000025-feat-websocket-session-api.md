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
- Preserved request ids on valid-JSON protocol errors and split malformed JSON from invalid request payloads.
- Capped per-subscription event draining per call to avoid a large backlog monopolizing a transport tick.
- Updated TUI session context labels to prefer the repository root over linked worktree names and use single-character labels.
- Covered the protocol with focused fake-API tests for hello, listing, input writes, subscription events, invalid JSON, and attach request encoding.
- Restored historical daemon sessions from the TUI reconnect path before acquiring input leases so restarted daemon/TUI shells become interactive again.
- Added a dedicated TUI sidebar worktree row when a linked worktree differs from the repository root.
- Fixed review findings in session context reporting: submodule checkouts now report the checked-out submodule path instead of `.git/modules/...`, and selected sidebar overflow checks include the worktree row.

## Progress

- 2026-05-20T19:20-0700 — Created `feat/websocket-session-api` worktree from `origin/main`, unset upstream, and started the Phase 6 transport slice.
- 2026-05-20T19:26-0700 — Renamed the transport crate and implemented the first JSON protocol handler against `SessionApi`. Validated the touched crate with `cargo test -p argus-transport-ws`.
- 2026-05-20T19:29-0700 — Completed branch validation with `cargo fmt --all -- --check`, `cargo check --workspace`, `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`, and `cargo test --workspace`.
- 2026-05-20T19:39-0700 — Addressed PR review comments for invalid request classification, request-id preservation, and bounded subscription draining. Revalidated with `cargo fmt --all -- --check` and `cargo test -p argus-transport-ws`.
- 2026-05-20T19:46-0700 — Adjusted TUI sidebar repository/branch context display so linked worktrees show the real repository name, shortened labels to one character, and covered repository/worktree split detection.
- 2026-05-20T20:01-0700 — Fixed daemon-backed TUI reconnect for historical shell sessions. The TUI was attaching to persisted sessions as observers, receiving `exited` snapshots, then refusing input/lease activation. It now restores historical sessions with the current terminal size before subscribing to live events and acquiring the input lease. Validated with `cargo fmt --all -- --check`, `cargo test -p argus-tui`, and `cargo test -p argus-daemon restore`.
- 2026-05-20T20:12-0700 — Added a `w` sidebar row for linked worktree names so the session pane can show both the repository (`r argus`) and active worktree (`w websocket-session-api`) when they differ.
- 2026-05-20T20:26-0700 — Addressed review findings for submodule and worktree-row edge cases. `git_repository_root` now only treats `.git/worktrees/<name>` as a linked-worktree common-dir shape and otherwise falls back to `--show-toplevel`; sidebar overflow detection now checks the displayed worktree row as well as repo/cwd and branch rows.

## Commits

- 2abff85 — feat: add websocket session api
- 4922de6 — fix: address websocket transport review comments
- 6351f3e — fix: show repository name in session sidebar
- HEAD — fix: restore interactive resumed sessions

## Next Steps

- Define a small request/response/event envelope for WebSocket clients.
- Implement the transport adapter in `argus-transport-ws` against `SessionApi`.
- Add focused tests with fake session APIs before wiring daemon runtime entrypoints.
