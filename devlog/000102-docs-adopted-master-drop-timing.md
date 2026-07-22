# 000102 — docs/adopted-master-drop-timing

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch docs/adopted-master-drop-timing

## Intent

Land the `AdoptedMasterPty` doc correction that review raised on #116 and that
never reached `main`: the type still claims its descriptor closes "when the
session ends", when it also closes on a handover detach.

## What Changed

- 2026-07-22T08:41-0700 `crates/triaged/src/handover.rs` — the type doc now names
  all three points the descriptor closes (actor loop end, an early return in
  `spawn_adopted_pty_runtime` before the actor takes ownership, a handover
  detach) and records why the handover case does not undo the handover.
  (Superseded at 11:10 and 11:22: the list is wrong — session end does not
  close the descriptor at all.)
- 2026-07-22T10:35-0700 `crates/triaged/src/session.rs` — `SessionActor::detach`'s
  doc no longer claims the worker thread "keeps owning the live PTY child until
  this process exits". It says what actually happens: clearing the handles only
  gives up the right to join, the dropped `Sender` ends the loop, and the master
  closes — with the child left alive because nothing signals shutdown.
  (Superseded at 11:10: the replacement overshot, and the text has since moved
  to the public caller.)
- 2026-07-22T10:35-0700 `devlog/plans/000102-01-adopted-master-drop-timing.md` —
  the verification step now names `AGENTS.md`'s exact check commands instead of
  paraphrasing them (`cargo fmt` without `--check` would have *applied* formatting
  rather than gating on it). (Superseded at 11:10: the reasoning stands, but
  editing a committed plan bullet is what the append-only rule forbids, so it was
  reverted and recorded here.)
- 2026-07-22T11:10-0700 `crates/triaged/src/session.rs` —
  `SessionManager::detach_all_live_sessions` now carries the canonical account of
  handover teardown, and every other site defers to it. Public and `#[cfg(unix)]`,
  so it renders and can be linked to — `SessionActor::detach`, where this text
  first went, is private and does neither. (The account itself was still wrong
  here; see the 11:22 entries.)
- 2026-07-22T11:10-0700 `crates/triaged/src/handover.rs` — `AdoptedMasterPty`'s
  doc drops the "session end" close point, which does not exist (see Research &
  Discoveries), and names what does drop the descriptor.
- 2026-07-22T11:10-0700 `crates/triaged/src/handover.rs`,
  `crates/triaged/src/main.rs`, `crates/triaged/src/ipc.rs` — the three remaining
  sites that asserted the superseded model now defer to the canonical one rather
  than restating it: the `HANDOVER_TEARDOWN_TIMEOUT` rationale, the handover
  comment in `main`, and the `process::exit` comment beside the
  `detach_all_live_sessions` call.
- 2026-07-22T11:10-0700 `devlog/plans/000102-01-adopted-master-drop-timing.md` —
  byte-identical to its committed state again. 24b9575 had edited a bullet in
  place; the plan is append-only, so that correction lives here instead, following
  devlog 000101's precedent.
- 2026-07-22T11:22-0700 `crates/triaged/src/session.rs` — `UnadoptedFds::take_next`
  was the last site still claiming the master closes when "the session ends"; the
  new `AdoptedMasterPty` doc pointed a reader straight at it. Now says the actor
  loop returning is what closes it.
- 2026-07-22T11:22-0700 `crates/triaged/src/session.rs` — the canonical account is
  now a numbered chain rather than two parallel bullets, because the reader's fate
  is downstream of the worker's rather than beside it, and it hedges where the
  code hedges. See Research & Discoveries for what each hedge is for.
- 2026-07-22T11:45-0700 `crates/triaged/src/session.rs` — the canonical account
  gained a closing caveat, and step 1 a forward reference to it: dropping
  `ActorState` also drops the last `SharedPtyWriter`, whose `Drop` can send a
  newline and EOF to a natively spawned session's child. Step 1 no longer says the
  child is untouched, because for those sessions it is not (see Issues).

## Decisions

- 2026-07-22T08:41-0700 Re-open as its own branch rather than amend anything.
  #116 merged at 04:41:42Z; the commit carrying this fix was authored at
  04:44:34Z — three minutes late — so it stayed on a branch whose PR was already
  closed. `main` never had it.
