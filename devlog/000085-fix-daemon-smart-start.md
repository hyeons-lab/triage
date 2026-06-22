# 000085 — fix/daemon-smart-start

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/daemon-smart-start

## Intent

The daemon "churns" PIDs on each handover: every manual `triaged --handover`
deploy is followed ~14s later by a second, self-triggered handover. Investigate
and fix.

## Research & Discoveries

- 2026-06-21T20:10-0300 — The daemon runs as a macOS LaunchAgent
  (`~/Library/LaunchAgents/com.hyeons-lab.triaged.plist`) with `KeepAlive: true`,
  so launchd respawns it on every exit. The handover timestamps in the daemon
  log come in pairs ~12–14s apart (e.g. 18:28:16 then 18:28:30), one per manual
  deploy plus one launchd respawn. It self-settles once the launchd-owned process
  owns the socket.
- The launchd job was spawning `triaged --handover` (the live process args and,
  conclusively, the launchd stderr log `~/Library/Logs/triage/triaged.err.log`
  showing repeated `Error: No running daemon socket found ... Start the daemon
  normally first.` — produced only by the `--handover` path in `main.rs`).
- Two problems with `--handover` under a KeepAlive supervisor:
  1. **Churn**: a manual handover makes the launchd-owned daemon exit; KeepAlive
     respawns `--handover`, which does a *second* handover to reclaim the socket.
  2. **Crash-loop hazard (observed)**: `--handover` *requires* an existing
     daemon. If the daemon ever exits with no replacement, the respawn bails and
     exits non-zero; KeepAlive respawns; it bails again — a tight loop the
     service can't recover from. A KeepAlive service must be able to cold-start.
- A plain `triaged` start isn't right either: `bind_owner_socket` bails
  "already in use" when a live socket exists (the `Status 1` seen in
  `launchctl list`), so a supervised respawn fights an in-flight manual deploy.

## Decisions

- 2026-06-21T20:30-0300 — Make startup "smart": decide handover vs fresh by
  probing whether a *live* daemon already owns the socket, not by the
  `--handover` flag. Live socket → hand over (adopt, zero session loss). No live
  socket → start fresh (so `--handover` no longer bails, killing the crash-loop;
  and a plain supervised respawn cold-starts instead of erroring). This single
  mode is safe under KeepAlive and doesn't fight manual deploys.

## What Changed

- 2026-06-21T20:30-0300 `crates/triaged/src/main.rs` — replaced the rigid
  `if is_handover { handover-or-bail }` block with a liveness-probe-driven
  decision. `--handover` is now a no-op hint (a warning when requested with no
  daemon to adopt). Windows still rejects `--handover` explicitly.
- 2026-06-22T00:50-0300 `crates/triaged/src/main.rs` — (PR #97 review) replaced
  the boolean `is_live_daemon_socket` with `probe_daemon_socket` →
  `DaemonSocketState { Live, Absent, Unverifiable }`, mirroring
  `bind_owner_socket`'s error-kind handling: `ConnectionRefused`/`NotFound` is
  `Absent` (stale), an unexpected connect error is `Unverifiable` (warn, treated
  as live so we don't proceed under an unvalidated assumption). Handover failure
  now falls back to a fresh start instead of aborting launch.
- 2026-06-22T00:50-0300 `crates/triaged/src/handover.rs` — (PR #97 review) set a
  10s read timeout on the handover client stream before `recv_fds`, so a hung
  daemon or a non-triaged process squatting on the socket can't block startup
  forever; the caller falls back to a fresh start on timeout. Verified with an
  isolated socket squatter (exits in ~10s instead of hanging).

## Issues

- The on-disk plist (and `triaged service install`'s generated plist) already use
  plain `triaged`; only the *loaded* launchd job had drifted to `--handover`.
  Reconciled by reloading the job after deploying the fixed binary.

## Next Steps

- After merge: confirm `triaged service install` plist + this smart-start cover
  both cold start and graceful upgrade on Linux (systemd) and Windows too.

## Commits

- HEAD — fix(triaged): adopt-or-start-fresh on launch so KeepAlive can't crash-loop
