# 000124: fix/harden-handover

**Agent:** Claude (claude-opus-5[1m]) @ triage branch fix/harden-handover
(worktree: worktrees/harden-handover)
**Agent:** Codex (gpt-5.6-sol) @ triage branch fix/harden-handover —
2026-08-15T09:13-0700

## Intent

Make a handover survivable. Five daemons wedged across 2026-08-11 and
2026-08-13, and one set of live sessions destroyed. The owner is asked to keep
every PTY master alive across an upgrade, so anything that stops it mid-swap, or
leaves it unable to serialize its sessions, turns a routine upgrade into an
outage. Close the two defects that caused every incident, plus the descriptor leak
that produced spurious bind failures.

## What Changed

- 2026-08-13T19:55-0700 `crates/triaged/src/main.rs`: added
  `ignore_terminal_job_control_signals`, called once at startup after help/version
  return and before any handover work. Sets `SIGTTOU` and `SIGTTIN` to `SIG_IGN`
  for the process lifetime. Handover teardown calls `tcsetattr`, which raises
  `SIGTTOU` *unconditionally* for a background process group (TOSTOP does not gate
  it), and an ignored `SIGTTOU` is what lets that call proceed instead of stopping
  us. Deliberately not `setsid`: a successor must keep serving whatever it
  inherited regardless of how it was launched, and the goal is narrower: job
  control must never freeze the owner of live PTYs.
- 2026-08-13T19:55-0700 `crates/triaged/src/session.rs`: `SessionApi::write_input`
  now resolves and authorizes the session under the sessions lock, clones the
  actor's `Sender`, drops the guard, and only then does the round-trip, via a new
  `request_write_input` free function. `SessionActor::write_input` delegates to the
  same function so there is one implementation. This is the `request_summary_rows`
  pattern already documented in this file, applied to the one caller that never
  got it. **Superseded 2026-08-13T22:45-0700**: the delegating method was deleted once
  its only remaining callers were tests; the free function is the implementation.
- 2026-08-13T19:55-0700 `crates/triaged/src/session.rs`: `git_raw_output` spawns
  through a new `detach_from_terminal`, a `pre_exec` hook calling `setsid`, so a
  cwd-detection child has no controlling terminal and cannot be job-control
  stopped. Non-unix gets an empty stub.
- 2026-08-13T19:55-0700 `crates/triaged/src/main.rs`: added
  `close_listener_on_exec`, called once on the finished `tcp_listener` so it covers
  all three construction paths (inherited, and both fresh binds). Sets
  `FD_CLOEXEC` so the listener stops leaking into exec'd children.
  **Superseded 2026-08-13T21:45-0700**: deleted again. It was a no-op on the two fresh
  binds (`std` already sets the flag) and became one on the inherited path too once
  `recv_fds` set it on arrival, which is where the leak actually was.

- 2026-08-13T20:30-0700 `crates/triaged/src/shutdown.rs` (new): answers SIGTERM,
  SIGINT and SIGHUP by starting a detached `triaged --handover` and staying up
  until that successor drives the ordinary three-phase handover to completion,
  which exits this process from the IPC handler thread. Self-pipe handlers (see
  Decisions), a rescue thread, `setsid` + null stdio on the successor, one retry,
  and a bounded budget. Nothing about the protocol is re-implemented; the signal
  path only decides *when* to start a successor.
- 2026-08-13T20:30-0700 `crates/triaged/src/handover.rs`: added
  `SHUTDOWN_RESCUE_TIMEOUT` (90s) with a compile-time assertion that it outlasts
  `HANDOVER_ADOPTION_TIMEOUT` + `HANDOVER_TEARDOWN_TIMEOUT`. Placed with the other
  handover deadlines rather than in the unix-only shutdown module so `service.rs`
  can assert against it on every target, Windows CI included.
- 2026-08-13T20:30-0700 `crates/triaged/src/service.rs`: `ExitTimeOut` 150 in the
  plist and `TimeoutStopSec=150` in the systemd unit, compile-time asserted above
  the rescue budget: launchd's 20s and systemd's 90s defaults both escalate to
  SIGKILL partway through a rescue, which destroys what the rescue is saving.
  `stop` and `uninstall` now send `DisableShutdownRescue` first, so an
  operator-requested stop is a plain exit and `uninstall` leaves nothing running.
- 2026-08-13T20:30-0700 `crates/triaged/src/ipc.rs`: new
  `WireRequest::DisableShutdownRescue` (+ `IpcClient::disable_shutdown_rescue`),
  and `unlink_own_default_socket` so an orderly non-handover exit cleans up its
  socket the way the handover exit already does.
- 2026-08-13T20:30-0700 `crates/triaged/src/session.rs`: `handover_in_flight()`
  and `try_live_session_count()`, both non-blocking, so the rescue never waits on
  the sessions mutex. `detach_from_terminal` became `pub(crate)` so the rescue
  reuses it rather than writing a second `setsid` `pre_exec` hook.
- 2026-08-13T20:30-0700 `crates/triaged/src/main.rs`: installs the handlers next to
  the job-control ignore (daemon invocations only), starts the rescue thread as soon as
  logging is up, and arms it with the manager the moment one exists.
- 2026-08-13T21:15-0700 `crates/triaged/src/session.rs`: `snapshot_session`,
  `styled_rows` and `resize_session` now resolve under the sessions lock and
  round-trip off it, through new `request_snapshot` (already existed),
  `request_resize` and `request_styled_rows` free functions (the matching
  `SessionActor` methods delegated to them until 22:45, when they were deleted as
  test-only). A new `Resolved` enum names the two
  cases (served under the lock, or an actor channel to use after releasing it).
  This is the finding that mattered most from review: 000124-01's premise, that
  `write_input` was "the one caller that never got it", was wrong. Snapshots are
  the *hottest* path in the daemon (clients poll them), so a session whose child
  stopped reading would have re-wedged everything on the next poll even with
  `write_input` fixed.
- 2026-08-13T21:15-0700 `crates/triaged/src/handover.rs`: `dup_cloexec` and
  `set_cloexec`, with three consequences. Every `dup` of a master or the listener goes
  through `dup_cloexec`, because `libc::dup` deliberately does *not* carry
  `FD_CLOEXEC`. `recv_fds` sets the flag on every descriptor it receives, which is the
  largest half by far: after a handover *every* master this daemon owns is a received
  descriptor, and macOS has no `MSG_CMSG_CLOEXEC` to ask for the flag on arrival. And
  `close_listener_on_exec`, added by 000124-01, was **deleted**: with `recv_fds` fixed
  it was a no-op on all three paths, since `TcpListener::bind` already returns a
  close-on-exec socket. Together these are the real mechanism behind the `git` child
  found holding :7777; 000124-01 had diagnosed it as an inheritable *listener* and
  fixed the one path that was never the problem.
- 2026-08-13T21:15-0700 `crates/triaged/src/shutdown.rs`: review pass, all of it
  behavioural. `errno` saved and restored around the handler's `write`; the pipe's
  write end made non-blocking so a saturated pipe can never park the handler
  inside an interrupted thread; another queued signal polled *during* the wait, so
  "send another stop signal to exit anyway" is true while the rescue runs rather
  than only after it; a successor that outlives the wait killed and reaped instead
  of dropped, so a failed rescue cannot leave a second daemon on the same socket
  and port; the in-flight-handover branch now falls through to its own successor
  when that swap ends without exiting us; a minimum-budget floor on the retry; and
  a wait for this daemon's own control socket before spawning, since a signal
  answered during startup would otherwise burn an attempt on a successor with
  nothing to hand over from.
- 2026-08-13T21:15-0700 `crates/triaged/src/session.rs`: the last three doors onto
  the same wedge. `attach_session` and `subscribe_session_events_from` now resolve
  under the lock and round-trip off it (a new `request_subscribe_events` joins the
  other `request_*` helpers), and `SessionActor::broadcast_event` became
  fire-and-forget. The actor's `BroadcastEvent` handler answers `Ok(())`
  unconditionally, so waiting for it reported nothing the `send` did not, while
  costing the daemon three lock-held round-trips: `attach_session` plus both lease
  calls. Not waiting is also what preserves ordering; see the Decisions entry.
