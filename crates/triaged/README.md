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

---

## Zero-Downtime Upgrades (Process Handover)

On Unix-like operating systems (including Linux, WSL, and macOS), `triaged` supports **zero-downtime updates**. This allows you to upgrade the daemon binary or restart the service without dropping active terminal sessions or interrupting running foreground shells.

### How it Works

The upgrade is performed using a robust, low-level **Three-Phase Sync Protocol**:
1.  **Transfer Phase**: The new daemon process is launched and connects to the running old daemon over a Unix Domain Socket, initiating a file descriptor transfer using `SCM_RIGHTS` (`sendmsg`/`recvmsg`). The old daemon passes all active master PTY file descriptors and the bound TCP listening socket directly to the new process.
2.  **Adoption & Sync Phase**: The new daemon adopts the active descriptors, reconstructs the in-memory virtual terminal grids and scrollback history by replaying the session log files, and starts network supervision.
3.  **Teardown Phase**: Once adopted, the new daemon writes a synchronization byte back to the old daemon. The old daemon gracefully drops its session references (without closing the underlying shells), closes its Unix socket, and exits, completing a zero-downtime handover.

### Initiating a Handover

To upgrade or restart the daemon with zero downtime, run the new binary with the `--handover` (or `-U`) flag:

```bash
triaged --handover
```

### Windows Graceful Fallback

Because low-level file descriptor passing and raw Unix domain sockets are native to POSIX platforms, native Windows installations will fall back gracefully to Triage's robust **Session Restore** flow, which saves session metadata and restores shell/workspace layout structures on restart.
