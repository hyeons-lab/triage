# Triage

An attention-routing terminal supervisor: a long-running daemon (`triaged`), a Ratatui TUI (`triage`), a Flutter client (`triage_client`), and an MCP server (`triage-mcp`), all sharing one session API.

## Plan

Triage is daemon-first. The local TUI is the first product target; remote access comes after the daemon and local navigation model are solid.

Core architecture constraints:

- The daemon owns canonical session state: PTYs, terminal grid snapshots, scrollback sequence numbers, metadata, and status.
- Multiple clients can observe a session, but input goes through a one-writer lease model. A session has one active interactive controller at a time.
- Repo/worktree grouping is inferred from OS and git state, with durable session cwd separated from transient foreground process cwd.
- Local transports use local trust boundaries first. Remote network transports require authentication and encryption.
- Persistence restores metadata, logs, and UI state first. It does not promise resurrection of arbitrary foreground programs.

Implementation order:

1. Tooling: workspace, tracing, config parser, CI, and test harness.
2. Terminal engine acceptance: choose the VT engine with tests for resize, late attach, reconnect, alt-screen, mouse reporting, bracketed paste, scroll regions, replay, and log tee behavior.
3. Daemon session core: PTY spawning, session actors, canonical VT state, logs, attach modes, and input lease semantics.
4. Local API and IPC: one session API bound to in-process and owner-only Unix socket transports.
5. TUI client: repo/worktree sidebar, status pills, attention routing hotkeys, overview, notifications, and log search.
6. MCP server: local AI-agent integration over stdio first, using the same session API and input lease model.
7. Remote web client: WebSocket + TLS + bearer auth, QR pairing, browser attach/reconnect, and Tailscale documentation.
8. Native mobile and notifications: validate xterm.dart behavior before iOS/Android builds and push notification work.
9. Later optional features: approval gates, remote-agent gRPC + mTLS, and semantic event indexing.

## Status

Early development. Not yet usable.

## Running

The daemon (`triaged`) owns session state; clients (the `triage` TUI, the MCP
server, the Flutter client) attach to it. Start the daemon in the foreground
with `triaged`, or register it to start automatically at login:

```bash
triaged service install     # start now + run at every login
triaged service status
triaged service uninstall
```

`triaged` runs on **macOS, Linux, and Windows** — the local control plane uses a
Unix domain socket on macOS/Linux and a named pipe on Windows, and the service
command installs the matching per-user mechanism (LaunchAgent, systemd `--user`
unit, or a logon Scheduled Task). Zero-downtime upgrade handover is Unix-only;
Windows falls back to Session Restore. See
[`crates/triaged/README.md`](crates/triaged/README.md) for details.

## Testing

The workspace includes `triage-test-support`, a non-published crate for reusable acceptance-test helpers. It provides renderer snapshot normalization and VT byte-stream fixtures so terminal engine, daemon session, and TUI behavior can be tested with deterministic golden outputs.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
