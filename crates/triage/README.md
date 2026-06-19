# triage

A terminal-based Ratatui local client for **Triage**, the attention-routing terminal supervisor.

This TUI client connects to the persistent background daemon (`triaged`) over local Unix sockets or Named Pipes, allowing you to attach, interact, monitor, and switch focus across persistent terminal workspaces.

## Features

*   **Durable Sessions**: PTYs stay alive in the background even if you close the terminal or detach.
*   **Workspace Sidebar**: Rapid navigation and group context overview.
*   **Rich Layouts**: Multiplex multiple panels and monitors.
*   **High Performance**: Built with Ratatui and an optimized community virtual terminal parser.

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
