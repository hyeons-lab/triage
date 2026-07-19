# Triage

An attention-routing terminal supervisor: a long-running daemon (`triaged`), a Ratatui TUI (`triage`), a Flutter client (`triage_client`), and an MCP server (`triage-mcp`), all sharing one session API.

The daemon owns your terminals. Clients come and go — close the TUI, switch to your phone, restart the daemon to upgrade it — and the shells keep running.

## Install

```bash
cargo install triaged triage        # daemon + TUI
cargo install triage-mcp            # optional: expose sessions to local AI agents
```

Prebuilt binaries and desktop/mobile client builds are attached to every
[GitHub release](https://github.com/hyeons-lab/triage/releases). See
[`crates/triaged/README.md`](crates/triaged/README.md#installation) for the
per-platform notes (the release builds are unsigned, so each OS warns once).

## Run

Start the daemon in the foreground with `triaged`, or register it to start at login:

```bash
triaged service install     # start now + run at every login
triaged service status
triaged service uninstall
```

Then attach with `triage` (TUI), or open <http://127.0.0.1:7777> for the web
client the daemon serves itself.

`triaged` runs on **macOS, Linux, and Windows** — the local control plane uses a
Unix domain socket on macOS/Linux and a named pipe on Windows, and the service
command installs the matching per-user mechanism (LaunchAgent, systemd `--user`
unit, or a logon Scheduled Task). Zero-downtime upgrade handover is Unix-only;
Windows falls back to Session Restore. See
[`crates/triaged/README.md`](crates/triaged/README.md) for details.

## Clients

| Client | What it is |
| ------ | ---------- |
| [`triage`](crates/triage/README.md) | Ratatui TUI — sidebar, session switching, attach. |
| [`triage_client`](flutter/triage_client/README.md) | Flutter app — web, iOS, Android, macOS, Windows, Linux. Pairs over WebSocket; remembers and switches between multiple daemons. |
| [`triage-mcp`](crates/triage-mcp/README.md) | MCP server — lets a local AI agent *read* your session state (read-only). |

Remote clients attach over WebSocket and are gated by a device-code + PIN pairing
flow that issues a per-device token. Triage terminates no TLS itself — front it
with a reverse proxy, or keep it on a tailnet. See
[Pairing](crates/triaged/README.md#pairing), and
[Remote Access](docs/remote-access.md) for reaching your daemon from anywhere.

## Architecture

- The daemon owns canonical session state: PTYs, terminal grid snapshots, scrollback sequence numbers, metadata, and status.
- Multiple clients can observe a session, but input goes through a one-writer lease model. A session has one active interactive controller at a time.
- Repo/worktree grouping is inferred from OS and git state, with durable session cwd separated from transient foreground process cwd.
- Local transports use local trust boundaries first. Remote network transports require authentication.
- Persistence restores metadata, logs, and UI state. It does not promise resurrection of arbitrary foreground programs.

## Status

Usable, and used daily by its author — but pre-1.0, and the attention-routing
half of the product is still being built.

**Working today:** the daemon and its session core; local IPC; the TUI (sidebar,
navigation, attach); the MCP server (read-only tools); remote access with PIN
pairing; the web client; Flutter desktop and Android builds; session persistence
across restarts; and zero-downtime handover on Unix.

**Not there yet:** the features Triage is ultimately *named* for — needs-response
detection, attention-routing hotkeys, the overview grid, log search, and
notifications — plus TLS termination, iOS/Android push, and approval gates. The
full roadmap, with honest per-item status, lives in
[`devlog/triage-design-doc.md`](devlog/triage-design-doc.md#-implementation-roadmap).

## Testing

The workspace includes `triage-test-support`, a non-published crate for reusable acceptance-test helpers. It provides renderer snapshot normalization and VT byte-stream fixtures so terminal engine, daemon session, and TUI behavior can be tested with deterministic golden outputs.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
