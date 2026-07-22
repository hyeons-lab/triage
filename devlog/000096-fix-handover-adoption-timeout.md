# 000096 — fix/handover-adoption-timeout

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch fix/handover-adoption-timeout

## Intent

A routine "rebuild the daemon and restart it via handover" failed:

```
Error: writing adoption sync byte (0x01) to old daemon
Caused by: Broken pipe (os error 32)
```

Make handover actually work instead of falling back to `launchctl kickstart -k`,
which kills every live PTY session — the exact outcome handover exists to avoid.

## What Changed

- 2026-07-19T18:30-0700 `crates/triaged/src/handover.rs` — named the three
  handover deadlines (`HANDOVER_TRANSFER_TIMEOUT` 10s Phase 1,
  `HANDOVER_ADOPTION_TIMEOUT` 60s Phase 2 (was 5s), `HANDOVER_TEARDOWN_TIMEOUT`
  10s Phase 3 (was 5s)), so the protocol's whole timing contract reads from one
  place. Added `PHASE1_COMPLETED_AT` + a `gap_ms` field on the Phase-2 log line:
  that gap is what decides whether a handover succeeds, and nothing was
  recording it.
- 2026-07-19T18:30-0700 `crates/triaged/src/ipc.rs` — Phase-2 wait uses the
  shared 60s constant.
- 2026-07-19T18:52-0700 `crates/triaged/src/session.rs`, `ipc.rs` — single-flight
  handover guard. Final state: the flag lives on `SessionManager`
  (`handover_in_flight`) and is claimed via `begin_handover()`, which returns a
  `HandoverGuard` that clears it on drop; `handle_handover_server` acquires it.
  It began as an ipc-local `HandoverInFlightGuard` static and moved onto the
  manager so it also gates `start_session` (see Decisions).
- 2026-07-19T18:57-0700 `crates/triaged/src/ipc.rs` — the Phase-3 `0x02` write is
  now best-effort (warn, still `process::exit(0)`) instead of `?`.
- 2026-07-19T19:00-0700 `crates/triaged/src/main.rs` — comment only, recording
  why `SessionManager::default()` must stay *above* the Phase-2 sync.
- 2026-07-20T12:31-0700 `crates/triaged/build.rs` — a missing `flutter` on PATH
  when the bundle is missing or stale is now a `panic!` instead of a
  `cargo:warning` that fell through to the `web_fallback/` placeholder.
- 2026-07-20T12:32-0700 `.github/workflows/ci.yml` — `TRIAGE_SKIP_FLUTTER_BUILD:
  "1"` scoped to the `check` and `test` jobs (not the workflow), so a future job
  that needs the real client can't silently inherit the placeholder. Those Rust
  jobs never install Flutter and would otherwise hit the new hard error; release
  packaging is unaffected because it stages a prebuilt bundle into `dist/`, which
  the build script prefers.

- 2026-07-20T14:30-0700 `crates/triaged/build.rs`, `AGENTS.md`, `.github/workflows/ci.yml`
  — the uncommitted missing-SDK hard-fail. Kept the hard failure for both a
  missing *and* a stale bundle when Flutter is absent (an out-of-date client must
  be corrected before building, per the project owner). Updated AGENTS.md to
  document the new contract (it still described warn-and-fallback). Moved
  `TRIAGE_SKIP_FLUTTER_BUILD` from workflow scope to the `check` and `test` jobs
  so a future job that needs the real client can't silently inherit the
  placeholder.
- 2026-07-20T14:30-0700 `crates/triaged/src/handover.rs`, `main.rs` — post-commit
  error handling. Moved `set_read_timeout` ahead of the 0x01 write so the last
  fallible call no longer sits past the point of no return, and made
  `adopt_sessions` failures log-and-continue rather than exit the successor
  (exiting closed every already-adopted master, orphaning sessions that adopted
  cleanly).
