# feat/mcp-stdio-session-tools

## Agent

- Codex, 2026-05-18T20:38-0700

## Intent

- Add the first local MCP stdio surface for Argus sessions.
- Keep the initial tool set read-only so agents can discover and inspect daemon-owned sessions before lease-gated input tools land.

## Decisions

- Bind MCP tools through the existing Unix socket `SessionApi` implementation instead of giving the MCP process direct session-manager ownership.
- Start with newline-delimited JSON-RPC stdio handling matching the MCP stdio transport, with no logging on stdout.
- Defer input/injection tools until a follow-up can make agent lease acquisition and approval behavior explicit.

## What Changed

- Added `argus-mcp` dependencies on the shared session types and daemon Unix socket client.
- Implemented a stdio JSON-RPC loop for `initialize`, `ping`, `tools/list`, and `tools/call`.
- Added read-only tools: `list_sessions`, `snapshot_session`, and `styled_rows`.
- Returned both text content and `structuredContent` for tool results so clients can display or parse the same response.
- Added unit coverage for tool listing, read-only tool calls, required argument validation, and notification suppression.
- Preserved explicit JSON-RPC `null` request IDs while continuing to suppress notifications with omitted IDs.
- Returned daemon/tool execution failures as MCP tool results with `isError: true` instead of JSON-RPC internal errors.

## Commits

- 07a2747 — feat: add MCP stdio session tools
- HEAD — fix: align MCP stdio error boundaries

## Progress

- 2026-05-18T20:38-0700 — Created `feat/mcp-stdio-session-tools` worktree from `origin/main`, unset upstream, and confirmed `crates/argus-mcp` is still a stub.
- 2026-05-18T20:45-0700 — Implemented the first read-only MCP stdio surface and validated it with `cargo fmt --all -- --check`, `/home/dberrios/.cargo/bin/cargo test -p argus-mcp`, `cargo check --workspace`, `cargo clippy --all-targets --all-features -- -D warnings`, and a real stdio `initialize` smoke request through `cargo run -q -p argus-mcp`.
- 2026-05-18T20:56-0700 — Addressed review feedback for MCP protocol boundaries: explicit `null` IDs now produce responses, omitted IDs remain notifications, and tool execution failures return displayable MCP tool errors. Validated with `cargo fmt --all` and `cargo test -p argus-mcp`.
- 2026-05-18T21:18-0700 — Replaced the manual `Default` implementation for JSON-RPC IDs with a derived default so clippy passes with warnings denied.

## Next Steps

- Add lease-aware write/input tools after the read-only surface is reviewed.
- Add a checked-in client configuration snippet once the final launch command is settled.
