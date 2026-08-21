# Triage

An attention-routing terminal supervisor: a long-running daemon (`triaged`), a Ratatui TUI (`triage`), an agent lifecycle-hook shim (`triage-hook`), a Flutter client (`triage_client`), and an MCP server (`triage-mcp`), all sharing one session API.

The daemon owns your terminals. Clients come and go — close the TUI, switch to your phone, restart the daemon with zero downtime to upgrade it — and the shells keep running.

## Install

```bash
cargo install triaged triage        # daemon + TUI
cargo install triage-hook           # agent lifecycle hook shim (approval judge)
cargo install triage-mcp            # optional: expose sessions to local AI agents
```

When installing from a local checkout, use `scripts/install.sh` rather than copying
the built binaries into place yourself. The binaries are adhoc-signed and macOS
caches a binary's code signature against its *inode*, so overwriting an installed
binary in place (what `cp` over a destination does) makes the kernel SIGKILL both
the running daemon and every relaunch with `Code Signature Invalid`. The script
installs through a temp file plus `rename`, which allocates a fresh inode and
avoids that entirely.

Desktop client builds are attached to every
[GitHub release](https://github.com/hyeons-lab/triage/releases). Releases after
`v0.1.6` also attach prebuilt CLI archives, plus a signature and checksum for
every asset — see
[Verifying a download](crates/triaged/README.md#verifying-a-download). No release
build carries an OS code-signing certificate, so macOS and Windows warn once; see
[Prebuilt desktop clients](crates/triaged/README.md#prebuilt-desktop-clients) for
the per-platform steps.

## Run

Start the daemon in the foreground with `triaged`, or register it to start at login:

```bash
triaged service install     # start now + run at every login + provision hooks
triaged service status
triaged service uninstall
```

To reload or upgrade the running daemon with **zero downtime** (preserving all live terminal sessions):

```bash
triaged reload
```

Then attach with `triage` (TUI), or open <http://127.0.0.1:7777> for the web
client the daemon serves itself.

`triaged` runs on **macOS, Linux, and Windows** — the local control plane uses a
Unix domain socket on macOS/Linux and a named pipe on Windows, and the service
command installs the matching per-user mechanism (LaunchAgent, systemd `--user`
unit, or a logon Scheduled Task). Zero-downtime upgrade handover and SIGTERM rescue
are Unix-only; Windows falls back to Session Restore. See
[`crates/triaged/README.md`](crates/triaged/README.md) for details.

## Components & Clients

| Component | What it is |
| --------- | ---------- |
| [`triaged`](crates/triaged/README.md) | Supervisor daemon — owns PTYs, canonical terminal grids, resident LLM summarizer, and Approval Judge. |
| [`triage`](crates/triage/README.md) | Ratatui TUI — sidebar, session switching, attach, and per-session auto-approval controls. |
| [`triage-hook`](crates/triage-hook/README.md) | Agent lifecycle-hook shim — auto-approves safe commands for Antigravity, Claude Code, and other agent CLIs. |
| [`triage_client`](flutter/triage_client/README.md) | Flutter app — web, iOS, Android, macOS, Windows, Linux. Pairs over WebSocket; remembers and switches between multiple daemons; includes approval dashboard. |
| [`triage-mcp`](crates/triage-mcp/README.md) | MCP server — lets a local AI agent *read* your session state (read-only). |

Remote clients attach over WebSocket and are gated by a device-code + PIN pairing
flow that issues a per-device token. Triage terminates no TLS itself — front it
with a reverse proxy, or keep it on a tailnet. See
[Pairing](crates/triaged/README.md#pairing), and
[Remote Access](docs/remote-access.md) for reaching your daemon from anywhere.

## Key Features

- **Resident Tool-Call Approval Judge**: Autonomous agent CLIs (Antigravity, Claude Code) ask Triage before running commands. A 3-layer security system (Layer 1 deterministic deny, Layer 2 deterministic allow, Layer 3 grammar-constrained local model) auto-approves safe commands like `git status` or `cargo test` while ensuring risky commands prompt for confirmation. See [Approval Judge](docs/approval-judge.md).
- **Zero-Downtime Process Handover & SIGTERM Rescue**: Upgrade or restart the daemon without dropping active shells. Passing PTY masters via `SCM_RIGHTS` and self-pipe signal handling rescues live sessions even during supervisor restarts (`triaged reload`).
- **Modern Terminal Emulation**: Support for Synchronized Output (DEC Mode 2026) to prevent cursor flicker, Unicode 11 emoji and wide-glyph rendering, and synthetic terminal query response filtering.
- **Cross-Platform Multi-Daemon Client**: Flutter client runs on desktop, mobile, and web, connecting securely to one or more daemons across local network or Tailscale.

## Configuration

Triage is configured via `~/.config/triage/config.toml`. All options are optional and carry sensible defaults. See the complete [Configuration Reference](docs/configuration.md).

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
navigation, attach, judge controls); the MCP server (read-only tools); remote access with PIN
pairing; the web client; Flutter desktop and Android builds; session persistence
across restarts; zero-downtime handover and SIGTERM rescue on Unix; and the local-model
[tool-call approval judge](docs/approval-judge.md), which lets an agent CLI
auto-approve its own routine commands while anything risky still prompts.

**Not there yet:** the features Triage is ultimately *named* for — needs-response
detection, attention-routing hotkeys, the overview grid, log search, and
notifications — plus TLS termination, iOS/Android push, and cross-client approval
modals (the judge answers an agent's own hook; it does not yet surface a prompt
on your phone). The
full roadmap, with honest per-item status, lives in
[`devlog/triage-design-doc.md`](devlog/triage-design-doc.md#-implementation-roadmap).

## Testing

The workspace includes `triage-test-support`, a non-published crate for reusable acceptance-test helpers. It provides renderer snapshot normalization and VT byte-stream fixtures so terminal engine, daemon session, and TUI behavior can be tested with deterministic golden outputs.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
