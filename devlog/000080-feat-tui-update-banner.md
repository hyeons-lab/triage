# 000080 — feat/tui-update-banner

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/tui-update-banner

## Intent

PR 3 of the self-update epic: a **read-only** "update available" banner in the
`triage` TUI. When the daemon's background check (shipped in #91) has seen a
newer stable release, the TUI shows a one-line banner with the current/latest
versions and where to get it. No update *action* yet — that's PR 4.

## Decisions

- 2026-06-19T17:36-0700 **Deviation from the plan: the TUI reads update status
  over IPC, not the WebSocket `Hello`.** The plan (Phase 4) assumed the TUI would
  read `update_available` / `latest_version` from the `HelloResult` it receives
  on connect. But the `triage` TUI does not use the WebSocket transport — it
  talks to the daemon over the local IPC socket (`triaged::ipc::IpcClient`,
  stateless newline-JSON request/response), and never performs a WS `Hello`
  handshake nor receives connection-level pushes. The `HelloResult` fields and
  the `UpdateAvailable` push from #91 serve the *Flutter/web* clients (PR 5).
  For the TUI, the update status is fetched with a new IPC request that returns
  the daemon's `ServerUpdateInfo` (the same value the WS `Hello` embeds), so both
  transports surface one source of truth (`SessionManager::server_update_info`).
- 2026-06-19T17:36-0700 New `WireRequest::ServerUpdateInfo` / `WireSuccess::ServerUpdateInfo`,
  mirroring the existing non-session `ReloadClientAssets` control request. The
  daemon handler calls `manager.server_update_info()`; `IpcClient` overrides the
  defaulted `SessionApi::server_update_info` to round-trip it, falling back to
  the "this build, nothing newer" default on any IPC error (the banner simply
  never shows).
- 2026-06-19T17:36-0700 Banner is **non-dismissible** for the read-only phase. A
  clean dismiss key is awkward here — the TUI forwards unmatched keystrokes to
  the focused terminal, so a bare letter can't be a UI hotkey without stealing
  it from the shell. The banner is a single unobtrusive top row, shown only when
  an update is available; the dismiss/"press U to update" affordance arrives with
  the actual update action in PR 4.
- 2026-06-19T17:36-0700 The TUI re-fetches update status on a slow timer (every
  ~60s) in addition to once at startup. The daemon's first poll completes a beat
  after it starts, so a startup-only fetch would usually miss it; a cheap
  periodic IPC round-trip lets the banner appear without restarting the TUI.
- 2026-06-19T17:36-0700 Naturally gated by config: when `[update] check = false`
  the daemon never polls, so `update_available` stays false and the banner never
  shows — no extra TUI-side config plumbing.
- 2026-06-21T08:47-0300 **PR #92 review (Copilot): moved the refresh off the UI
  thread.** The original design re-queried `manager.server_update_info()` directly
  from the main loop, but that's a blocking IPC round-trip — on Windows the
  pipe-busy connect can wait up to 5s with no read timeout, freezing the UI even
  when idle. Now a dedicated `triage-update-poller` thread owns its own stateless
  `IpcClient` (each round-trip reconnects, so a second client is safe) and pushes
  status over an `mpsc` channel; `refresh_update_status` drains it with `try_recv`
  and never blocks. The thread exits when the receiver drops. Supersedes the
  "cheap periodic IPC round-trip on the main loop" decision above. Poller cadence
  stays 30s (`UPDATE_POLL_INTERVAL`); the UI drains every loop iteration since it's
  now free.
- 2026-06-21T08:47-0300 **PR #92 review (Copilot): no per-frame `Vec` in `draw()`.**
  The banner/no-banner layout used `constraints(if … { vec![…] } else { vec![…] })`,
  allocating a `Vec` every redraw. Split into two branches each passing a
  fixed-size constraint array, so the hot path no longer heap-allocates.

## Plan

See `devlog/plans/000080-01-tui-update-banner.md`.

## Next Steps

- PR 4: Phase 0b signing + Phase 3 health-gated handover self-update, plus the
  TUI `U` action and the dismiss affordance.
- PR 5: Flutter banner + browser-download (consumes the `HelloResult` fields /
  `UpdateAvailable` push directly).

## Commits

- 3ddf6f0 — feat(triage): read-only update-available banner in the TUI
- HEAD — fix(triage): poll update status off the UI thread; drop per-frame layout alloc