- 2026-08-13T21:45-0700 `crates/triaged/src/session.rs`: `serialize_active_sessions`
  now snapshots each live session's `Sender` and launch data under the lock and does the
  extract round-trips off it, bounded by a `HANDOVER_EXTRACT_BUDGET` shared across all
  of them (see the 22:15 entry for why it is shared and pipelined rather than per-actor).
  The one lock-held blocking call left, and the worst one to leave: it is the call a
  handover cannot proceed without, so a single parked actor made the daemon
  un-handoverable in exactly the situation that most needs a handover, and defeated the
  shutdown rescue with it. An actor that misses the deadline is now skipped, which
  loses that one session rather than all of them; the previous code aborted the whole
  swap on a dead actor, which is the trade being reversed here deliberately.
- 2026-08-13T21:45-0700 `crates/triaged/src/{main,shutdown}.rs`: `arm_rescue` moved to
  immediately after the manager is created, from after adoption. Between the handover
  commit and the old call site this process is the sole owner of every adopted master,
  and an unarmed stop signal there took the "exit without a rescue" path, closing all of
  them. That was a regression introduced by the round-2 fix, found in round 3.
- 2026-08-13T21:45-0700 `crates/triaged/src/{ipc,shutdown}.rs`: `own_socket_is_bound`,
  set on a successful bind, replaces the connect probe the rescue used to decide the
  socket was ready. A connect cannot tell our socket from a predecessor's mid-swap, so
  it could green-light a successor that hands over from a daemon which has already
  detached its sessions.
- 2026-08-13T21:45-0700 `crates/triaged/src/session.rs`: the extract round-trips share
  one `HANDOVER_EXTRACT_BUDGET` instead of a deadline each, and the actor closes the
  descriptor it duplicated when the answer finds no receiver. Both come from the same
  observation: the bound that matters is the *successor's*, which gives up on the whole
  Phase-1 response after `HANDOVER_TRANSFER_TIMEOUT`, so per-actor deadlines would sum
  past it the moment a second session was parked and fail the swap wholesale. And a
  bounded caller means a late answer routinely arrives with nobody to take it, which
  leaked one master per late session per attempt.
- 2026-08-13T22:15-0700 `crates/triaged/src/session.rs`: the extract commands are all
  sent *before* any waiting starts, and `ExtractedHandover::fd` became an `OwnedFd`.
  Both fix defects in the previous entry's own fix. Sending inside the collect loop meant
  that once one parked actor spent the shared budget, every session after it got a
  zero-length wait against an actor that had not yet been asked, so a single wedged
  session dropped most of the set (a reviewer measured 199 spurious timeouts in 200
  against an instantly-answering actor). Pipelining makes the loop cost the slowest actor
  rather than the sum, and a healthy actor's answer is already queued when the collect
  reaches it. The `OwnedFd` closes the descriptor when a late answer finds its receiver
  gone, which the manual close it replaces could not: that path had the send *succeed*
  into a channel about to be dropped.
- 2026-08-13T22:15-0700 `crates/triaged/src/service.rs`: `KillMode=process` in the
  systemd unit. Without it the Linux rescue could not work at all: systemd's default
  signals every process in the unit's cgroup on stop, and `setsid` does not move a
  process out of a cgroup, so the successor was killed along with the daemon that started
  it. The raised `TimeoutStopSec` alone just made that take 90 seconds.
- 2026-08-13T22:15-0700 `crates/triaged/src/shutdown.rs`: insistence is now tracked per
  stop *episode* rather than per attempt, and the control-socket wait polls for signals.
  A rescue can fail in milliseconds (a spawn error returns at once), and restarting the
  coalesce window on every attempt meant a caller signalling faster than
  `SIGNAL_COALESCE_GRACE` could never register as insisting: the daemon forked a
  successor per signal and never exited, turning the override into a livelock.
- 2026-08-13T21:45-0700 `crates/triaged/src/shutdown.rs`: three more all-or-nothing
  error paths. A rescue-thread spawn failure or an unreadable pipe now restores the
  default signal dispositions, because a handler installed with nothing consuming it is
  worse than no handler: the signal is caught, discarded, and the daemon becomes
  stoppable only by SIGKILL. The top-of-loop insistence check now applies
  `SIGNAL_COALESCE_GRACE` as well, so a rescue that fails in a second does not read the
  rest of the same teardown burst as an operator insisting. And the retry floor is
  re-checked after `wait_for_own_ipc_socket`, which can consume it on its own.
- 2026-08-13T21:15-0700 `crates/triaged/src/service.rs`: the rescue-disable moved
  from four per-platform call sites into `run_cli`, the one place `stop` and
  `uninstall` both pass through (which also stops the `cfg(not(unix))` stub being
  dead code on Windows).

- 2026-08-13T22:45-0700 `crates/triaged/src/shutdown.rs`: insistence is keyed to the
  last *failure* rather than to the chain of attempts, and `failures_this_episode` is
  gone. The round-5 shape had the same class of bug it fixed, from the opposite side: a
  rescue that spends its whole 90s budget takes longer than the 60s `INSIST_WINDOW`, so
  the signal after it started a "new episode", zeroed the failure count, and launched
  another full rescue instead of exiting. The daemon logged "send another stop signal to
  exit anyway" and then did not, for the *commonest* failure mode. Two independent
  reviewers found it in the same round, at the same line.
- 2026-08-13T22:45-0700 `crates/triaged/src/session.rs`: deleted
  `SessionActor::write_input`, `resize` and `styled_rows`, whose only remaining callers
  were tests once the `SessionApi` methods started calling the `request_*` free
  functions directly. `snapshot` stays: it still has a production caller.

- 2026-08-13T23:15-0700 `crates/triaged/src/shutdown.rs`: the burst window is computed
  once per rescue and passed into both waits, instead of being re-armed inside each one,
  and the control-socket wait now honours it. Re-arming meant an operator's override
  could be drained and discarded during the first seconds of a retry, so
  `run_rescue_loop` never saw it: the promise in the log was silently unkeepable for
  three seconds per attempt. The socket wait had the opposite half of the same bug, no
  window at all, and it is reachable while holding masters freshly adopted from a
  predecessor, so a logout's SIGHUP-then-SIGTERM there would have closed all of them.
- 2026-08-13T23:15-0700 `crates/triaged/src/handover.rs`: the rescue budget's
  compile-time assertion now includes `HANDOVER_TRANSFER_TIMEOUT`. Phase 1 runs inside
  the budget too, so calling the 20s above adoption-plus-teardown "slack" attributed a
  bounded protocol phase to slack. Same class of arithmetic slip as the one this file
  already records auditing out of that comment, in the same comment.
- 2026-08-14T07:35-0700 `crates/triaged/src/service.rs`: split `STOP_GRACE_SECS` into
  `LAUNCHD_STOP_GRACE_SECS` (60) and `SYSTEMD_STOP_GRACE_SECS` (150). macOS launchd
  silently caps ExitTimeOut at 60s (values above 60 are replaced with 60 by launchd),
  while systemd TimeoutStopSec has no such cap. Updated assertions and unit generation
  tests to reflect each platform's invariant.
- 2026-08-14T07:35-0700 `crates/triaged/src/handover.rs`: `complete_handover_adoption`
  now handles Phase 2 write and timeout errors with peer liveness probing. If sending
  the 0x01 adoption byte fails because the outgoing daemon died (SIGKILLed by launchd
  during Phase 2 warm-up), the successor adopts what was transferred instead of
  aborting. If the peer is still alive, it refuses adoption so the living peer keeps
  serving. Added unit tests in `handover_tests.rs` verifying both dead-peer adoption and
  alive-peer refusal during Phase 2 write failure and Phase 3 EOF.
- 2026-08-14T10:55-0700 `crates/triaged/src/{handover,handover_tests}.rs`: record the
  Phase 1 peer socket's device and inode, then require the same socket identity before
  treating a later listener as the daemon that transferred the descriptors. A launchd
  respawn at the same pathname is now classified as a dead peer, so the successor adopts
  the transferred PTY masters. Added a regression test that replaces the original
  listener before the Phase 2 write fails.
- 2026-08-14T13:23-0700 `crates/triaged/src/{handover,ipc,session,handover_tests}.rs`:
  **Supersedes the 10:55 socket-identity check.** The state now carries the Phase 1
  daemon PID, and a failed Phase 2 or Phase 3 connection sends an IPC probe that only
  that daemon can answer while its handover guard is active. The probe and response use
  one connection, so a launchd respawn cannot win a pathname check between metadata and
  connect. Added a test for the active-owner probe and serialized the tests that mutate
  process-global handover state.