- 2026-07-20T14:30-0700 `handover.rs`, `ipc.rs`, `session.rs`, `main.rs` — the
  three protocol-level findings (see Decisions and Issues below): a teardown-commit
  byte to end the EOF-adopt split-brain, a distinguishable busy refusal so a
  concurrent launch retries instead of crash-looping, and refusing new sessions
  while a handover is in flight.
- 2026-07-20T19:50-0700 `crates/triaged/src/session.rs` — `restore_session` gained
  the same authoritative handover gate as `start_session`; it also inserts a Live
  session, so without it the gate was only half-closed.
- 2026-07-21T09:15-0700 `crates/triaged/src/handover.rs`, `main.rs`,
  `handover_tests.rs` — a Phase-3 EOF now probes whether the peer is still
  listening (`peer_still_listening`) and `TeardownSignal::Eof` carries
  `peer_alive`. A daemon that *aborted* closes the connection and keeps serving
  (refuse), but one that was **killed** closes it by dying — and refusing there
  destroyed sessions that were still perfectly alive, since the successor held
  the only remaining handles. Reachable via the documented `launchctl kickstart
  -k` on a stuck swap. A dead peer now always adopts.
- 2026-07-21T09:40-0700 `crates/triaged/src/session.rs` — `restore_session`'s new
  handover gate rolls the entry back to `Historical` before bailing, matching the
  spawn- and snapshot-failure paths beside it. Without the rollback the entry
  stuck as `Restoring` forever, and since an aborted handover leaves this daemon
  serving, the "try again once the swap completes" it returns could never come
  true — the session was unusable until a restart.
- 2026-07-21T09:40-0700 `crates/triaged/src/ipc.rs`, `session.rs` — descriptors
  staged for an SCM_RIGHTS send are now closed by `Drop` (`StagedFds`) rather than
  a trailing loop, and `serialize_active_sessions` closes what it duplicated when
  it aborts. Both previously leaked on paths between staging and sending (the TCP
  `dup`, response serialization, an actor that stopped answering). This used to be
  harmless because the process was about to exit; now that an aborted handover
  leaves the daemon running and retryable, the leaks accumulate.
- 2026-07-21T10:05-0700 `crates/triaged/src/ipc.rs`, `main.rs` — closed the two
  remaining swap races, both created by the commit byte releasing the successor
  *before* the outgoing daemon finishes teardown:
  - The successor could adopt and then die at `bind_owner_socket`, which bailed
    while the predecessor still held the socket — taking every adopted session
    with it. `IpcConfig::bind_grace` (only set when sessions were inherited) now
    waits the predecessor out for `HANDOVER_TEARDOWN_TIMEOUT`; the bind split into
    `try_bind_owner_socket`, whose `Ok(None)` marks the one retryable condition. A
    fresh start keeps a zero grace, so a genuinely occupied socket still fails
    immediately.
  - The outgoing daemon now unlinks the socket only while it is still the one it
    bound, matched on `(dev, ino)` recorded at bind time (`unlink_own_socket`). It
    was released before that unlink, so a fast successor could bind and then have
    its *live* socket deleted by its predecessor, leaving it serving where no
    client could reach it. Skipping the unlink entirely was the first attempt and
    was worse in a different way: a file left behind on every swap widens the
    window where two concurrent starters both remove it and both bind. Checking
    identity keeps the cleanup and touches no one else's socket.
- 2026-07-21T10:35-0700 `crates/triaged/src/ipc.rs` — inside a bind grace, *any*
  bind failure retries rather than propagating. The caller that sets a grace holds
  adopted masters, so returning exits the process and loses every one of them; the
  races are real and benign (a predecessor on an older build still unlinks, so our
  `remove_file` can lose to it and report `NotFound`; a bind can lose to another
  launch and report `EADDRINUSE`). Zero grace still propagates immediately. Added
  tests for both grace paths — the zero-grace default is the only thing keeping a
  fresh start from waiting instead of failing loudly, and nothing covered it.
