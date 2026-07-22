# 000101 — feat/handover-session-logging

**Agent:** Claude Code (claude-opus-4-8[1m]) @ triage branch feat/handover-session-logging
(worktree: worktrees/handover-session-logging, branched from `chore/cera-0-3-1`)

## Intent

Make a handover say what it did to each session, so the question left open by the
cera 0.3.1 deploy — did the swap lose any shells? — can be answered from the log
instead of guessed at from `ps`.

## What Changed

- 2026-07-22T07:29-0700 `crates/triaged/src/session.rs` — first cut: three
  `tracing::info!` lifecycle lines, `adopted inherited live session` in
  `adopt_sessions`, `session child exited` in `broadcast_completed`, and a
  demotion line in `demote_dead_live_session`, whose success path previously
  logged nothing at all. Review corrected all three; see the 08:16 entry for what
  actually ships and Issues for why.
- 2026-07-22T08:16-0700 `crates/triaged/src/session.rs` — final state, four
  `tracing::info!` lines, all observability with no control flow changes:
  `adopted inherited live session` (`session_id`, `pid`, `command`) in
  `adopt_sessions`, emitted after the map insert; `killing session child` in
  `ActorState::shutdown`, immediately before `child.kill()`; `session child is
  gone` in `broadcast_completed`; and `demoting exited live session for restore`
  in `demote_dead_live_session`. Cause of death is carried by correlating the
  middle two on `session_id` — a kill is `killing session child` followed by
  `session child is gone`, a natural death is the latter alone — rather than
  transported into the broadcast. Transporting it is unreliable because the
  broadcast that wins is decided by a race: killing the child closes the PTY, and
  the resulting EOF *usually* broadcasts the exit from `drain_shutdown_output`
  before `shutdown` reaches its own broadcast, so a cause attached at the call site
  is silently dropped whenever that happens.

## Decisions

- 2026-07-22T07:26-0700 Branched from `chore/cera-0-3-1` instead of `main`. The
  experiment needs the binary installed over the live daemon, and building from
  `main` would put cera 0.1.1 back on the user's machine purely as a side effect
  of a diagnostic. Cost: this branch stacks on an open PR and must be rebased onto
  `main` after #118 lands. (Paid 2026-07-22T08:34-0700: #118 merged as `82c945d`
  and the branch was replayed onto `main` with `rebase --onto`, so the stack is
  gone and only this change remains.)
- 2026-07-22T07:27-0700 Ran the experiment *with* the launchd double handover
  rather than booting out the LaunchAgent first. `launchctl bootout` would
  SIGTERM the running daemon and destroy the sessions being measured — the
  measurement would consume its own subject. Since the new logging attributes
  every adoption to a specific session and PID, two adoptions are as readable as
  one, and testing the real deploy path is worth more than an artificially
  isolated one.
- 2026-07-22T07:28-0700 Logged the exit at `broadcast_completed` rather than at
  `mark_exited`/`reap_child`. `broadcast_completed` is guarded by
  `exit_broadcasted`, so it fires exactly once per session; the reap paths are
  polled and would log on every check.
- 2026-07-22T08:16-0700 **Deviation from the plan:** the branch and this devlog
  were renamed `fix/…` → `feat/…` after review flagged that the commit type
  (`feat`) and the branch type disagreed. The change adds a capability rather than
  repairing a defect, so `feat` is the correct type and the branch moved to match.
  Plan step 1 still reads `fix/` because plans are append-only; this entry is the
  record. Nothing was pushed under the old name.

## Issues