- 2026-08-14T13:26-0700 `crates/triaged/src/ipc.rs`: **Supersedes the 13:23
  active-handover predicate.** A matching Phase 1 owner PID now answers the probe even
  after its handover guard has dropped. An aborted owner retains every PTY master and
  must be recognized as alive so the late successor refuses rather than creating a
  second reader. The probe regression now verifies both the in-flight and post-abort
  states, plus rejection of a different PID.
- 2026-08-14T16:35-0700 `crates/triaged/src/{handover,ipc,session,handover_tests}.rs`:
  **Supersedes PID-based peer identity.** The handover state and probe now carry a
  random 128-bit daemon-instance token, which launchd cannot reuse after a SIGKILL.
  A pre-token peer is ambiguous by definition, so its error path adopts rather than
  dropping the only transferred descriptors. Added coverage for a token-confirming
  peer, a replacement peer, and the identity-less legacy policy.
- 2026-08-14T18:26-0700 `crates/triaged/src/{handover,handover_tests,ipc}.rs`:
  **Supersedes the 16:35 identity-less adopt policy.** A tokenless peer that
  announces the teardown-commit protocol is treated as still live after a Phase 2
  write failure or Phase 3 EOF, so the successor refuses instead of risking a
  second reader. Peers that predate the commit protocol retain their historical
  adopt-on-EOF behavior. Gated Unix-only token imports and the probe handler so
  non-Unix builds remain warning-free.
- 2026-08-14T18:43-0700 `crates/triaged/src/{handover,handover_tests,ipc}.rs`:
  **Supersedes the 18:26 tokenless fallback.** The successor records the original
  Unix peer PID during Phase 1 and authenticates it on a fresh Phase 2 connection
  for the immediately preceding commit-capable protocol. A mismatched token or PID
  unlinks only the replacement daemon's IPC pathname before adoption, letting the
  successor bind and retain the transferred PTYs. Added coverage for token and PID
  mismatch fencing.
- 2026-08-14T19:03-0700 `crates/triaged/src/{handover,ipc,main}.rs`:
  **Supersedes pathname fencing.** A failed token probe is now classified as a
  replacement after any successful connection, including a daemon too old to parse
  the probe. The successor never unlinks another process's socket; after adopting,
  it keeps the inherited PTYs and waits without expiry to claim the IPC pathname.
  The legacy fallback now uses a non-reusable process identity: macOS audit token
  (including PID version) or Linux kernel peer credentials plus process start time.
- 2026-08-14T19:43-0700 `crates/triaged/src/{handover,ipc}.rs`:
  A connected but non-confirming probe is now indeterminate and refuses adoption.
  A definitive identity mismatch invokes a bounded, ordinary empty-session handover
  against the replacement, so it releases its own listener before this successor
  adopts; failure to arbitrate refuses safely rather than creating duplicate readers.
- 2026-08-14T19:47-0700 `crates/triaged/src/{ipc,main}.rs`: **Supersedes the
  19:03 no-expiry wait.** Successful replacement arbitration releases the socket
  before adoption, so the normal bounded bind grace remains sufficient. A failed
  arbitration refuses before descriptors are adopted rather than leaving a daemon
  alive but unreachable over local IPC.
- 2026-08-14T19:56-0700 `crates/triaged/src/{handover,ipc,main}.rs`:
  **Supersedes the 19:47 refusal after failed arbitration.** A confirmed token or
  process-identity mismatch proves the original owner is gone, so the successor
  adopts even if the replacement cannot complete its own empty handover. It retains
  the recovered masters while IPC binding waits for that replacement to release the
  pathname; normal replacements still exit through bounded arbitration.
- 2026-08-14T20:31-0700 `crates/triaged/src/{handover,ipc}.rs`: Replacement
  arbitration now distinguishes an empty launchd respawn from a successor that
  already owns sessions, refusing the latter to prevent overlapping destructive
  readers. Indeterminate token responses fall back to the Phase 1 process-birth
  identity on the same connection, identity-less legacy recovery checks whether
  any peer is reachable, and received SCM_RIGHTS descriptors are guarded by RAII
  until the complete response body arrives.
- 2026-08-15T00:26-0700 `crates/triaged/src/{handover,handover_tests,ipc,main}.rs`:
  **Supersedes the 20:31 refusal model.** Recovery now transfers and merges every
  reachable owner before readers start. A lineage token survives clean successor
  hops, with TCP-listener, process-birth, and socket-file identities as compatibility
  fallbacks, so the newest committed snapshot replaces stale sessions without
  conflating an independent respawn. Descriptor receipt arms shutdown deferral before
  `recvmsg`; teardown waits for process EOF rather than the pre-exit 0x02 byte; socket
  claiming serializes and identity-checks the stale-node removal; and Phase 2 again
  has a 60-second timeout now that late successors recover through the current owner.
  When 253 sessions consume Linux's full SCM_RIGHTS allowance, the listener stays
  with the old daemon and the successor rebinds it after teardown instead of failing
  the entire session transfer.
- 2026-08-15T01:19-0700 `crates/triaged/src/{handover,handover_tests,ipc,main,service,session}.rs`:
  **Supersedes the 00:26 snapshot replacement and descriptor-ceiling behavior.**
  Recovery snapshots are additive because bounded actor extraction can omit a live
  session. Children carry PID plus process birth time, so repeated recovery passes
  replace the same master without trusting a reused PID or duplicating a session after
  its display ID is renamed. Renamed sessions receive distinct log paths, adopted
  numeric IDs advance the allocator, optional snippet seeding runs off the IPC startup
  path, and TCP bind contention is retried without exiting the sole PTY owner. Handover
  state is sent before descriptors, then SCM_RIGHTS descriptors are sent in portable
  64-FD chunks; the receiver raises its soft descriptor limit and accepts transfers
  larger than one kernel control message. macOS and Linux liveness now reject PID
  reuse and zombies, legacy 0x02 waits for peer teardown, and systemd restarts after a
  successful handover as well as a failure.
- 2026-08-15T01:49-0700 `crates/triaged/src/{handover,handover_tests,ipc,session}.rs`:
  **Supersedes the 01:19 metadata-first framing.** The first sendmsg now carries
  the complete JSON state and up to 64 descriptors, preserving rollback to the
  prior one-message receiver. Lineage-capable successors acknowledge all chunks
  with 0x04 before 0x01; a legacy successor may commit only when the complete
  transfer fits in its first message. If a sender dies between later chunks, the
  mapped descriptor prefix and matching state prefix remain protected and socket
  arbitration recovers the current owner before readers start. File-limit growth
  counts descriptors already open, process identity is captured while a newly
  spawned child is still unreaped, and adopted children are stopped by closing the
  PTY rather than a check-then-SIGKILL race on a reusable PID. The public
  `recv_fds` and `complete_handover_adoption` signatures remain compatible.

- 2026-08-15T06:49-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/ipc.rs` — Added negotiated metadata-first `HandoverV2`
  framing. New peers receive and parse the complete state before any SCM_RIGHTS
  message can install descriptors; older peers remain reachable through a fresh
  legacy connection. Descriptor capacity is raised and verified before either the
  initial or recovery request is sent.
- 2026-08-15T06:49-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/session.rs` — Restored deterministic adopted-session shutdown
  with `TIOCSIG` through a duplicated PTY master. Kernel resolution through the
  terminal avoids the process-birth-check/`kill(2)` PID-reuse window, while the
  adopted-child test now verifies the original process identity disappears.
- 2026-08-15T06:49-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/session.rs`, `crates/triaged/src/handover_tests.rs` — Recovery
  renames reserve log destinations with `create_new`, skip occupied file names,
  and avoid replacing a different manager session that happens to have the same
  display ID. Token-authenticated handovers without a supported process identity
  now use socket reachability instead of waiting forever on an absent owner.
- 2026-08-15T06:49-0700 `VERSION`, `Cargo.toml`, `Cargo.lock`,
  `flutter/triage_client/pubspec.yaml` — Raised the workspace to 0.3.0 with
  `scripts/bump-version.sh`; the wire/session structs gained required public fields,
  so publishing the change as another 0.2.x release would misstate source
  compatibility.

- 2026-08-15T07:24-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/session.rs` — Made adopted PTY readers cancellable and added
  a Linux/Android pidfd signal target for the serialized shell process. Apple and
  BSD builds retain PTY-bound signaling, repeated across a foreground job handoff;
  all supported paths cancel the reader so the actor can close every master copy.