- 2026-07-21T10:50-0700 `crates/triaged/src/handover.rs` — noted at
  `AdoptedMasterPty` why it deliberately has no `Drop`. This branch briefly added
  one to plug the same leak `UnadoptedFds` covers; it was removed on rebase. The
  assumption behind it — that a handover's `process::exit` skips the `Drop` — is
  false: `SessionActor::detach` drops the actor's command sender, `run_actor`
  unwinds its state, and the close would run while the session is live. Closing
  unclaimed descriptors in `adopt_sessions` is the narrower fix and covers the
  in-flight fd, which the `Drop` did not.
- 2026-07-20T19:50-0700 `crates/triaged/src/handover.rs`, `handover_tests.rs` —
  a Phase-3 read **timeout** and a **closed socket** were both collapsed to
  `None` and both resolved to `Refuse`. They are opposites: a timeout leaves the
  peer connected and able to commit, and the outgoing daemon's detach is gated
  only on its own commit-byte write succeeding — never on the successor still
  being alive. So refusing on a slow peer orphaned every session the moment that
  write landed late. Introduced `TeardownSignal { Byte, Eof, Timeout }`;
  `Timeout` now always adopts, `Eof` refuses only from a committing peer.
  `teardown_outcome` also matches the named byte constants instead of literals.
- 2026-07-20T19:50-0700 `crates/triaged/src/session.rs` — the `start_session`
  handover gate was a TOCTOU: it checked the flag, then forked a PTY (tens of
  ms), then inserted. A handover starting in that window snapshotted without the
  session and `detach_all_live_sessions` dropped it. The authoritative check now
  runs under the same `sessions` lock `serialize_active_sessions` holds for its
  whole snapshot, so the session is either transferred or refused.
- 2026-07-20T19:50-0700 `crates/triaged/src/session.rs` — `adopt_sessions` now
  owns its inherited descriptors through `PendingFds`, which closes any it never
  adopted. A bare `Vec<RawFd>` closes nothing on drop, so a partial adoption
  leaked fds and left children attached to a PTY nobody drains.
- 2026-07-20T19:50-0700 `crates/triaged/src/main.rs` — the busy-retry loop no
  longer treats an absent socket as terminal once a swap is known to be in
  flight (the outgoing daemon unlinks the socket before exit, while the winner
  binds much later); and the `Refuse` path now returns an `Err` instead of
  `process::exit`, so a manual deploy still gets a non-zero status *and* main's
  `WorkerGuard` drops — `process::exit` skipped it, and that guard is the only
  thing that flushes the non-blocking tracing appender, so the message explaining
  the refusal would likely never have reached the log. launchd respawns either
  way (`KeepAlive: true`, not `SuccessfulExit`).
- 2026-07-20T19:50-0700 `crates/triaged/src/ipc.rs`, `handover.rs`, `main.rs` —
  documentation accuracy: `handle_handover_server`'s doc comment described the
  deleted `HANDOVER_IN_FLIGHT` static, and two comments claimed the teardown
  handshake ends the double-reader window. It does not — `detach()` only drops
  join handles, so the outgoing daemon reads until `process::exit`. Corrected
  and recorded as a follow-up.

## Code Review (2026-07-21)

- 2026-07-21T10:09-0700 `crates/triaged/src/session.rs` — PR #113 review: making
  `adopt_sessions` failures log-and-continue (above) leaked file descriptors.
  `adopt_sessions` takes `Vec<RawFd>`, a bare integer with no ownership, and
  removes one per session as it goes. While a failure propagated with `?` into a
  `process::exit`, the OS reclaimed whatever was left; now that the daemon
  survives, every fd the loop had taken but not yet attached to a session — plus
  everything still queued behind it — stayed open for the life of the process.
  The surplus case leaked on the *success* path too: more inherited fds than the
  state lists and the extras were simply dropped.

  Fixed with an RAII guard (`UnadoptedFds`) that owns the queue and closes
  whatever it still holds on drop. Ownership transfers only after
  `sessions.insert`, so the fd in flight is covered by every early return between
  taking it and the session going live — including the two actor-thread spawns,
  which can fail with `EAGAIN` under the fd pressure a leak would itself create.
  Chose the guard over `Vec<OwnedFd>`/`OwnedFd` in `AdoptedMasterPty` because the
  latter changes when a *live* session's master closes, which is a bigger change
  to the adopted-PTY lifetime than this bug warrants.

