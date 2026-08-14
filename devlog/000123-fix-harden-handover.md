# 000123 — fix/harden-handover

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

- 2026-08-13T19:55-0700 `crates/triaged/src/main.rs` — added
  `ignore_terminal_job_control_signals`, called once at startup after help/version
  return and before any handover work. Sets `SIGTTOU` and `SIGTTIN` to `SIG_IGN`
  for the process lifetime. Handover teardown calls `tcsetattr`, which raises
  `SIGTTOU` *unconditionally* for a background process group (TOSTOP does not gate
  it), and an ignored `SIGTTOU` is what lets that call proceed instead of stopping
  us. Deliberately not `setsid`: a successor must keep serving whatever it
  inherited regardless of how it was launched, and the goal is narrower — job
  control must never freeze the owner of live PTYs.
- 2026-08-13T19:55-0700 `crates/triaged/src/session.rs` — `SessionApi::write_input`
  now resolves and authorizes the session under the sessions lock, clones the
  actor's `Sender`, drops the guard, and only then does the round-trip, via a new
  `request_write_input` free function. `SessionActor::write_input` delegates to the
  same function so there is one implementation. This is the `request_summary_rows`
  pattern already documented in this file, applied to the one caller that never
  got it.
- 2026-08-13T19:55-0700 `crates/triaged/src/session.rs` — `git_raw_output` spawns
  through a new `detach_from_terminal`, a `pre_exec` hook calling `setsid`, so a
  cwd-detection child has no controlling terminal and cannot be job-control
  stopped. Non-unix gets an empty stub.
- 2026-08-13T19:55-0700 `crates/triaged/src/main.rs` — added
  `close_listener_on_exec`, called once on the finished `tcp_listener` so it covers
  all three construction paths (inherited, and both fresh binds). Sets
  `FD_CLOEXEC` so the listener stops leaking into exec'd children.

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
  child would mostly be covered — but a child that resets its dispositions, or any
  other job-control path, reopens the hole. Removing the controlling terminal
  closes it structurally instead of by inheritance.
- 2026-08-13T19:55-0700 Did **not** bound `recv_actor_result` with a timeout.
  Tempting, since the wedge was a never-answering actor, but any deadline turns a
  slow-but-healthy session into a spurious error. With the lock released before the
  round-trip, a stuck actor blocks only the client writing to it, which is the
  property that actually matters.
- 2026-08-13T19:55-0700 Left SIGTERM handoff out of this branch. It is the
  remaining loss vector — `launchctl bootout` SIGTERMs the owner and its death
  closes every master — but Phase 2 takes 10-15s (session deserialize plus
  summarizer model load), which does not fit launchd's default grace period.
  Doing it properly means raising `ExitTimeOut` in the plist, or moving the masters
  into a keeper process that outlives daemon restarts. That is an architecture
  decision and deserves its own branch.

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
- 2026-08-13T19:55-0700 `cargo check` reporting `Finished` in 0.18s with no
  `Checking triaged` line looked like the edits had not been picked up. They had:
  an earlier invocation in the worktree had already compiled them successfully and
  the result was cached. Verified by grepping the new symbols in the worktree files
  and reading `git diff --stat`.

## Verification

- `cargo fmt --all --check` clean.
- `cargo clippy -p triaged --all-targets --all-features -- -D warnings` clean.
- `RUSTDOCFLAGS="-D warnings" cargo doc -p triaged --all-features --no-deps` clean.
- `cargo test -p triaged -- --test-threads=1`: 161 passed, 0 failed, 1 ignored,
  plus 11 in the binary target. Single-threaded per the known parallel flakiness of
  `session_context_*`.

## Next Steps

- Regression test for the lock scope: a session whose child has stopped reading
  must not prevent `list_sessions` from returning. Needs a way to block an actor
  deterministically without a timing-sensitive test.
- SIGTERM handoff or the keeper-process design, per the decision above.
- Consider making `--handover` refuse to run when it has a controlling terminal
  unless forced, so the trap is unreachable rather than merely survivable.
