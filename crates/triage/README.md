# triage

A terminal-based Ratatui local client for **Triage**, the attention-routing terminal supervisor.

This TUI client connects to the persistent background daemon (`triaged`) over local Unix sockets or Named Pipes, allowing you to attach, interact, monitor, and switch focus across persistent terminal workspaces.

## Features

*   **Durable Sessions**: PTYs are owned by the daemon, so they stay alive when you close the client, detach, or restart the daemon.
*   **Workspace Sidebar**: A session list showing each session's repo, worktree, and branch, so you can tell at a glance which terminal is which.
*   **Attach and Switch**: Cycle between sessions and drive the focused one directly; input goes through Triage's one-writer lease model.
*   **Update Banner**: A read-only notice when a newer Triage release is published (see [Update checks](#update-checks)).
*   **High Performance**: Built with Ratatui over a WezTerm-derived virtual terminal engine.

## Installation

Install both the client and daemon:

```bash
cargo install triage triaged
```

## Usage

First make sure the daemon is running. Start it in the foreground:

```bash
triaged
```

…or register it to start automatically at login (macOS, Linux, and Windows):

```bash
triaged service install
```

Then launch the client interface:

```bash
triage
```

The client connects to the daemon over a local Unix domain socket (macOS/Linux)
or named pipe (Windows). See [`triaged`](https://crates.io/crates/triaged) for
daemon and service details.

## Keys

Everything else you type is forwarded to the focused session.

| Key | Action |
| --- | ------ |
| `Ctrl+N` | New session |
| `Ctrl+W` | Close the focused session |
| `Alt+↓` / `Alt+→` / `F3` | Next session |
| `Alt+↑` / `Alt+←` / `F4` | Previous session |
| `F2` | Show/hide the sidebar |
| `PageUp` / `PageDown` | Scroll the focused session's scrollback |
| `Ctrl+Q` | Quit the client (sessions keep running in the daemon) |

`Ctrl+C` is forwarded to the session, not intercepted — it interrupts the
running program, as in any terminal. Use `Ctrl+Q` to leave the client.

## Update checks

The daemon polls for newer releases and the TUI surfaces an "update available"
banner naming the new version. It is **read-only** — nothing is downloaded or
installed automatically. Configure or disable it under `[update]` in
`~/.config/triage/config.toml`; see the
[`triaged`](https://crates.io/crates/triaged) docs.