- 2026-07-21T10:34-0700 `crates/triaged/src/handover_tests.rs` — the first version
  of these tests passed locally and failed on CI, and both of the obvious ways to
  ask "is this fd closed?" are wrong inside a parallel test binary.
  `fcntl(F_GETFD)` cannot separate "never closed" from "closed, and the number
  already reissued"; descriptors are recycled immediately, so a correctly-closed
  fd reads as open. Switching to a pipe and watching for EOF was worse — other
  tests in the binary `start_session`, and the children they fork inherit a copy
  of the write end, so the read end reports a live writer regardless of what this
  process did. Settled on identifying the descriptor: a fresh temp file has an
  inode nothing else shares, so "gone" and "now points somewhere else" both mean
  closed, independent of other threads and forked children. Confirmed by running
  the full suite (where the parallelism actually bites) seven times.

## Decisions

- 2026-07-19T18:20-0700 Raise the Phase-2 bound rather than tune it — a
  successor that *dies* closes the socket and the outgoing daemon's read returns
  EOF immediately, so the deadline only ever fires for a successor that is alive
  but slow. Aborting that handover is strictly worse than waiting. The bound
  survives only to stop a wedged successor pinning the outgoing daemon forever.
- 2026-07-19T18:35-0700 Instrument before choosing a value. `Summarizer::spawn`
  and `spawn_poller` only spawn threads, so the initial "the LLM model load
  blocks startup" hypothesis was wrong; measuring beat guessing.
- 2026-07-19T18:52-0700 Refuse concurrent handovers rather than queue them. A
  refused successor falls back to a fresh start and then fails to bind, which is
  loud and harmless; queueing would mean two successors holding dups of the same
  masters.
- 2026-07-19T18:57-0700 Past `detach_all_live_sessions()` the daemon must exit
  unconditionally. The sessions are already gone from the process, so failing to
  deliver `0x02` must not abort the exit.
- 2026-07-19T19:01-0700 On a Phase-3 EOF the successor adopts rather than
  refuses. EOF cannot distinguish "aborted before detaching" (adopting adds a
  second destructive reader) from "detached, `0x02` lost" (refusing strands every
  session). Resolved toward adopting: the first is corruption on a daemon that
  can be restarted, the second is unrecoverable loss.
- 2026-07-20T14:30-0700 End the EOF-adopt split-brain with a `0x03` teardown-commit
  byte, gated on a backward-compatible `HandoverState.sends_teardown_commit` flag
  (`#[serde(default)]`). The outgoing daemon sends `0x03` *before* detaching and
  detaches only if that byte landed — the atomicity invariant `detach ⟺
  commit-sent`. The successor, knowing the peer commits, reads a pre-commit EOF as
  "aborted, sessions kept" and refuses rather than adopting a second destructive
  reader. An older daemon sets no flag, so the successor keeps the legacy
  adopt-on-EOF behavior for it — no regression across versions. The adopt/refuse
  contract is the pure `teardown_outcome` fn so it is unit-tested without the
  two-process socket dance (which has no automated harness).
- 2026-07-20T14:30-0700 Refuse a concurrent handover with a distinguishable
  `WireResponse::Err("handover already in flight")` sentinel instead of dropping
  the connection. The client tells "busy, retry" from a dead peer and retries with
  backoff up to the outgoing daemon's adoption deadline, instead of falling back to
  a fresh start that fails to bind the still-held port and crash-loops under
  launchd `KeepAlive`.
- 2026-07-20T14:30-0700 Move the handover-in-flight flag onto `SessionManager`
  (from an ipc-local static) so it also gates `start_session`: a session created
  after the outgoing daemon snapshotted its set would not be in the transferred
  fds and would be lost on detach. Refusing loudly for the ~swap duration beats a
  silent loss. The 5s→60s widening had turned this from a <=5s window into a ~23s
  one.
