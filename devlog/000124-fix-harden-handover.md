# 000124: fix/harden-handover

**Agent:** Claude (claude-opus-5[1m]) @ triage branch fix/harden-handover
(worktree: worktrees/harden-handover)

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

## Issues

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

## Verification

- `cargo fmt --all --check` clean.
- `cargo clippy --workspace --all-targets --all-features -- -D warnings` clean.
- `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps
  --locked` clean.
- `cargo test -p triaged -- --test-threads=1`: 165 passed, 0 failed, 1 ignored, plus
  11 in the binary target, on the rebased tree. It was 167 before the rebase; #142
  removed two `session.rs` tests, which accounts for the difference exactly. All six
  tests this branch adds are present and passing. Single-threaded per the known parallel flakiness of
  `session_context_*`.
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
- **Stop still means stop**, same harness, four cases: no live sessions → plain
  exit, no replacement; `TRIAGE_NO_RESCUE=1` with a live session → plain exit, no
  replacement; `DisableShutdownRescue` over IPC with a live session → plain exit,
  no replacement; SIGINT with a live session → rescued into a successor. This is
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

## Commits

- HEAD~1 fix(triaged): stop job control and the sessions lock from wedging a handover
- HEAD fix(triaged): hand live sessions to a successor instead of dying on SIGTERM

(Both hashes changed when the branch was rebased onto `origin/main` at
2026-08-13T23:45-0700; recorded by position rather than by a hash that a further
rebase would invalidate again.)

## Next Steps

- The keeper process, which is the only remaining answer to `SIGKILL`: a small
  process handed a `dup` of each master as its session is created, so the
  descriptors never live in the daemon alone and no signal to the daemon can close
  them. Costs a deposit/reclaim protocol, registration on the session-create path,
  and a reaper for entries whose child has exited. Worth doing only if a SIGKILL
  loss actually happens: with the rescue in place, launchd escalates to SIGKILL
  only after 150s, which a rescue does not reach.
- Consider making `--handover` refuse to run when it has a controlling terminal
  unless forced, so the trap is unreachable rather than merely survivable.
- `recv_actor_result` is still unbounded everywhere except
  `serialize_active_sessions`. That is deliberate (a deadline turns a slow-but-healthy
  session into a spurious error), and with every round-trip now off-lock a stuck actor
  blocks only its own client. Revisit only if a caller appears that cannot tolerate
  waiting on one session forever.