- 2026-07-22T07:24-0700 `cargo build` panicked in `build.rs`: "Flutter web bundle
  is missing and the `flutter` command was not found on PATH". Flutter lives at
  `<local-path>/flutter/bin`, which is not on `PATH` in this environment (the
  same class of problem as Homebrew's `bin`). Prepending it fixed it.
  `TRIAGE_SKIP_FLUTTER_BUILD=1` was the wrong escape hatch here: it embeds the
  placeholder bundle, and this binary was going to be installed as the live
  daemon, which serves that bundle to the web client.
- 2026-07-22T07:47-0700 The exit log was semantically wrong, and three of four
  reviewers caught it independently. `broadcast_completed` is not only reached
  from a natural death: `ActorState::shutdown` reaps the child and, if it is still
  running, **kills** it before calling in. So `session child exited` also fired for
  a user closing a session, for the daemon stopping, and for the demotion path's
  own `actor.shutdown()`. The line exists to attribute a vanished shell, and as
  written it could not tell a shell that died on its own from one the daemon
  killed — reinstating the exact ambiguity the change was meant to remove. The
  lesson: "single funnel" was an assumption about the call graph that I asserted
  in a comment without checking the callers.
- 2026-07-22T07:47-0700 The adoption line was emitted *before* `sessions.insert`,
  so a failure between the two would have logged an adoption that never entered
  the map. Moved after the insert. This does not make the line unconditionally
  true — `persist_manifest` runs after the whole loop and can still fail — but
  `main.rs` deliberately keeps partially-adopted sessions rather than discarding
  them, so a line that survived the insert reflects a session the daemon is really
  holding.
- 2026-07-22T07:47-0700 A reviewer flagged the demotion log as doing I/O under the
  global `sessions` write guard. Skipped: `triage-core/src/logging.rs:54` installs
  `tracing_appender::non_blocking`, so the call hands off to a queue rather than
  touching the filesystem, and `actor.shutdown()` already blocks under that same
  guard a few lines earlier. Restructuring the phase-3 swap to hoist one
  non-blocking log out of the lock would cost more clarity than it buys.
- 2026-07-22T07:47-0700 Cited `session.rs:1672` for the demotion call site in the
  first draft; this branch's own additions had shifted it, so the citation landed
  inside an unrelated function. Re-grepping produced a *second* stale number two
  rounds later, because each round moved the line again. Line numbers in a devlog
  that ships alongside the diff that moves them are stale by construction; the
  citation is now the function name (`restore_session`), which does not drift.
- 2026-07-22T07:58-0700 **The first fix for the exit-reason problem was worse than
  the bug**, and a second review round caught it unanimously. Passing `reason` as
  an argument — `"shutdown"` from `shutdown`, `"exited"` from `broadcast_exit` —
  looks right and is dead on arrival: killing the child closes the PTY, so
  `drain_shutdown_output` receives `OutputClosed`, calls `broadcast_exit()`, and
  sets `exit_broadcasted` *before* `shutdown` reaches its own
  `broadcast_completed`. The `"shutdown"` call is therefore a no-op and every
  deliberate kill was logged `reason="exited"` — the original ambiguity, now
  wearing a field that asserted it had been resolved. Generalizable: a
  discriminator passed from a call site is only as good as the assumption that the
  call site is the one that wins, and the exactly-once guard made that assumption
  false.
- 2026-07-22T08:16-0700 The *second* fix — a `killed_by_shutdown` flag on
  `ActorState`, set where `child.kill()` succeeds and read at the broadcast — was
  correct but unnecessary, and a third round pointed out the simpler option:
  log at the kill site and correlate on `session_id`. That needs no field, no
  initializer at either construction site, and no doc comment explaining why the
  cause cannot be derived downstream. Two reviewers also noted the flag's name
  over-claimed: `shutdown` is called for user-initiated close and restore
  rollback, not only daemon shutdown, so `killed_by_shutdown` would have labelled
  a user closing a tab as a daemon kill. Taking the third option dissolved both
  problems. Worth noting the shape of the loop: round 1 found the bug, round 2
  found my fix was broken, round 3 found the working fix was over-built.
- 2026-07-22T08:16-0700 `killing session child` can still overstate for an adopted
  session. `AdoptedChild::try_wait` is `kill(pid, 0)`, which succeeds for a
  not-yet-reaped zombie and after PID reuse, so `reap_child` can report a shell
  alive that has in fact already died, and the kill line is then attributed to a
  shell nothing killed. Pre-existing detection weakness rather than something this
  change introduces — a daemon that is not a process's parent cannot `waitpid` it
  — but it bounds how much the log can be trusted: `killing session child` means
  "the daemon believed it was alive and tried", not "the daemon ended it".
- 2026-07-22T08:16-0700 `child.kill()` uses `?`, so a kill failure returns from
  `shutdown` before the exit is ever broadcast — no `Exited` event and no exit
  line. Reachable for adopted sessions, where `AdoptedChild::try_wait` is
  `kill(pid, 0)` against a reparented process that can exit between the reap and
  the kill. Left alone deliberately: it is pre-existing control flow and fixing it
  is a behaviour change, not observability. The new kill-site line does make it
  visible — `killing session child` with no `session child is gone` after it is
  exactly this case. Recorded under Next Steps.

## Commits

- HEAD — feat(triaged): log session adoption, kill, exit, and demotion

## Research & Discoveries

- **Adopted session shells are not children of the adopting daemon.** The process
  that forked them exits during teardown, so they reparent to PID 1; only sessions
  spawned *since* the last handover are the daemon's own children. Confirmed: of
  13 adopted sessions, 10 are alive with `PPID 1` and uptimes back to the previous
  day, while the daemon's direct children were exactly the two sessions created
  after it started. `ps --ppid <daemon>` therefore undercounts adopted sessions by
  construction, and using it as the measure is what produced the false "four
  missing shells" reading on 2026-07-21.
- **No shell is lost across a handover.** In the controlled run all 13 sessions
  were adopted twice (14:27:44Z and 14:28:20Z) with byte-identical PIDs, and every
  PID that was alive before was alive after.
- **Three sessions were already dead before the handover, not killed by it.**
  `session-73`, `session-80` and `session-104` each logged their exit within a few
  milliseconds of adoption, in *both* handovers. (The two lines are not ordered by
  construction — the actor worker thread starts before the adoption line is
  emitted — so read the closeness as coincidence in time, not causation.) An event
  that reproduces identically across two independent swaps is a pre-existing state
  being discovered, not damage being done.
- Dead `Live` sessions are carried indefinitely. Demotion is reachable only from a
  restore request (the sole caller is `restore_session`), so a session whose shell
  died stays `Live`, is serialized into every subsequent handover, and has a PTY fd
  passed for a dead PID. `sessions.json` compounds it: all 32 sessions are persisted `exited: false`,
  covering both the 19 that are merely `Historical` and the 3 `Live` ones whose
  shells are confirmed dead — so at least 22 sessions are recorded as live without
  a running shell, and the manifest cannot be used to reason about liveness.
  `Adopting 13 inherited live sessions` overstates what is live for the same
  reason, and until now the count was the only signal available.
- The fresh shells seen at 06:16:28–43Z on 2026-07-21 line up with the Flutter
  client reconnecting after its reinstall, not with the handover: a client
  attaching to a session whose shell had died drives restore → demote → respawn,
  which is exactly the "respawn with restored cwd" that looked like recovery from
  a crash.

## Lessons Learned

- Pick the measurement from the model, not from convenience. "Children of the
  daemon" was the easy thing to capture with `ps` and was structurally incapable
  of answering the question, because handover deliberately severs that
  relationship. A whole round of analysis was spent on an artifact of the wrong
  metric.
- An anomaly that reproduces identically across two independent runs is
  pre-existing state, not damage.

## Next Steps

- ~~Rebase onto `main` once #118 merges~~ — done 2026-07-22T08:34-0700; #118 landed
  as `82c945d` and this branch now sits directly on `main` with no stack.
- Reap dead `Live` sessions rather than carrying them forever — a sweep at
  adoption is the natural place, since `session child is gone` already fires there
  within milliseconds.
- Persist the real `exited` state in `sessions.json`, which currently records
  every session as live regardless.
- Make a failing `child.kill()` still broadcast the exit. Today the `?` in
  `ActorState::shutdown` returns before `broadcast_completed`, so subscribers
  waiting on `SessionEvent::Exited` get nothing and the session's end is never
  logged. Out of scope here because it changes behaviour rather than
  observability, but the new kill-site line makes the case identifiable:
  `killing session child` with no `session child is gone` following it.