- 2026-08-15T07:24-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/ipc.rs` — Restored the public single-message
  `send_fds`/`recv_fds` contract and moved daemon-only chunking behind
  `send_handover_fds`. Handover state and descriptors are now committed to the
  inherited globals before the fallible descriptor-readiness acknowledgement.
- 2026-08-15T07:24-0700 `crates/triaged/src/handover_tests.rs` — Added public FD
  helper, readiness-write failure, and foreground-job shutdown regressions. The
  zero-downtime test now proves both the adopted shell and a separate foreground
  process group disappear after explicit shutdown.

- 2026-08-15T08:53-0700 `crates/triaged/src/handover.rs` — Legacy FD frames
  now attach SCM_RIGHTS only to the four-byte length prefix, then complete any
  short prefix write and the JSON body with `write_all`. The receiver likewise
  completes a short prefix after extracting ancillary descriptors, so stream
  backpressure cannot turn a healthy large state document into an aborted handover.
- 2026-08-15T08:53-0700 `crates/triaged/src/handover.rs` — Recovery snapshots from
  the same owner are compacted immediately by session identity: duplicate listener
  and PTY descriptors are replaced and closed, earlier partial-only sessions stay
  in the union, and definitively dead process/PTY entries are pruned. Retries no
  longer retain one full duplicate set every 250 milliseconds.
- 2026-08-15T08:53-0700 `crates/triaged/src/ipc.rs`,
  `crates/triaged/src/handover.rs` — A committed peer that exceeds the teardown
  grace is terminated through its authenticated process identity. Linux uses a
  checked pidfd and macOS uses the kernel audit token captured from
  `LOCAL_PEERTOKEN`; the successor still waits for the committed connection to
  close before starting readers.
- 2026-08-15T08:53-0700 `crates/triaged/src/handover_tests.rs` — The adopted
  foreground job now ignores SIGHUP, and new tests pin duplicate-snapshot
  compaction plus timeout-triggered committed-peer termination.
- 2026-08-15T09:13-0700 `crates/triaged/src/session.rs`,
  `crates/triaged/src/main.rs` — Post-commit session adoption now keeps the
  transferred PTY descriptor idle while attempting initialization on a duplicate.
  Failed and later sessions stay retained in the manager and retry with bounded
  backoff; shutdown adoption protection remains armed until every retained session
  is installed.
- 2026-08-15T09:13-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/handover_tests.rs` — Both handover metadata receivers reject
  frames above 16 MiB before allocating. The failure regression now proves the
  failed descriptor and the queued descriptor remain open, and the framing
  regression exercises both metadata-only and descriptor-bearing receivers.
- 2026-08-15T09:26-0700 `crates/triaged/src/session.rs`,
  `crates/triaged/src/main.rs` — Unresolved adoption now includes both queued and
  in-flight retries. It keeps shutdown protection armed and makes
  `begin_handover` return busy until every inherited actor is installed, so a
  second handover cannot omit the retained PTYs. Adopted readers wait behind a
  startup gate until the worker thread exists, preventing an unsuccessful setup
  from consuming output.
- 2026-08-15T09:26-0700 `crates/triaged/src/session.rs` — A retry-thread creation
  failure falls back to the already-running startup thread instead of parking the
  only PTY copies indefinitely. Failed explicit session termination now restores
  the live manager entry and manifest; the actor loop stays active rather than
  treating a failed kill as completed shutdown.
- 2026-08-15T09:26-0700 `crates/triaged/src/handover.rs` — Linux/Android without a
  checked pidfd and Unix targets without a PTY-safe termination primitive return
  an unsupported error instead of reporting that an adopted process was killed.
- 2026-08-15T11:47-0700 `crates/triaged/src/session.rs`,
  `crates/triaged/src/main.rs`, `crates/triaged/tests/pty_child_exec.rs` — Session
  children now pass through an internal exec shim that resets the daemon's ignored
  TTIN/TTOU dispositions before the configured program starts. The integration
  test begins with both dispositions ignored and verifies that the exec target sees
  `SIG_DFL`.
- 2026-08-15T11:47-0700 `crates/triaged/src/session.rs`,
  `crates/triaged/src/shutdown.rs` — Pending-adoption IDs block restore and explicit
  shutdown while their live PTYs lack actors. Session shutdown validates the
  removal manifest before termination, keeps the live actor and manifest unchanged
  on termination failure, and commits removal only after termination succeeds.
  Closely spaced stop signals retain the normal three-second coalescing window while
  inherited descriptors are being published.
- 2026-08-15T11:47-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/handover_tests.rs` — Tokenless recovery now treats Darwin's
  zero foreground process group as a stale PTY, while preserving genuinely
  indeterminate non-EIO errors. Retained-adoption tests also pin restore/shutdown
  refusal until an actor owns the descriptor.
- 2026-08-15T13:35-0700 `crates/triaged/src/session.rs`,
  `crates/triaged/src/handover.rs`, `crates/triaged/src/main.rs` — Restore and
  shutdown now hold one per-session lifecycle slot through all off-lock work and
  persistence. Successful adopted-process termination no longer reports failure
  when reader cancellation fails. Pending IDs reserve allocator slots immediately,
  unresolved adoption defers orphan-log purge, shutdown temp manifests are unique
  per session, V2 reserves only its declared descriptor count, and cold Unix starts
  again fail synchronously when the configured TCP address cannot bind.
- 2026-08-17T07:21-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/ipc.rs`, `crates/triaged/src/main.rs`,
  `crates/triaged/src/session.rs`, `crates/triaged/src/shutdown.rs` — Addressed
  CI lint warnings and completed max-effort review loop:
  - Eliminated Linux-specific `needless_return` statements in `ipc.rs`.
  - Replaced raw `.expect()` invocations in non-test paths with error propagation.
  - Handled poisoned mutex states on handover and session globals (`INHERITED_STATE`,
    `INHERITED_FDS`, `HANDOVER_STREAM`, `RECOVERED_HANDOVERS`, `PHASE1_COMPLETED_AT`).
  - Guaranteed `cmsghdr` alignment for `SCM_RIGHTS` control buffers using `Vec<usize>`
    and added saturating arithmetic on truncated control message lengths.
  - Released sessions mutex before joining dead actor threads during live-to-historical demotion.
  - Reaped successor child processes during emergency shutdown rescues even if kill fails.
  - Closed unconsumed file descriptors when compacting additive recovery snapshots in `handover.rs`.
  - Cleared `has_tcp_listener` in inherited state upon TCP listener adoption.
  - Simplified and deduplicated pending adoption ID maintenance and match arms.
- 2026-08-17T07:28-0700 `.github/workflows/antigravity-review.yml`,
  `scripts/antigravity_review.py`, `crates/triaged/src/handover.rs` — Added
  Antigravity automated code review workflow powered by Gemini 3.7 Flash,
  replacing the legacy Junie review setup. The Python runner fetches PR diffs,
  excludes generated files, checks `AGENTS.md` and `GEMINI.md` conventions,
  and updates structured review comments in-place. Also increased Linux PTY
  foreground process group termination polling in `AdoptedSignalTarget::terminate`
  with early-exit checks to prevent spurious `WouldBlock` errors under CI runner load.

## Decisions

- 2026-08-13T19:55-0700 Ignore `SIGTTOU`/`SIGTTIN` rather than `setsid()` at
  startup. `setsid` fails outright when the caller is already a process-group
  leader, and detaching the controlling terminal is a bigger behavioural change
  than the problem requires. Ignoring the two signals is unconditional, cannot
  fail meaningfully, and removes the entire failure class. It is also exactly what
  three lldb rescues did by hand on 2026-08-13, so it is known to work on the real
  wedge.
- 2026-08-13T19:55-0700 `setsid` in the child for git, even though the daemon now
  ignores those signals for itself. SIG_IGN dispositions do survive `exec`, so the
  child would mostly be covered, but a child that resets its dispositions, or any
  other job-control path, reopens the hole. Removing the controlling terminal
  closes it structurally instead of by inheritance.
- 2026-08-13T19:55-0700 Did **not** bound `recv_actor_result` with a timeout.
  Tempting, since the wedge was a never-answering actor, but any deadline turns a
  slow-but-healthy session into a spurious error. With the lock released before the
  round-trip, a stuck actor blocks only the client writing to it, which is the
  property that actually matters.