- 2026-07-20T12:31-0700 A build that cannot produce the real client fails rather
  than substituting the placeholder. The placeholder makes a missing SDK a silent
  defect: the build succeeds, the daemon starts, and the only symptom is a client
  that cannot connect — surfacing far from the build that caused it, on whatever
  device someone next picks up. `TRIAGE_SKIP_FLUTTER_BUILD` stays as the
  deliberate opt-out, so the escape hatch is explicit rather than the default.

## Issues

- **The 5s Phase-2 deadline was never adequate.** `ipc.rs` gave the successor 5s
  to send `0x01`; measured gap was 22.6s, consistent across three attempts. Log
  archaeology found a June 28 handover at 8.9s — also over budget. It had been
  passing on luck.
- **The daemon logs nothing by default.** `RUST_LOG` is unset under launchd and
  `~/Library/Logs/triage/*.log` was stale since June; the real JSON log is
  `~/.local/state/triage/triaged.log`. The first two diagnosis attempts produced
  no telemetry at all.
- **Bootstrap constraint.** The 5s is compiled into the *running* daemon, so this
  fix cannot rescue the current swap — it lands via one hard restart and every
  handover after that benefits.
- **Reordered startup, then reverted it.** Review argued the timeout was a
  bandaid and that `SessionManager::default()` (the 22.6s) should move below the
  Phase-2 sync, since `restore_sessions` swallows its errors and cannot abort
  startup. Implemented it, then a follow-up review showed it was a net
  regression, which independent tracing of the startup order confirmed. Until
  the adoption byte goes out the outgoing daemon is **still fully serving**, so
  that 22.6s is warm-up, not downtime. Below the sync the same work becomes: no
  reader on the adopted masters (children block on a full PTY buffer and sessions
  freeze), no process answering clients, and a panic in log replay stranding
  every session with no daemon left. Reverted; kept the reasoning as a comment at
  the call site so it is not re-attempted.
- **Two safe changes that were unsafe together.** Making the `0x02` write
  non-fatal and making a Phase-3 EOF fatal are each defensible, but combined they
  lose every session when a daemon detaches and its `0x02` does not arrive. Only
  the pairing was wrong, which is why it survived review of each change alone.
- **Deploying the fix shipped a placeholder client (2026-07-20).** The first
  build of this branch ran without `flutter` on PATH, so `build.rs` warned and
  embedded `web_fallback/`. The warning was not read closely — absence of it in a
  truncated build log was taken as proof the real bundle was embedded — and the
  19.6 MB binary was installed over `~/.cargo/bin/triaged` and hard-restarted.
  The daemon then served a stub with no client in it, and the symptom appeared as
  "cannot connect from my phone", nowhere near the build. The previous binary was
  overwritten by the install with no backup, so the only way back was building the
  bundle and rebuilding: 37.1 MB with the client, versus 19.6 MB without. Size is
  the cheap check. This is what motivated the `build.rs` hard error above.
- **The daemon's tracing output goes nowhere reachable.** `StandardOutPath` and
  `StandardErrorPath` in the LaunchAgent have not been written since 2026-06-21,
  and a successor launched by hand with stdout/stderr redirected produced an empty
  file. There is no log-based way to watch a handover; the swap above had to be
  verified from process state (`lsof` on the PTY masters and the listener). Worth
  fixing before the next protocol change — this branch added a `gap_ms` field
  precisely so the timing could be observed, and right now nothing can read it.

- **The byte-level handshake has no automated integration coverage (2026-07-20).**
  `handover_tests.rs` exercises serialize→adopt→detach in-process at the
  `SessionManager` level; it never runs `complete_handover_adoption` /
  `handle_handover_server`, which do cross-process socket I/O and end in
  `process::exit`. The `0x03` commit protocol was therefore validated by (a) unit
  tests on the extracted `teardown_outcome` decision function covering every
  branch, and (b) three real local handovers on 2026-07-21 (see Research &
  Discoveries), which exercised the commit path and the legacy path against a live
  daemon carrying 10 sessions. That is evidence, not coverage: it is manual, it
  ran one ordering, and CI still never executes the handshake. Residual risk on #4: it
  adds no per-byte acks, so if the successor died after sending `0x01` but before
  reading a `0x03` already buffered in the socket, the outgoing daemon would have
  detached and the sessions would be lost — but a successor that dies mid-handover
  loses those sessions in the pre-change code too, so this is a strict improvement,
  not a new failure mode. A two-process handover test harness is the right
  follow-up before further protocol changes.

