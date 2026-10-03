# 000157 — fix/input-reliability

## Agent

Muse Code (muse-spark), 2026-10-02.

## Intent

Typing-lag hunt follow-up (root causes found on the ux-trio worktree):
keystrokes are silently dropped on lease denial (handover wipe, takeover,
ghost holder) and in disconnect windows, there is no heartbeat on either
side so a half-dead socket keeps a green "attached" indicator while
typing goes nowhere, and the indicator never reflects actual socket
state. Fix all four: preserve leases across handover, park denied input
server-side and flush on acquire, buffer input across disconnects,
client heartbeat with dead-socket teardown, socket-driven indicator.

## What Changed

- Daemon: `HandoverSession` carries the input lease; adopt and
  restore-completion restore it instead of resetting.
- Daemon: `write_input` parks lease-denied bytes per (session, client);
  controller attach and the lease RPC flush them on grant.
- Client: offline input buffers (4KB cap) instead of dropping; the
  selected session's buffer flushes proactively on reconnect.
- Client: 25s `hello` heartbeat tears half-dead sockets down through the
  close path.
- Client: rail rows and the workspace header render
  `displayStatus(connected:)`, so a dead socket reads disconnected.
- Tests: handover lease round-trip, 2 denied-flush integrations, 2
  parked-map units, 4 displayStatus units; `connected:` threaded through
  rail/header test constructions.

## Decisions

- Restore-completion got the same one-line lease fix as adopt: it
  destructured the carried lease and inserted a default, which is only
  correct for fresh sessions.
- Park server-side, not client-side: only the daemon knows a write was
  denied, which makes the retry exactly-once by construction. Client
  retry is uncorrelatable without write acks (stale errors vs reordered
  LeaseChanged races).
- Park bounds: 4KB per (session, client), 10s TTL, sweep on touch,
  forgotten on shutdown. Stamp stays at the first byte so sustained
  typing into a denial still ages out.
- Error messages byte-identical: the client parses them to re-acquire,
  so the write_input restructure keeps both strings.
- Lock order sessions-then-parked everywhere; flush collected under the
  guard, sent after it drops.
- No daemon-side idle timeout: ghost leases self-heal via
  takeover-plus-park, and the client heartbeat covers the felt problem.
- No 'observing' indicator state: auto-acquire makes no-lease transient
  and the label would flicker.
- Heartbeat skips background (throttled timers must not kill idle
  connections) and pairing (nothing to prove before auth); auth can
  never fail a beat because an unauthenticated hello still answers.

## Issues

- `cargo test -p triaged --lib`: same 8 pre-existing pairing failures as
  the broadcast branch base; all 5 new tests green, everything else
  green.
- Residual: bytes in flight on a socket that dies are best-effort — the
  daemon cannot tell delivered from lost without write sequence numbers.
  Protocol-level ack/seq is the principled fix, deferred as future work.

## Commits

- HEAD — fix(input): end-to-end input reliability

## Progress

- 2026-10-02T21:54-0700: worktree + branch created from 42a634e, discovery
  done, plan written (000157-01).
- 2026-10-02T22:10-0700: D1/D2/C1/C2/C3 implemented. Daemon tests
  red-then-green (handover revert-run, 2x5s-deadline integrations);
  fmt + clippy clean; flutter analyze clean; 53 + 148 client tests pass.

## Research & Discoveries

- `writeInput` is fire-and-forget; a denied write reaches the client only
  as an `error` message, which the lease-error path turns into clear +
  re-acquire — but the denied bytes are already lost. One dropped char
  per denial, on both transports (unmatched ids fall through to events).
- Adopt inserts `InputLeaseState::default()`; `HandoverSession` carries no
  lease, so every reload silently denies the next write per session.
- `_pendingInputBytes` already survives reconnects (cleared only on
  server switch) and `hasInputLease` already resets on reconnect — the
  disconnect-window drop is just the `!isConnected` early return.
- No ping/pong anywhere; `isConnected` is `_channel != null`; the 60s
  stats poll ignores failures. A half-dead socket is undetectable.
- Client-side exact-once retry of denied bytes is unclosable without
  write acks (stale error events vs reordered LeaseChanged races), so
  the retry lives server-side where denial is known exactly.

## Lessons Learned

- None yet.

## Next Steps

- Implement D1/D2 (daemon), C1/C2/C3 (client) per the plan.
- Gates, commit, push, PR.