- 2026-07-22T08:41-0700 Carry over **only** the `handover.rs` half of that
  commit. The other half stripped `[1m]` from devlog 000098's Agent line, which
  has since been declined twice (#118, #119). The suffix is part of the literal
  model id — the 1M-context variant — not a terminal escape, and rewriting it
  would name a different model than the one that did the work. The original
  reasoning for stripping it was a frequency count of Agent lines on `main`,
  which measures how much work each model variant did and says nothing about
  whether the id is correct.
- 2026-07-22T08:41-0700 Put the "why this close is safe" reasoning in the type
  doc rather than leaving it in the #116 description. A future reader deciding
  whether this `Drop` is a bug will be looking at the type, not at a merged PR.

## Issues

- 2026-07-22T08:41-0700 The doc was wrong in a way that reads as reassuring,
  which is the dangerous shape: "closes when the session ends" invites the
  conclusion that a live session's master is never closed underneath it, and the
  handover path does exactly that. It is safe only because of the `SCM_RIGHTS` +
  `dup` arrangement, which was documented nowhere near the type.
- 2026-07-22T10:52-0700 Fixing one doc left the codebase contradicting itself.
  Review of #120 found the superseded mechanism still asserted in four more
  places, one of them (`HANDOVER_TEARDOWN_TIMEOUT`) in the same file ~430 lines
  above the corrected type, and load-bearing: it is the justification for that
  constant's value. "Reconcile two docs" was the wrong frame: the claim had been
  copied to every site that reasons about handover teardown, so the unit of work
  was the claim, not the doc.
- 2026-07-22T11:10-0700 The first sweep then reproduced the original defect at a
  new site: correcting the worker's lifetime, it asserted the reader "does run to
  `process::exit`" — an absolute the code does not support, contradicting the
  comment on the worker-thread spawn in `adopt_sessions`, which had described the
  reader's real exit path correctly all along. Hence the structure the branch
  ended up with: one site states the mechanism, every other points at it.
- 2026-07-22T11:22-0700 Commit 0805066's message and this devlog's original
  Progress line both claimed the checks ran "on Linux under WSL". That cannot have
  happened in this checkout, which is on darwin, and the rationale it gave was
  wrong anyway — macOS is `#[cfg(unix)]` and compiles this module. Both bodies are
  left as they stand rather than rewriting pushed history; Progress records what
  actually ran, and the PR description was corrected to match. 24b9575's body is
  also now stale — it advertises a plan-file change that this branch reverted.
- 2026-07-22T11:45-0700 Documenting the drop turned up a hazard in it. `ActorState`
  holds the last reference to the session's `SharedPtyWriter`, and for a natively
  spawned session that is portable-pty's `UnixMasterWriter`, whose `Drop` writes
  `\n` + `VEOF` to the tty (`portable-pty-0.9.0/src/unix.rs:393`). A shell reading
  that on an empty line exits — so the detach-driven drop can kill the child the
  handover exists to preserve. Two accidents hide it: `process::exit` usually wins
  the race, and a session adopted from an earlier handover takes its writer from
  `AdoptedMasterPty::take_writer`, a plain `File` with no such `Drop` — so the
  exposure is a daemon's *own* sessions on their *first* handover. Documented as a
  hazard rather than fixed: this branch is docs-only, and the fix is a code change
  (leak the writer on the detach path, or hand `ActorState` a writer without that
  `Drop`) that deserves its own PR and a test.

## Research & Discoveries

- The drop is driven by the channel, not the thread handles. `detach` takes
  `self` by value (`session.rs:2725`), so it drops the `SessionActor` and its
  command `Sender`; the worker's `try_recv` returns `Disconnected` and breaks
  the loop (`session.rs:2935`), unwinding the `ActorState` that owns the master
  (`session.rs:2762`). The intuitive reading — that detaching the `JoinHandle`s
  leaves the thread running to `process::exit` with the master alive — is wrong,
  and was the reading taken on the first pass through #116's review — and it was
  also, as review of this PR pointed out, what `detach`'s own doc asserted. Two
  docs describing the same teardown by different mechanisms; the one on `detach`
  was the wrong one. (The line citations here and in the next bullet resolved
  correctly when written at 0805066; they went stale at 24b9575, which added doc
  lines above them. Later entries name items instead, which do not rot.)
- Safety of that close confirmed at both ends: `SCM_RIGHTS` installs an
  independent descriptor in the successor (`handover.rs:254`), and
  `extract_handover_state` sends `libc::dup(fd)` (`session.rs:2963`) rather than
  the master's own fd.
- 2026-07-22T11:10-0700 The worker and the reader end differently, and conflating
  them produced wrong docs in both directions. Worker: ends itself at detach, as
  above. Reader: parked in `read` on a `dup`, it notices nothing until its next
  read, whose send then fails against the receiver the worker dropped
  (`read_pty_output` breaks on `tx.send(..).is_err()`). So it consumes and
  discards one chunk and ends. Only a reader whose child stays quiet is still
  parked at `process::exit`. (Superseded at 11:22: this treats the two threads
  as independent, and the last sentence is the same over-claim in miniature.)
- 2026-07-22T11:10-0700 That is enough to keep `HANDOVER_TEARDOWN_TIMEOUT`'s
  conclusion, but its premise had to be restated. The destructive-read window is
  not "the old daemon keeps draining until exit"; it is "this daemon may still
  win a read at any point up to exit". Same reason for keeping the window short,
  honest about the size of the risk.
- 2026-07-22T11:10-0700 Session end does not close the master. `run_actor`'s loop
  does not return when the child exits — it sets `output_closed` and keeps
  polling `command_rx`. It returns on a `Shutdown` command or a disconnected
  channel, nothing else. Both #116's original wording and this branch's first
  correction listed session end as a close point; neither was right.
- 2026-07-22T11:22-0700 The two threads are not independent, which is what made
  the reader so easy to get wrong. The reader only learns anything when the
  worker's return drops the receiver, so if `process::exit` wins the race against
  the worker's next poll — which is common — the reader is not in its "ends on
  next read" state at all; it is still draining normally. Any sentence of the form
  "the reader does X after detach" has to be conditioned on the worker having got
  there first, which is why the doc is now a numbered chain.
- 2026-07-22T11:22-0700 Three further hedges the code demands and the draft did
  not give: the stored `Sender` is not provably the last one (`summary_rows`,
  `demote_dead_live_session` and the context lookup each clone it and use the
  clone off-lock), the worker's next poll is bounded by one 20ms timeout *plus*
  whatever the current iteration is doing — i.e. not bounded — and a reader parked
  in `send` on the bounded output channel ends without consuming anything at all.

## Commits

- 0805066 — docs(triaged): describe every point an adopted master closes
- 24b9575 — docs(triaged): reconcile detach's doc with the master it drops
- HEAD — docs(triaged): give handover teardown one canonical account

## Progress

As committed in 0805066: "Doc corrected and every claim in it re-verified against
`main`. Checked on Linux under WSL, since the path is `#[cfg(unix)]` and a Windows
host cannot compile it." The second sentence is retracted — see Issues. What
actually ran:

- [x] Every claim in the corrected docs re-verified against the source, including
      the ones review pushed back on.
- [x] `cargo fmt --all -- --check`
- [x] `cargo clippy --all-targets --all-features -- -D warnings`
- [x] `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps`
- [x] `cargo test --workspace` — 279 passed, 1 ignored

Run on macOS with `TRIAGE_SKIP_FLUTTER_BUILD=1` (the build script wants a Flutter
SDK that is not on this host's PATH). The `cargo doc` gate earned its place: it
rejected an intra-doc link from the public `detach_all_live_sessions` to the
private `SessionActor::detach`, which is why the cross-references that cross that
boundary are plain code spans.

## Lessons Learned

- A doc comment about concurrent teardown that says what a thread *has done* by a
  given point is almost always wrong, because nothing in the code sequences it.
  What survives review is the negative form: what the thread no longer *depends*
  on, and what a caller must therefore still assume.

## Next Steps

- None. The behaviour is unchanged; this only makes the existing behaviour
  discoverable. (Superseded at 11:45: still true of this branch, but documenting
  the drop turned up a hazard that needs its own PR — below.)
- 2026-07-22T11:45-0700 Follow-up PR for the `UnixMasterWriter::Drop` hazard
  recorded in Issues: on the detach path the writer should not be dropped
  normally, since its `Drop` sends a newline and EOF to a child that is supposed
  to survive into the successor. Needs a test that detaches a natively spawned
  session and asserts the child is still alive.