## Research & Discoveries

- The handover protocol is a two-phase commit. `0x01` is the point of no return:
  before it the outgoing daemon bails, skips teardown and keeps serving; after it
  there is no rollback. Everything that can abort the successor's launch must
  therefore stay above the sync.
- The 22.6s is `SessionManager::default()` → `restore_sessions` → per **historical**
  session: full log read, replay through the terminal emulator, and three
  blocking `git` subprocesses. These are dead sessions the handover does not even
  transfer.
- It grew ~9s (June) → 22.6s (July) because it scales with accumulated session
  logs. 60s buys headroom, not a permanent fix.
- Smart-start means *any* `triaged` invocation attempts a handover against the
  live daemon — including the `launchctl kickstart -k` an operator runs when a
  swap looks stuck. That is what makes the concurrent-handover race reachable
  rather than theoretical.
- 2026-07-20T12:29-0700 **The fix validated itself in production.** Landing it
  needed a hard restart, because the deadline is enforced by the *outgoing*
  daemon and the running one still had the 5s bound — the fix could not be
  deployed by the mechanism it repairs. Once it was running, the next swap went
  through as a real handover: both live shells survived, reparented to PID 1
  (adoption moves descriptors, not parentage), and the successor's listener
  carried the same kernel socket address as its predecessor's — inherited via
  `SCM_RIGHTS`, not rebound. The launchd `KeepAlive` respawn converged as
  designed, handing over from the manual successor rather than fighting it.

- 2026-07-21T11:00-0700 **The full protocol verified in production, across three
  real swaps.** The branch had until now been validated only by unit tests and
  reading; the byte-level handshake had never run outside a review argument.
  Measured on a daemon carrying 10 sessions:

  | Swap | `gap_ms` | `peer_sends_commit` | Teardown byte observed |
  | ---- | -------- | ------------------- | ---------------------- |
  | 1 (legacy → new) | 24360 | `false` | `0x02` — "reported teardown complete; adopting" |
  | 2 (new → new) | 30598 | `true` | `0x03` — "committed to teardown; adopting" |
  | 3 (new → new) | 24181 | `true` | `0x03` — "committed to teardown; adopting" |

  Every gap is 24–31s against the 5s bound this branch replaced, so all three
  would have failed before it. Both compatibility directions ran for real: swap 1
  exercised the legacy path (`sends_teardown_commit` absent → `#[serde(default)]`
  false → adopt on `0x02`), swaps 2 and 3 the commit-byte path. The TCP listener
  kept one kernel socket address (`0x5614916b74cd57db`) across the whole chain,
  proving inheritance rather than rebinding, and the `KeepAlive` respawn converged
  each time instead of fighting the manual successor.
- 2026-07-21T11:00-0700 **The best-effort `0x02` write earned itself in
  production.** Swap 3 logged `failed to send teardown sync byte (0x02); exiting
  anyway since sessions are already detached — Broken pipe`. The successor reads
  one byte, gets `0x03`, and closes; the outgoing daemon's `0x02` then lands on a
  closed socket. Before this branch that write was `?`, so the daemon would have
  returned an error *after* `detach_all_live_sessions()` — the exact drained,
  session-less-but-still-listening state described under Issues. It is also direct
  evidence that `0x02` is now unobservable to any current successor: it is kept
  only for daemons predating the commit byte.
