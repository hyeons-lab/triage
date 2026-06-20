# 000080-01 — Read-only TUI update banner

## Thinking

The daemon already knows when a newer release exists (#91): a background
`git ls-remote` poll stores an `UpdateStatus`, surfaced as `ServerUpdateInfo`
(`server_version`, `update_available`, `latest_version`) via the defaulted
`SessionApi::server_update_info`, which `SessionManager` overrides.

The plan put the TUI banner on the WS `Hello` path, but the TUI is an IPC
client, not a WS client. The IPC transport (`triaged::ipc`) is a stateless
newline-JSON request/response over a Unix socket / Windows named pipe with no
server push. So the TUI can't observe the `HelloResult` fields or the
`UpdateAvailable` broadcast — those are for the Flutter/web clients (PR 5).

The minimal, correct bridge is a new IPC request that returns the daemon's
`ServerUpdateInfo`, mirroring the existing `ReloadClientAssets` non-session
control request. That keeps `SessionManager::server_update_info` as the single
source of truth for both transports. The TUI fetches at startup and on a slow
timer, stores the result, and renders a one-line banner when an update exists.

## Plan

1. **`ServerUpdateInfo` is serializable** (`crates/triage-core/src/session.rs`):
   add `Serialize, Deserialize` so it can cross the IPC wire.
2. **IPC protocol** (`crates/triaged/src/ipc.rs`):
   - `WireRequest::ServerUpdateInfo`, `WireSuccess::ServerUpdateInfo(ServerUpdateInfo)`.
   - `handle_request` arm → `Ok(WireSuccess::ServerUpdateInfo(manager.server_update_info()))`.
   - `impl SessionApi for IpcClient` overrides `server_update_info()` to
     round-trip the request, returning the "this build / no update" default on
     any IPC error (so the banner just stays hidden).
   - A test that the round-trip returns the manager's value through the IPC seam.
3. **TUI state** (`crates/triage/src/lib.rs`):
   - Store `update: ServerUpdateInfo` on `LocalSessionApp`.
   - Fetch it once in `start_with_manager` (after the manager is live).
   - `refresh_update_status(&mut self) -> bool` (returns whether it changed) and
     read accessors (`update_available`, `latest_version`, `server_version`).
4. **Render + refresh** (`crates/triage/src/main.rs`):
   - When `app.update_available()`, prepend a `Length(1)` banner row above the
     content area; shift the terminal/status rows down accordingly.
   - `draw_update_banner` renders a single styled line:
     `⬆ Update available: Triage <latest> (you have <current>) — github.com/hyeons-lab/triage/releases`.
   - In the main loop, every ~60s call `app.refresh_update_status()` and set
     `needs_draw` when it changed.
5. **Validate**: `cargo fmt`, `cargo clippy --workspace --all-targets -D warnings`,
   `cargo test` for triage-core / triaged / triage. Manually reason about the
   embedded-mode path (no poller → default → no banner).

## Out of scope (later PRs)

- The `U` update action and dismiss key (PR 4).
- Flutter/web banner (PR 5), which uses the `HelloResult` fields directly.
