# 000141-01: Cut git subprocess cost out of handover adoption

## Thinking

Handover adoption is the daemon's stop-the-world window: `adopt_sessions` takes the
session-manager lock once and holds it across the whole per-session loop. Log analysis of
327 adoption windows in `~/.local/state/triage/triaged.log` shows the cost is rigidly
linear in session count at ~285ms/session, and every bucket from 3 to 33 sessions lands at
270–330ms/session. At the current 32 sessions that is a ~10s freeze; measured handover
duration is median 3.4s, p90 16.6s.

Two contributors sit inside that loop, both per-session:

1. `resolve_session_context` forks 3–4 `git` subprocesses (`rev-parse --show-toplevel`,
   `rev-parse --path-format=absolute --git-common-dir`, `branch --show-current`). Measured
   ~49ms warm and idle; far worse in an adoption burst, where the daemon forks a ~900MB,
   150-thread process ~100 times back to back.
2. `spawn_adopted_pty_runtime` reads and VT-parses each session's replay tail. Suspected
   to be the other large share, but not yet measured.

The same git resolution also runs in steady state: `apply_cwd` re-resolves on every cwd
poll (`CWD_POLL_INTERVAL` = 750ms) so a same-directory branch switch is still caught. With
many busy sessions that is a continuous fork storm, even though sessions cluster into few
directories: the live manifest has 32 sessions across only 14 distinct cwds.

Two independent fixes:

**Cache.** Memoize `resolve_session_context` by cwd behind a short TTL. Git branch is a
property of the worktree, not the session, so two sessions in one directory always resolve
identically, so coalescing them is semantically exact, not an approximation. The TTL must sit
below `CWD_POLL_INTERVAL` so branch-switch detection keeps its current 750ms granularity;
500ms does that while still collapsing an adoption burst (all resolutions land within
milliseconds of each other) and the steady-state N-sessions-one-repo case. A TTL rather
than a permanent entry also self-heals when a directory becomes or stops being a repo.
Expected effect on adoption: 32 resolutions -> 14.

**Hoist.** Caching alone still leaves ~14 resolutions under the lock. Take the git work off
the lock entirely: `adopt_one_session` installs the actor with no context, and after the
guard is dropped a background pass resolves each adopted session's context and delivers it
via a new fire-and-forget `ActorCommand::SetContext`. The actor already broadcasts context
changes to clients, so a context arriving a moment later populates the rail the same way a
branch switch does.

Rejected: restructuring `adopt_sessions` into off-lock prepare / on-lock install phases.
That would also lift the replay-tail parse off the lock, but the conflict-rename decision
must happen under the lock *before* `spawn_adopted_pty_runtime` opens the renamed log, so
the split needs three phases and opens a window where another thread can claim an id
between the rename and the insert. The handover protocol is already the most failure-prone
part of the daemon; that trade is not worth it for this change.

Because the replay-tail share is suspected but unmeasured, add per-phase timing to the
adoption loop (`prepare` vs `install` vs `context`) at debug level so the next handover
says where the remaining time goes instead of leaving it to inference.

Verification is by unit test and by the timing log. Deliberately not exercised against the
running daemon: it currently holds 32 live sessions of real work, and a handover
experiment risks them.

## Plan

1. Add a process-wide `SessionContextCache` (cwd -> (resolved, instant)) with a 500ms TTL,
   consulted by `resolve_session_context`. Keep the uncached resolution as
   `resolve_session_context_uncached` so tests can bypass the cache.
2. Add `ActorCommand::SetContext { context }`; the actor stores it and broadcasts on change,
   reusing the existing `broadcast_context_update` path.
3. `adopt_one_session`: stop calling `resolve_session_context`; install the actor with
   `context: None` and hand its `command_tx` plus resolved cwd back to `adopt_sessions`.
4. `adopt_sessions`: after the sessions guard is dropped, resolve the collected cwds on a
   background thread and send each `SetContext`.
5. Instrument the adoption loop with per-session prepare/install timings, logged as a debug
   summary per handover.
6. Tests: cache hit/expiry, that a same-cwd second resolution does not re-run git, and that
   adoption still ends with each session's context populated.
7. `cargo fmt --all`, `cargo clippy --all-targets --all-features -- -D warnings`,
   `cargo test --workspace` (with `TRIAGE_SKIP_FLUTTER_BUILD=1`).
