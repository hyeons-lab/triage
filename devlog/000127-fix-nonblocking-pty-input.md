# 000127: Fix Nonblocking PTY Input & Web Bracketed Paste

**Agent:** Antigravity  
**Intent:** Unwedge triage daemon by making PTY input writing non-blocking via a dedicated writer thread and fire-and-forget IPC, and integrate bracketed paste handling into the Flutter web client terminal.

## What Changed

- Made `request_write_input` in `triaged::session` fire-and-forget: sends `ActorCommand::WriteInput` without blocking on actor round-trip, preventing stuck sessions from blocking the Tokio WebSocket server.
- Decoupled PTY writes in `triaged::session` onto a dedicated `session-actor-writer` thread so that large writes / stuck child stdin buffers never stall the `session-actor-worker` loop.
- Routed web paste events in `flutter/triage_client/lib/widgets/terminal_pane_web.dart` through `xterm.paste(text)` to ensure Mode 2004 bracketed paste sequences and line endings are preserved.

## Decisions

- **Dedicated PTY Writer Thread:** Placing the PTY `write_all` on a dedicated thread per active session guarantees the actor worker loop is never parked in kernel `write()`, keeping summarizer queries, resize, snapshots, and event fanout responsive at all times.
- **Fire-and-Forget `WriteInput`:** Aligning `WriteInput` with `broadcast_event` (send without waiting on roundtrip) eliminates cross-actor blocking in the daemon's WebSocket transport layer while preserving ordering across keystrokes.

## Commits

- HEAD — fix: make pty input nonblocking and support web bracketed paste

## Progress

- [x] Identified root cause of PTY write deadlock and web paste unbracketed multi-line flooding.
- [x] Created worktree `fix/nonblocking-pty-input`.
- [x] Updated `crates/triaged/src/session.rs`.
- [x] Updated `flutter/triage_client/lib/widgets/terminal_pane_web.dart`.
- [x] Validated tests with `cargo test` and `flutter test`.
