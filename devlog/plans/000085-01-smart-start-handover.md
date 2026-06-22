# Plan 000085-01 — smart start (adopt-or-fresh)

## Thinking

The daemon runs under a KeepAlive LaunchAgent. The two existing startup modes are
both wrong for a supervised service:

- `triaged --handover` requires an existing daemon; with none it bails. Under
  KeepAlive that's a crash-loop (respawn → bail → respawn). Observed in the
  launchd stderr log.
- plain `triaged` bails "already in use" when a live socket exists, so a
  supervised respawn fights an in-flight manual handover deploy (and produces the
  paired PID churn).

The decision "handover vs fresh" should be driven by reality — is a live daemon
already on the socket? — not by the CLI flag. That one rule is safe in all cases:
cold start with nothing running starts fresh; a start that races/follows a live
daemon adopts it with zero session loss. The handover protocol is already
designed for the new process to initiate adoption, so there's no mutual-storm
risk.

## Plan

1. In `crates/triaged/src/main.rs`, replace the flag-gated handover block with a
   liveness-probe decision: if a live daemon owns the socket, hand over; else
   start fresh. `--handover` becomes a hint (warn if requested with no daemon).
2. Add `is_live_daemon_socket(path)` — `path.exists() && UnixStream::connect(path).is_ok()`.
3. Keep the Windows rejection of `--handover`.
4. Build; verify end-to-end against the real daemon: (a) a start with a live
   daemon adopts it; (b) `--handover` with no daemon starts fresh instead of
   bailing.
5. Deploy via handover, then reconcile the launchd job (reload the on-disk plain
   plist) so it stops spawning `--handover`.
6. Commit devlog + plan + code; open a draft PR.