- 2026-08-13T19:55-0700 Left SIGTERM handoff out of this branch. It is the
  remaining loss vector (`launchctl bootout` SIGTERMs the owner and its death
  closes every master), but Phase 2 takes 10-15s (session deserialize plus
  summarizer model load), which does not fit launchd's default grace period.
  Doing it properly means raising `ExitTimeOut` in the plist, or moving the masters
  into a keeper process that outlives daemon restarts. That is an architecture
  decision and deserves its own branch.
  **Superseded 2026-08-13T20:30-0700**: asked to close it here. Both halves are
  now in: the grace period is raised *and* the daemon does something with it.
- 2026-08-13T20:30-0700 A detached successor rather than a keeper process. Both
  designs remove the daemon's exclusive hold on the masters; only the keeper also
  survives `SIGKILL`, because the descriptors never live in one process. It lost
  anyway on risk: a keeper has to be handed each master as the session is created,
  which puts a new process in the hot path of the code least safe to change without
  live testing, and it defends a case nothing in the incident history hit. Every
  real loss came from SIGTERM. The successor path reuses a protocol that has been
  exercised repeatedly instead of inventing a second one, and its worst case is
  "no worse than today". The keeper stays written up as the remaining SIGKILL gap.
- 2026-08-13T20:30-0700 Self-pipe signal handlers, not a `sigwait` thread. The
  clean-looking option is to block the signals process-wide and consume them with
  `sigwait`, but a blocked signal mask is inherited across `fork` and `exec`, so
  every session shell would start with SIGTERM blocked and be unkillable. Fixing
  that means resetting the mask in the session spawn path, the one place worth not
  touching. A handled disposition resets to the default on `exec`, so a self-pipe
  leaves children alone. The handler does nothing but `write` one byte.
- 2026-08-13T20:30-0700 Handlers installed in `main` (early), rescue thread started
  only after the manager owns its sessions. A signal in between is not lost: it
  waits in the pipe and is serviced when the thread starts. Deliberately preferred
  over dying partway through startup while holding masters freshly adopted from a
  predecessor. It does mean a stop requested during startup is honoured late.
  **Superseded 2026-08-13T21:15-0700**: the second half was wrong in both directions.
  Queueing a signal with nothing consuming it made the daemon unstoppable for the whole
  of startup, and a `service stop` racing a start could not even land its
  `DisableShutdownRescue` (the IPC socket is not bound yet). The thread now starts right
  after logging init and `arm_rescue` publishes the manager separately; before it is
  armed, a signal exits, which is what the default disposition would have done anyway.
- 2026-08-13T20:30-0700 A failed rescue keeps the daemon alive rather than exiting.
  Exiting guarantees the loss; staying up keeps the sessions and leaves a human able
  to intervene. The obvious objection, a daemon that ignores SIGTERM, is answered
  by the second signal exiting immediately, and by the three ways to ask for a plain
  stop (`service stop`, `service uninstall`, `TRIAGE_NO_RESCUE=1`). Those three are
  smoke-tested; the second-signal path is not, since reaching it needs an induced
  rescue failure. See Verification.
- 2026-08-13T20:30-0700 SIGINT rescues too. Ctrl-C usually means "stop now", but on
  a daemon holding dozens of live agent sessions it means "destroy all of them",
  which is the failure this module exists to prevent.
- 2026-08-13T20:30-0700 Handlers are installed for daemon invocations only. A
  `triaged service <action>` process has no rescue thread to consume the pipe, so a
  handler there would catch Ctrl-C, queue it, and never act on it: an
  un-interruptible CLI.
- 2026-08-13T21:15-0700 The operator-requested stop suppresses the rescue for a
  bounded window (120s) rather than latching. `service stop` disables the rescue
  and *then* asks the supervisor to stop the job, so a latch plus a stop that fails
  (no plist, a `launchctl` error, an aborted uninstall) would leave a running
  daemon permanently unable to save its sessions, and the next logout would destroy
  them silently. Found by review; it is the failure this branch exists to prevent,
  re-introduced through the escape hatch.
- 2026-08-13T21:15-0700 Made `broadcast_event` fire-and-forget rather than moving it
  off-lock like the other round-trips. Both fix the wedge; only this one keeps event
  order. The three callers mutate lease state and then announce it, so resolving
  off-lock would let two concurrent lease changes broadcast in the opposite order to
  the mutations they describe, and a client would see a stale `LeaseChange`
  generation last. Sending under the lock keeps event order and mutation order
  identical, and costs nothing because the answer was never informative.
- 2026-08-13T21:15-0700 Accepted a widened window in `write_input`: the lease is
  authorized under the lock and the bytes reach the PTY later, so a client whose
  lease is preempted in between still gets its input through. The window is the
  actor's queue depth, which is exactly what grows when an actor is slow. Accepted
  because leases are cooperative UI arbitration rather than a security boundary, and
  because the alternative is authorizing inside the actor, which would mean teaching
  it about leases. Worth revisiting if input ever needs to be authoritative.
- 2026-08-13T21:45-0700 `serialize_active_sessions` now skips an actor that misses its
  deadline instead of aborting the whole handover. The old comment argued the opposite,
  that a half-transferred set would "silently drop the sessions we skipped", and it was
  right about the cost and wrong about the alternative: aborting keeps every session in
  a daemon that cannot hand any of them over, so the next stop signal or SIGKILL loses
  all of them instead of one. Skipping is logged at error level rather than warn,
  because a skipped session does not survive this daemon's exit.
- 2026-08-13T21:45-0700 `service install` deliberately does *not* suppress the rescue,
  even though it unloads a running job first. That unload is a restart: letting the
  rescue run carries live sessions across it (the replacement takes them, then the
  freshly loaded job hands over from the replacement), at the cost of an `install` that
  can take a minute. It prints a note saying so. Suppressing would be fast and would
  destroy every live session, which is the wrong default for this daemon.
- 2026-08-13T21:15-0700 Fixed the sizing rationale for `SHUTDOWN_RESCUE_TIMEOUT`
  rather than the value. Both the constant's doc and this devlog claimed the budget
  had to cover a ~22.6s cold start *plus* all three handshake phases, which adds up
  to more than 90s. The arithmetic is wrong, not the constant: the cold start
  happens between Phase 1 and the adoption byte, which is exactly the window
  `HANDOVER_ADOPTION_TIMEOUT` already bounds. Left as a decision because a future
  reader recomputing it from the old wording would have changed the wrong term.

- 2026-08-15T00:26-0700 Treat a committed, same-lineage recovery snapshot as
  authoritative only when it advertises the 0x03 commit protocol. Current daemons
  cannot roll back after that byte, so absences mean sessions exited; legacy daemons
  can fail after their pre-exit 0x02 and remain alive with a drained map, so an empty
  legacy snapshot is not evidence that the retained Phase 1 masters are stale.
- 2026-08-15T00:26-0700 Restore the bounded Phase 2 wait. The earlier removal avoided
  admitting a second successor but let a live wedged client hold the handover gate
  forever. The recovery path now serializes later successors, carries a stable lineage,
  and hands over whichever process currently owns it, making timeout both live and
  exclusive.
- 2026-08-15T01:19-0700 Never use absence from a recovery snapshot as a tombstone.
  **This supersedes the 00:26 authoritative-snapshot decision.** Actor extraction is
  intentionally bounded, and a successor may also continue after adopting only a
  subset. Neither snapshot can prove an omitted session exited. Retaining the union is
  loss-safe; process-birth identities prevent the retained state from later signaling
  an unrelated process after PID reuse.
- 2026-08-15T01:19-0700 Send metadata before SCM_RIGHTS chunks. A sender that dies
  while streaming the JSON has installed no descriptors in the successor; once any
  descriptor arrives, the receiver already knows its session mapping. Predecessors
  that attach descriptors to the length prefix remain readable. An older successor
  safely refuses a new chunked transfer before sending the adoption byte, so the owner
  keeps its sessions.
- 2026-08-15T01:49-0700 Preserve the legacy first frame and negotiate commitment,
  rather than changing the request enum. Old predecessors must continue accepting a
  new successor's `{"Handover":null}` request, so a new request variant cannot be the
  negotiation point. Presence of the lineage token marks a chunk-capable response;
  its successor sends 0x04 only after receiving the declared descriptor count. The
  server refuses a direct legacy 0x01 when more than 64 descriptors were sent.

