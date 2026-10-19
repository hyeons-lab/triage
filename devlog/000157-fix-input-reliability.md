# 000157: fix/input-reliability

## Agent

Muse Code (muse-spark), 2026-10-02.
2026-10-18T11:56-0700: Antigravity (Gemini 4 Argon High) @ triage branch fix/input-reliability (switched agent mid-branch).

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
- Client (follow-up): heartbeat teardown gated on 75s of inbound
  silence instead of one failed beat; transport tracks
  `millisSinceLastInbound` on every frame. The ungated version turned
  slow loads into teardown loops (see Issues).

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
- Liveness is inbound traffic, not the beat: a hello routinely times
  out behind a huge history replay on the daemon's serial
  per-connection queue (ws.rs handles requests inline, one at a time),
  so teardown requires 75s of total silence. Per-request concurrency on
  the daemon is the principled fix; deferred as a separate change
  (response reordering needs care).

## Issues

- `cargo test -p triaged --lib`: same 8 pre-existing pairing failures as
  the broadcast branch base; all 5 new tests green, everything else
  green.
- Residual: bytes in flight on a socket that dies are best-effort: the
  daemon cannot tell delivered from lost without write sequence numbers.
  Protocol-level ack/seq is the principled fix, deferred as future work.
- 2026-10-03T19:06-0700 outage: the ungated heartbeat tore the socket
  down on any single slow beat; on a slow connection the attach replay
  always exceeds the 10s request timeout, so every connect died
  mid-load and reconnected into the same wedge (sessions never
  loading). Ruled out a parked session-245 actor first: observer
  attaches to 245 and a control session both answered in <400ms, and
  the daemon sat at ~2% CPU. Fix is the silence gate above.

## Commits

- f986c19: fix(input): end-to-end input reliability
- 7b386e0: fix(client): gate heartbeat teardown on inbound silence
- 6580449: fix(triaged,client): review findings from input reliability audit
- HEAD: fix(triaged,client): address input reliability review rounds 2-4

## Progress

- 2026-10-02T21:54-0700: worktree + branch created from 42a634e, discovery
  done, plan written (000157-01).
- 2026-10-02T22:10-0700: D1/D2/C1/C2/C3 implemented. Daemon tests
  red-then-green (handover revert-run, 2x5s-deadline integrations);
  fmt + clippy clean; flutter analyze clean; 53 + 148 client tests pass.
- 2026-10-03T19:06-0700: silence-gated the heartbeat after the outage
  above; transport unit test green, analyze clean.
- 2026-10-03T19:31-0700: deploy took three tries (the first two
  installs served the pre-fix bundle; binary predated the flutter
  stamp; likely raced cargo invocations on a load-58 machine). A clean
  client rebuild (`rm -rf flutter/.../build` + release build) fixed
  it; curl-verified the served JS contains the new strings. Lessons:
  `grep` on the binary never works (rust-embed `compression` feature),
  so always curl-verify the served bundle after a web-client deploy.
- 2026-10-09T12:30-0700: Completed code review loop across daemon and
  Flutter client. Fixed input inversion race under session lock, bounded
  parked clients per session (MAX_PARKED_CLIENTS_PER_SESSION = 8), pruned
  pending input on session disposal, guarded session lookup on reconnect,
  flushed pending input on session select, verified legacy handover JSON
  backward compatibility, and enforced websocket silence invariant.
- 2026-10-09T12:48-0700: Confirmation round passed clean across all 8 pillars;
  addressed clean-up recommendations: consolidated lease grant and flush into
  canonical helper `grant_input_lease_and_flush`, unnested select pending input
  flush from async subscription guard, and asserted post-disconnect elapsed
  silence reset and error message format in test suites. All 364 workspace tests
  and 653 Flutter tests pass.
- 2026-10-14T21:46-0700: cascaded onto the hardened PR #184 head and
  re-reviewed (stack review loop, round 1: 1 bug, 4 correctness, 6
  quality, 4 nitpick). The cascade itself broke the test target against
  the parent's new `SerializedHandover`/watermark API (3 compile errors,
  fixed). Fixes: parked input now rides the handover state
  (`HandoverSession.parked_input`, re-parked fresh-stamped on adoption)
  instead of dying with the outgoing daemon; a failed parked flush
  restores the taken entry whole (original stamp) instead of dropping it
  while reporting success; a failed lease-change broadcast no longer
  fails a committed grant; demotion to Historical forgets parked input;
  the client cap keeps the fitting prefix instead of dropping the whole
  chunk; the client flush removes bytes only after a successful write;
  heartbeat teardown and the pending-input buffer are extracted into
  testable units (`heartbeatShouldTeardown`, `PendingInputBuffer`) with
  unit legs; denied-flush integration tests deduplicated. Correction to
  the Decisions entry above: the shipped flush is collected under the
  sessions guard and sent through the fire-and-forget actor channel (no
  round-trip), not sent after the guard drops. Gates on the cascaded
  tree: fmt + clippy clean, workspace check + docs clean, 368 triaged
  lib tests passing with the same 8 pre-existing pairing failures, 662
  Flutter tests passing, flutter analyze clean. Round 2 review pending.
