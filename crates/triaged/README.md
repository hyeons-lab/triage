# triaged

Persistent daemon process that manages terminal session state, PTY multiplexing, and canonical VT performance structures for **Triage**, the attention-routing terminal supervisor.

The daemon runs persistently in the background, keeping terminal scrollbacks, layout grids, and active PTY handles alive even when no clients are attached.

## Installation

```bash
cargo install triaged
```

## Running the Daemon

Start the persistent supervisor process:

```bash
triaged
```