- 2026-08-15T06:49-0700 Metadata-first framing is version-negotiated rather than
  replacing the old request. A current successor first asks for `HandoverV2`; an
  older daemon rejects the unknown request without transferring descriptors, after
  which the successor reconnects with `Handover`. A current daemon still accepts
  the legacy request so rolling upgrades work in either direction.
- 2026-08-15T06:49-0700 Adopted processes are signaled through the inherited PTY,
  not by serialized PID. `TIOCSIG` binds the signal target to the actual terminal
  descriptor in the kernel and therefore remains safe if the original numeric PID
  has been recycled.

- 2026-08-15T07:24-0700 Linux uses pidfd signaling instead of `TIOCSIG` for hard
  termination. Linux PTYs accept only a narrow interactive-signal set through
  `TIOCSIG`; pidfd binds SIGKILL to the opened process object and closes the same
  PID-reuse race without that restriction. A birth-identity check both before and
  after `pidfd_open` prevents an intervening reuse from changing the target.

- 2026-08-15T08:53-0700 A post-commit timeout is no longer treated like an
  ordinary pre-commit ambiguity. Once 0x03 lands, rollback is impossible and a
  wedged owner blocks all output indefinitely; terminating that exact authenticated
  process after the grace is safer than either starting competing readers or
  waiting forever.
- 2026-08-15T11:47-0700 Reset job-control signals in the forked PTY child through
  the daemon executable, not an intermediate shell. POSIX shells preserve signals
  that were ignored on entry, so `trap - TTIN TTOU` cannot reliably restore the
  default dispositions inherited from the daemon.
- 2026-08-15T11:47-0700 A shutdown error must remain retry-safe. The manager leaves
  a live actor and the existing manifest authoritative until child termination
  succeeds; a later manifest-commit error retains a historical in-memory view and
  the previous on-disk entry rather than labeling a dead actor live.
- 2026-08-15T13:35-0700 Restore and shutdown share a lifecycle exclusion keyed by
  session ID. A one-time state check cannot protect either operation because both
  release the manager lock for actor work; holding the key through rollback and
  persistence makes their manifest transitions serial without blocking unrelated
  sessions.
- 2026-08-15T13:35-0700 Descriptor headroom follows the framing contract. A legacy
  first frame can install the maximum ancillary payload immediately and therefore
  needs preflight capacity; V2 sends metadata first, so reserving its exact declared
  count is both safe and compatible with lower hard descriptor limits.

## Issues

- 2026-08-14T10:55-0700 The review found that the Phase 2 rescue probe only checked
  whether any daemon accepted at the shared IPC path. If launchd SIGKILLed the outgoing
  daemon at its 60-second cap and immediately respawned it, the replacement listener
  made the successor refuse and close the only transferred PTY masters. The probe now
  compares the Phase 1 socket identity before it connects, so a replacement listener
  cannot be mistaken for the original owner.
- 2026-08-14T13:23-0700 The first repair still had a time-of-check/time-of-use gap:
  launchd could replace the socket after its device/inode was read and before the probe
  connected. Replaced the pathname check with an active-owner IPC probe. The focused
  handover tests also shared mutable process-global stream state without a lock; they
  now serialize setup through one test mutex.
- 2026-08-14T13:26-0700 The initial active-owner probe treated a dropped handover guard
  as a dead peer. That is false after a Phase 2 timeout or failed 0x01 write: the
  original daemon aborts the swap, drops its guard, and keeps serving its session
  masters. The probe now confirms the original process identity independently of the
  guard, preventing a late successor from becoming a second reader.
- 2026-08-14T16:35-0700 A PID is not a durable daemon identity because launchd can reuse
  it after the owner dies. Replaced it with a random per-daemon token. A legacy owner
  that omits the token remains impossible to distinguish from a replacement daemon;
  that path now adopts to preserve sessions instead of refusing into certain descriptor
  loss when launchd has already killed the owner.
- 2026-08-14T18:26-0700 Review found the preceding identity-less policy was unsafe for
  the immediately preceding commit-capable daemon: it can abort before committing,
  retain its masters, and close the handover connection. The successor cannot prove
  that an identity-less listener is that owner rather than a launchd respawn. Commit-
  capable tokenless handovers therefore refuse conservatively; only pre-commit
  protocol peers keep the legacy adopt behavior. Also gated Unix-only token imports
  and probe code after review identified a Windows unused-import warning.
- 2026-08-14T18:43-0700 The conservative tokenless refusal still discarded the only
  PTY copies when launchd had already replaced a preceding commit-capable daemon.
  Capture the original peer PID from the Phase 1 Unix connection and compare it on
  the Phase 2 probe connection; unlike a pathname check, this is authenticated by
  the connected socket. A confirmed replacement also has to be displaced from the
  IPC pathname before adopting, otherwise the successor could later fail its own
  bind and close every recovered master.
- 2026-08-14T19:03-0700 Review found the initial replacement fencing step could unlink
  a different daemon that bound between probe and deletion. Removing a shared socket
  pathname cannot be made atomic with a prior connection-level identity check. The
  successor instead holds its adopted masters and retries IPC binding indefinitely;
  it can continue serving remote clients through the inherited TCP listener while a
  replacement exits or releases the pathname. Also replaced the legacy PID fallback
  with a process-birth identity so PID reuse cannot impersonate the original owner.
- 2026-08-14T19:43-0700 A connected peer can time out or close while the original
  owner is still alive, so treating any probe failure as a replacement was unsafe.
  Only an explicit identity mismatch authorizes recovery. That recovery cannot unlink
  a shared pathname: it uses the established empty-session handover protocol to make
  the confirmed replacement exit; if that bounded arbitration fails, the successor
  refuses and leaves the current owner untouched.
- 2026-08-14T19:47-0700 Keeping a recovered daemon in an unbounded IPC-bind loop
  avoids descriptor loss but leaves local clients attached to an empty replacement.
  The replacement handover is bounded and identity-triggered, so after it succeeds
  normal bind recovery is enough; after it fails, refusing is the only safe state.
- 2026-08-14T19:56-0700 A confirmed replacement is not an original owner merely
  because it cannot cooperate with the optional cleanup handover. Refusing there
  drops the successor's only PTY copies after the original has died, recreating the
  loss this repair addresses. Keep those masters and wait for the replacement's IPC
  pathname in the exceptional cleanup-failure case.
- 2026-08-14T20:31-0700 Final review found that a different daemon may already own
  the same sessions after a later handover, so identity mismatch alone is not enough
  to adopt. The cleanup handover now reports session ownership separately from
  unavailability. It also found that an accepted but ambiguous token probe can be
  resolved by the captured process-birth identity, and that `recv_fds` leaked received
  descriptors if the response body was truncated; both paths are now explicit.

- 2026-08-13T19:20-0700 Three separate `triaged --handover` invocations from a
  single `agy` session (ttys015) stopped themselves mid-swap within one hour, each
  holding every PTY. `kill -CONT` alone does not recover them: they re-stop on the
  next `tcsetattr`. `tcsetpgrp` from another session fails with `ENOTTY`, since
  POSIX only permits setting the foreground group of your *own* controlling
  terminal. What worked was `lldb --batch -p <pid> -o "expression
  (void*)signal(22, (void*)1)"` (22 = `SIGTTOU`, 1 = `SIG_IGN`) followed by
  `kill -CONT`. That rescue is what this branch makes unnecessary.
- 2026-08-13T19:47-0700 Live sessions were destroyed by `launchctl bootout` run on
  the LaunchAgent while the launchd-managed instance had just become the owner of
  all 56 masters. bootout sends SIGTERM; the owner's death SIGHUP'd every session.
  The reading that justified it ("launchd instances hold nothing") was minutes
  stale, and ownership had moved in between. Root cause of the loss was operator
  procedure, not code, but it is the strongest argument for the keeper-process
  design noted above.
- 2026-08-13T22:15-0700 Deviation from plan 000124-01 step 5: no test asserts that
  `SIGTTOU`/`SIGTTIN` are `SIG_IGN`. A test could read the disposition back with
  `sigaction`, but it would only prove `libc::signal` does what it says, since the
  property that matters (a background `tcsetattr` proceeds instead of stopping the
  process) cannot be exercised without a controlling terminal and a background process
  group, which a test harness does not have. The lock-scope half of that step was
  delivered, twice over.