- 2026-10-18T11:56-0700: review round 2 (1 bug, 2 correctness, 4
  quality, 1 nitpick). Fixes: extracted `PendingInputSender` with
  single-flight guard per session and drain-on-denial (`deniedByDaemon`
  confirms sent because the daemon now owns the parked copy, preventing
  duplicate delivery on re-acquire; transport failure retains the
  buffer); added `refresh_parked_input` in the handover IPC handler
  immediately before sending `HandoverState` so denials parked during
  the extract window ride the handover; added `restore_parked_entry`
  bypassing the new-client admission cap when re-parking a taken entry
  after a failed flush, and pinned original-stamp preservation on
  restore; memoized compressed segment uncompressed sizes in
  `storage.rs` by `(path, file_size)` (excluding the mid-rotation
  uncompressed fallback); extracted `heartbeatFailureAction` to pin
  foreground/pairing/connected re-checks on failed beats and documented
  the connected precondition on `heartbeatShouldTeardown`. Gates green.
  Round 3 review pending.
- 2026-10-18T12:26-0700: review round 3 (1 bug, 3 correctness, 2
  convention, 1 quality, 0 nitpick). Fixes: `refresh_parked_input` now
  shares `parked_input_for_handover` with `serialize_active_sessions`,
  refreshes `session.lease` alongside `session.parked_input` under the
  `sessions`-then-`parked` lock order, and clears `parked_input` when the
  entry was flushed or swept during the extract window (while preserving
  retained `pending_adoptions` sessions); extracted top-level
  `leaseErrorSessionId` requiring `'input lease'` in the message so
  non-lease session errors never drop unsent buffered bytes; looped
  `PendingInputSender.flush` until the snapshot is empty, routed live
  keystrokes through `_pendingInput` whenever `hasPending` is true, and
  cleared `hasInputLease` on `PendingFlushOutcome.failed`; forgot
  client-side `_pendingInput` and cleared `hasInputLease` on `Exited`,
  exited snapshots, and before `restoreSession`; prepended older restored
  bytes ahead of newer parked bytes in `restore_parked_entry`; restored
  `pub fn get_segment_uncompressed_size`'s summary doc line; and pinned
  `segment_size_cache` memoization (plus uncached `NotFound` fallback)
  and `restore_session` lease preservation with non-vacuous regression
  assertions. Gates green. Round 4 review pending.
- 2026-10-18T12:44-0700: review round 4 (2 correctness; Reviewers 2 and 4
  returned NO FINDINGS). Fixes: extracted top-level
  `attachGrantsInputLease` returning `false` when `snapshot['exited'] ==
  true` so dormant pre-demotion leases on historical sessions never mark
  an exited `SessionVm` as holding a live input lease; updated
  `_loadDaemonSession` to forget `_pendingInput` and keep the exited
  post-attach snapshot when `snapshot['exited'] == true`; updated
  `_refreshSessionSnapshot` to check `_isStale(owningGeneration)` and
  recompute `session.hasInputLease` from `freshAttachRes` after
  `restoreSession`; and triggered `_acquireInputLeaseAndFlush` in
  `_loadDaemonSessionInto` when an on-demand loaded live session has
  buffered `_pendingInput`. Gates green. Round 5 narrowed review pending.
- 2026-10-18T12:55-0700: review round 5 narrowed (Reviewers 1 & 3) and
  round 6 confirmation (all 4 lenses) both completed with NO FINDINGS
  across all 8 pillars.

## Research & Discoveries

- `writeInput` is fire-and-forget; a denied write reaches the client only
  as an `error` message, which the lease-error path turns into clear +
  re-acquire, but the denied bytes are already lost. One dropped char
  per denial, on both transports (unmatched ids fall through to events).
- Adopt inserts `InputLeaseState::default()`; `HandoverSession` carries no
  lease, so every reload silently denies the next write per session.
- `_pendingInputBytes` already survives reconnects (cleared only on
  server switch) and `hasInputLease` already resets on reconnect: the
  disconnect-window drop is just the `!isConnected` early return.
- No ping/pong anywhere; `isConnected` is `_channel != null`; the 60s
  stats poll ignores failures. A half-dead socket is undetectable.
- Client-side exact-once retry of denied bytes is unclosable without
  write acks (stale error events vs reordered LeaseChanged races), so
  the retry lives server-side where denial is known exactly.

## Lessons Learned

- A take-then-send flush loses bytes exactly when the send fails; take
  an entry you can restore whole (stamp included, prepended ahead of any
  newer bytes parked in the interim), or consume only on success.
- Cascading a stack breaks child test code against the parent's new
  APIs even when the rebase is conflict-free; compile the child's test
  target immediately after every rebase.
- When a denied payload is parked by the receiver for later flush, the
  sender must drop its copy on a lease-denial error (retaining only on
  transport failure) or both sides deliver on re-acquire.
- A pre-send refresh that only overwrites on `Some(entry)` leaves the
  pre-extraction snapshot intact whenever the entry was drained or
  expired during the extraction window; project the current value
  unconditionally (empty when absent) alongside companion ownership
  state.

## Next Steps

- Cascade to PR #186 (`perf/load-quick-wins`) and continue the stack review loop.