- 2026-07-21T11:00-0700 **Session survival: 8/8 on a clean run.** Verified by
  mapping the daemon's PTY masters to their slave ttys and comparing the exact
  shell PIDs on each before and after, which is stricter than counting the
  daemon's children — the earlier method missed shells already reparented to PID 1
  by a previous handover, and undercounted the live set. All eight survived and
  reparented to PID 1, including the session this work was being driven from.

  The one-time legacy → new migration (swap 1) is a different story: it started
  with 10 live shells and ended with 8. Both losses are on that swap; every swap
  since, on the new code, has been loss-free. Cause undetermined — an idle shell
  at a prompt writes nothing, so a session log going quiet cannot distinguish
  "idle" from "dead", and no adoption error was logged (the new code logs one
  explicitly on partial failure). Recorded as suspicion against the migration off
  the pre-fix binary, not against the protocol.
- 2026-07-21T11:15-0700 **An adopted session leaks its PTY master when it ends —
  found in production, not in review.** Shutting the two stale sessions down
  removed them from the daemon (`SnapshotSession` → "not found") and released two
  of each session's three descriptors, but left exactly one open on each of their
  PTY devices (`15,6` and `15,16`); the daemon's `ptmx` fd count fell 28 → 26 for
  two sessions destroyed.

  Cause: `AdoptedMasterPty` holds a bare `RawFd` and has no `Drop`. Its reader and
  writer are `dup`s handed out as `File`s, so those close; the master itself never
  does. A natively spawned session is unaffected — `portable_pty`'s master owns its
  descriptor — so this is specific to sessions that arrived through a handover.
  That is not a narrow case: every handover re-adopts *every* session, so after one
  swap the whole set is adopted and each one that ends leaks a descriptor until the
  daemon restarts.

  This contradicts the reasoning recorded on `8124aed`, which chose `UnadoptedFds`
  over an `OwnedFd`/`Drop` on `AdoptedMasterPty` on the grounds that a `Drop` would
  "change when a *live* session's master closes". It would — and that turns out to
  be the behaviour needed: closing when the session ends is exactly right, and on
  the handover path it is harmless because the successor holds an independent
  descriptor installed by `SCM_RIGHTS`, not a share of this one. `UnadoptedFds`
  correctly covers descriptors that never reach a session; nothing covered the ones
  that did. Fixed below.
- 2026-07-21T11:00-0700 **A daemon keeps the master of a session whose shell has
  exited.** Those two dead sessions still held PTY masters afterwards, so the
  daemon reported "Adopting 10 inherited live sessions" while only 8 had shells,
  and every subsequent handover faithfully transferred all 10. Session counts in
  the log are therefore counts of *tracked* sessions, not live ones — worth
  remembering when reading a handover log as evidence.

## Next Steps

- Make the historical-session restore lazy or cheaper. It is the actual root
  cause; the gap grows on the same trajectory that breached 5s, and `gap_ms` now
  makes that trend visible.
- Make `SessionActor::detach()` join its reader threads, so the handoff becomes
  exclusive at the commit byte rather than at the outgoing daemon's
  `process::exit`. Today `detach` only drops the join handles, so both daemons
  read the same masters until that exit; the window is short but real, and it is
  the last place a handover can still split a session's output.
- Give the daemon a log sink that can actually be read. `gap_ms` and the handover
  phase lines are unobservable while tracing goes nowhere, which cost real time
  diagnosing the swap above.
- Teach the actor to tear down a half-built session. If the worker thread fails to
  spawn during adoption, the reader thread started just before it lingers (parked
  in `read`) until the child's next output, holding a dup'd master fd. Bounded and
  self-clearing, but not deterministic.
- Build a two-process handover integration test harness. The `0x03` commit
  protocol, the busy-refusal retry, and the start_session gate are all validated
  only by unit tests on extracted logic plus manual handovers; the wire sequencing
  itself is untested by CI.

## Commits

- cb8f4c0 — fix(triaged): stop the 5s adoption deadline from aborting valid handovers
- 55212d4 — fix(triaged): gate teardown on a commit byte and fail the build on a missing client
- 8124aed — fix(triaged): close handover fds that no session adopts
- HEAD — fix(triaged): close the session-loss holes a multi-round review found