- 2026-08-13T21:15-0700 Deviation from plan 000124-02 step 4: `FD_CLOEXEC` on the
  owner Unix listener was **not** added, because it would be a no-op.
  `UnixListener::bind` already returns a close-on-exec socket, as `std` sets the
  flag on every descriptor it creates. It was written into the plan (and into
  000124-01 before it) on the assumption that the `git` child holding :7777 proved
  the listeners were inheritable. It did not: the inheritable descriptors were the
  `libc::dup` copies and the ones received through `SCM_RIGHTS`, which is where the
  fix landed instead. Recorded rather than quietly dropped, because "the undone
  half" has now been carried forward twice.
- 2026-08-13T21:15-0700 Plan 000124-01 and this devlog's already-written entries were
  edited in place to remove em dashes, which AGENTS.md's append-only rule would normally
  forbid. The global
  no-em-dash rule is explicit that it overrides matching existing conventions, and
  that plan is unmerged text from this same branch, so it is not really history yet.
  The reworded title is part of the same edit; nothing substantive changed.
- 2026-08-13T21:15-0700 Two review rounds found a total of six defects in the
  rescue's own signal handling, and the pattern in them is worth keeping: every one
  was a case where the failure mode of the *safety mechanism* was the loss it exists
  to prevent. A signal burst read as operator insistence (a logout sends SIGHUP then
  SIGTERM, so the commonest rescue-worthy event exited immediately). `failed_attempts`
  never resetting, so one transient failure armed a no-attempt exit forever. Killing
  a successor that had already committed, closing the masters it now owned. An
  operator-requested stop latching, so a *failed* `service stop` disarmed the rescue
  permanently. Writing the mechanism was the easy part; the hazard is that its own
  error paths are all-or-nothing.
- 2026-08-13T19:55-0700 `cargo check` reporting `Finished` in 0.18s with no
  `Checking triaged` line looked like the edits had not been picked up. They had:
  an earlier invocation in the worktree had already compiled them successfully and
  the result was cached. Verified by grepping the new symbols in the worktree files
  and reading `git diff --stat`.

- 2026-08-13T23:45-0700 Renumbered from 000123 to 000124, and the two plans with it.
  `origin/main` gained its own `devlog/000123-fix-preserve-raw-newlines.md` (#142) while
  this branch was in review, which is the collision AGENTS.md says to resolve by
  rebasing and renumbering. The rebase itself was clean despite #142 also touching
  `session.rs`; every gate and both smoke tests were re-run against the rebased tree
  rather than assumed from the clean merge.
- 2026-08-14T07:35-0700 macOS launchd caps ExitTimeOut at 60s, silently substituting
  60 for any requested value above 60. Confirmed by loading throwaway LaunchAgents with
  values from 45 to 3000 and reading `launchctl print gui/$UID/<label> | grep "exit timeout"`.
  Because launchd escalates to SIGKILL after 60s, a long Phase 2 warm-up outlives the
  outgoing daemon. Closing the Phase 2 adoption gap (adopting transferred descriptors
  when the peer dies before the 0x01 write) makes the rescue immune to supervisor
  SIGKILL.
- 2026-08-15T00:26-0700 Max review round 1 found that several individually safe
  fallbacks did not compose: pathname absence was not proof of process death, 0x02
  preceded process exit, a different-token successor could still be the same session
  lineage, and the stale-socket removal could race another binder. Plan 000124-04's
  device/inode-only identity was therefore expanded to a wire lineage token plus
  authenticated process and socket identities. The two user-supplied findings were
  fixed in the same pass: adoption is armed before descriptor receipt, and tokenless
  snapshots use a stable socket identity rather than their changing session set.
- 2026-08-15T01:19-0700 Max review round 2 found that the recovery model still
  assumed complete snapshots, durable raw PIDs, and a one-message descriptor transfer.
  Those assumptions each produced a session-loss path: partial snapshots pruned live
  masters, a later `StartSession` could reuse an adopted ID, a delayed stop could signal
  a recycled PID, and 254 sessions exceeded SCM_RIGHTS. The first chunking regression
  failed with `EMSGSIZE` on macOS at both 253 and 128 descriptors; 64 descriptors per
  send passes after raising the successor's 256-file soft limit.
- 2026-08-15T01:49-0700 Max review round 3 found two flaws in the first chunking
  design: a killed sender made `ReceivedFds` drop a valid prefix, and an old successor
  received metadata without descriptors and could commit an unusable transfer. It
  also found that retained recovery snapshots were omitted from the file-limit
  calculation and that process-birth verification followed by raw `kill(2)` was still
  racy. The framing/readiness protocol, partial-prefix recovery, dynamic limit, and
  PTY-close shutdown above address those paths.

- 2026-08-15T06:49-0700 Max review round 4 found that the PID-safe no-op child
  killer left idle adopted shells and their reader-owned masters alive, initial FD
  capacity was raised too late, partial initial stream framing could install
  descriptors without a complete state document, and recovery renames could
  truncate an unrelated log. The first metadata-first fixture initially failed
  because it still emitted the legacy combined frame; updating it to the negotiated
  response made the intended interrupted-chunk path pass.

- 2026-08-15T07:24-0700 Max review round 5 found the Linux `TIOCSIG` contract,
  foreground-job shutdown, public FD helper asymmetry, non-Unix identity stub, and
  readiness-write ownership gap. The first cancellable-reader run surfaced a benign
  `BrokenPipe` when PTY signaling killed the child before cancellation reached its
  already-closed reader; cancellation now treats that as completed teardown.
- 2026-08-15T07:24-0700 A Linux cross-target `cargo check` could not reach Rust
  type-checking because this macOS host has the Rust target but no
  `x86_64-linux-gnu-gcc`; `ring` and `zstd-sys` failed in their C build scripts.
  The target-specific source is retained for CI validation rather than presenting
  that environmental failure as a code result.

- 2026-08-15T08:53-0700 Max review round 6 found a partial legacy stream write,
  unbounded duplicate recovery snapshots, Linux foreground jobs surviving a
  shell-only pidfd signal, and an infinite post-commit wait. The fixes use
  prefix-only ancillary framing, per-owner union compaction, PTY SIGQUIT before
  the Linux shell pidfd signal, and authenticated committed-peer termination.
- 2026-08-15T09:13-0700 Max review round 7 found that a fallible post-commit
  adoption closed the failed descriptor and every unattempted descriptor, and that
  both metadata receivers trusted an unbounded length prefix. Both were fixed. A
  separate claim that Linux `TIOCSIG` requires an `int *` was rejected against the
  upstream kernel implementation in `drivers/tty/pty.c`, which casts the ioctl
  argument directly to `int`; the existing by-value call is the Linux ABI.
- 2026-08-15T09:26-0700 Max review round 8 found that a second handover could omit
  retained sessions, the retry queue looked empty while its worker owned the PTYs,
  a reader could drain output before the actor worker existed, and thread creation
  failure left no retry path. It also found unsupported adopted-session termination
  paths reporting success. Handover gating, an unresolved-retry flag, reader startup
  gating, synchronous retry fallback, and reversible shutdown address those cases.
- 2026-08-15T11:47-0700 Max review round 9 found an ordinary SIGHUP/SIGTERM burst
  could bypass adoption publication protection, pending PTYs could be restored or
  shut down through historical placeholders, a shell stage could not undo inherited
  ignored job-control signals, and shutdown could fail after irreversibly killing a
  child. It also found Darwin's zero foreground group kept dead tokenless snapshots.
  The coalescing gate, pending-ID registry, child exec shim, transactional shutdown
  ordering, and stricter PTY liveness predicate address those cases.
- 2026-08-15T13:35-0700 Max review round 10 found a restore/shutdown manifest race,
  post-termination reader-cancel errors, pending ID/log collisions, overbroad V2
  descriptor reservation, cold-start TCP retry, and a shared shutdown temp file.
  The targeted fixes were rechecked by the same final-round reviewers; all three
  reported no remaining findings.
- 2026-08-15T13:35-0700 The first full workspace test attempt exhausted the local
  volume while linking the all-feature daemon binary (`errno=28`). Linker cleanup
  released its temporary output; the unchanged command then built and completed
  successfully, so the failure was environmental rather than a test regression.

## Verification

- `cargo fmt --all --check` clean.
- `cargo clippy --workspace --all-targets --all-features -- -D warnings` clean.
- `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps
  --locked` clean.
- `cargo test -p triaged -- --test-threads=1`: 170 passed, 0 failed, 1 ignored, plus
  11 in the binary target, on the rebased tree. All eleven tests this branch adds (six
  earlier plus five new `complete_handover_adoption` unit tests) are present and passing.
  Single-threaded per the known parallel flakiness of `session_context_*`.
- The lock-scope regression test was confirmed to actually catch the regression,
  both halves of it. Re-adding a `self.sessions()?` guard around `write_input`'s
  round-trip makes it fail with "list_sessions never returned" after its 10s
  watchdog; separately, restoring `broadcast_event`'s wait for the actor makes it
  fail with "acquire_input_lease never returned". Removing each makes it pass. A
  test for an unbounded block is worthless unless that is demonstrated, so both
  were demonstrated rather than assumed.
- **End-to-end SIGTERM rescue**, in an isolated daemon (its own `HOME`, its own
  `XDG_RUNTIME_DIR`, port 17777, summarizer off): started a session running `sh -c
  'exec sleep 900'`, sent SIGTERM to the owner, and the owner spawned a successor,
  completed all three handover phases, and exited ~1.5s later. The session's child
  process was still alive afterwards and the successor listed `session-1`. The
  swap itself took ~30ms because that daemon had no historical sessions to replay;
  a real daemon spends ~20s there, which is what the budget and `ExitTimeOut` are
  sized for.
- **Stop still means stop**, same harness, four cases: no live sessions -> plain
  exit, no replacement; `TRIAGE_NO_RESCUE=1` with a live session -> plain exit, no
  replacement; `DisableShutdownRescue` over IPC with a live session -> plain exit,
  no replacement; SIGINT with a live session -> rescued into a successor. This is
  the half worth testing hardest, because the risk this change introduces is a
  daemon that cannot be stopped. Not covered by the harness: the second-signal
  override, which only fires after a rescue has already failed and so needs an
  induced failure to reach. It is unit-tested only in the sense that
  `MIN_ATTEMPT_BUDGET`'s floor is; the path itself is untested.
- Unit tests for the rescue's decision inputs (`try_live_session_count` returning 0, a
  count, and `None` under a held lock; `handover_in_flight` around `begin_handover`),
  for the disable window expiring rather than latching, and for a signal burst being
  drained as one event rather than read as an operator insisting.
- `a_parked_session_does_not_cost_the_others_their_handover` pins the pipelining fix.
  It catches the old shape on 7 runs in 10, not 10 in 10: the bug only affects sessions
  ordered *after* the parked one, and `HashMap` iteration order is randomised per
  process. Measured rather than assumed, and stated in the test's own doc, because a
  probabilistic guard that reads as a proof is worse than one that admits it.
- 2026-08-15T00:26-0700 **Supersedes the earlier test counts for the current
  working tree:** `cargo check -p triaged --all-features --locked` and
  `cargo clippy -p triaged --all-targets --all-features --locked -- -D warnings`
  are clean. `cargo test -p triaged handover --lib --locked -- --test-threads=1`
  passes 25 handover-focused tests, including stable tokenless snapshot identity,
  cross-process lineage replacement, legacy non-pruning, process-liveness fallback,
  and the TCP-listener descriptor reservation. Full workspace gates remain to be
  rerun after the review loop reaches a stop condition.
- 2026-08-15T01:19-0700 `cargo clippy -p triaged --all-targets --all-features
  --locked -- -D warnings` is clean. `cargo test -p triaged handover --lib --locked
  -- --test-threads=1` passes 25 focused tests, including the new 254-descriptor
  chunking case, additive partial snapshots, cross-merge process identity, distinct
  recovered log paths, and allocator advancement. Full workspace gates remain for the
  final clean review head.
- 2026-08-15T01:49-0700 `cargo check -p triaged --all-features --locked` and
  `cargo clippy -p triaged --all-targets --all-features --locked -- -D warnings`
  are clean. The focused handover suite passes 26 tests, adding a killed-between-
  chunks case that retains all 64 mapped descriptors and an assertion that the first
  recvmsg remains legacy-compatible. Full workspace gates remain for the final clean
  review head.
- 2026-08-15T06:49-0700 `cargo check -p triaged --all-features --locked` and
  `cargo clippy -p triaged --all-targets --all-features --locked -- -D warnings`
  are clean. The focused handover suite passes 27 tests, including metadata-first
  partial transfer, unsupported process-identity arbitration, non-overwriting log
  collision recovery, and an end assertion that explicit adopted-session shutdown
  removes the captured process identity. Full workspace gates remain for the final
  clean review head.
- 2026-08-15T07:24-0700 `cargo clippy -p triaged --all-targets --all-features
  --locked -- -D warnings` is clean. The public 65-descriptor round trip, a fully
  received transfer whose readiness write hits a closed peer, and the adopted
  shell/foreground-job shutdown regression each pass independently on macOS.
- 2026-08-15T08:53-0700 Formatter, triaged all-target/all-feature clippy with
  warnings denied, and `git diff --check` are clean. The focused handover suite
  passes 31 tests, including a SIGHUP-ignoring foreground job, immediate duplicate
  descriptor compaction, and a committed peer that remains connected past its
  teardown deadline.
- 2026-08-15T09:13-0700 Formatter and triaged all-target/all-feature clippy with
  warnings denied are clean. The focused handover suite passes 32 tests, including
  retained post-commit adoption failures and both oversized metadata receive paths.
- 2026-08-15T09:26-0700 Formatter, triaged all-feature check and all-target clippy
  with warnings denied, `git diff --check`, and the version synchronization check
  are clean. The focused handover suite remains 32/32 after unresolved-adoption
  gating, reader startup gating, retry fallback, and reversible shutdown.
- 2026-08-15T11:47-0700 Formatter, triaged all-feature check and all-target clippy
  with warnings denied, and `git diff --check` are clean. The handover-focused suite
  passes 34/34 after pending-ID operation guards and zero-foreground-group
  compaction. The shutdown manifest preflight regression passes, and the new PTY
  child integration target passes 2/2 while verifying ignored TTIN/TTOU become
  default dispositions across the internal exec shim.
- 2026-08-15T13:35-0700 Final gates are clean: workspace all-feature check,
  workspace all-target/all-feature clippy with warnings denied, workspace
  all-feature rustdoc with warnings denied, formatter, version synchronization,
  and `git diff --check`. The all-feature workspace suite passes: triaged library
  192 passed and 1 model-download test ignored, triaged binary 11 passed, PTY child
  integration 2 passed, and every other workspace unit/integration/doc-test target
  passed. The final focused handover suite passes 35/35.

## Commits

- de409d8 fix(triaged): stop job control and the sessions lock from wedging a handover
- fdde81d fix(triaged): hand live sessions to a successor instead of dying on SIGTERM
- f98341b fix(triaged): harden handover ownership recovery
- 5408384 fix(triaged): address review findings across handover, IPC, and session cleanup
- HEAD ci: add Antigravity automated code review workflow and harden Linux PTY termination

(Both hashes changed when the branch was rebased onto `origin/main` at
2026-08-13T23:45-0700; recorded by position rather than by a hash that a further
rebase would invalidate again.)

## Next Steps

- The keeper process, which is the only remaining answer to `SIGKILL`: a small
  process handed a `dup` of each master as its session is created, so the
  descriptors never live in the daemon alone and no signal to the daemon can close
  them. Costs a deposit/reclaim protocol, registration on the session-create path,
  and a reaper for entries whose child has exited. Worth doing only if a SIGKILL
  loss actually happens: **Superseded 2026-08-14T07:35-0700**: launchd caps ExitTimeOut
  at 60s rather than 150s, but Phase 2 adopt-on-dead-peer ensures sessions survive
  launchd's SIGKILL regardless. A keeper remains relevant only for a SIGKILL of the
  daemon outside a handover.
- Consider making `--handover` refuse to run when it has a controlling terminal
  unless forced, so the trap is unreachable rather than merely survivable.
- `recv_actor_result` is still unbounded everywhere except
  `serialize_active_sessions`. That is deliberate (a deadline turns a slow-but-healthy
  session into a spurious error), and with every round-trip now off-lock a stuck actor
  blocks only its own client. Revisit only if a caller appears that cannot tolerate
  waiting on one session forever.
