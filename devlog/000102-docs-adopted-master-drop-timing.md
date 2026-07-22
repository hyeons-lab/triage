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
- 2026-07-22T10:35-0700 `crates/triaged/src/session.rs` — `SessionActor::detach`'s
  doc no longer claims the worker thread "keeps owning the live PTY child until
  this process exits". It says what actually happens: clearing the handles only
  gives up the right to join, the dropped `Sender` ends the loop, and the master
  closes — with the child left alive because nothing signals shutdown.
- 2026-07-22T10:35-0700 `devlog/plans/000102-01-adopted-master-drop-timing.md` —
  the verification step now names `AGENTS.md`'s exact check commands instead of
  paraphrasing them (`cargo fmt` without `--check` would have *applied* formatting
  rather than gating on it).

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

The doc was wrong in a way that reads as reassuring, which is the dangerous
shape: "closes when the session ends" invites the conclusion that a live
session's master is never closed underneath it, and the handover path does
exactly that. It is safe only because of the `SCM_RIGHTS` + `dup` arrangement,
which was documented nowhere near the type.

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
  was the wrong one.
- Safety of that close confirmed at both ends: `SCM_RIGHTS` installs an
  independent descriptor in the successor (`handover.rs:254`), and
  `extract_handover_state` sends `libc::dup(fd)` (`session.rs:2963`) rather than
  the master's own fd.

## Commits

- 0805066 — docs(triaged): describe every point an adopted master closes
- HEAD — docs(triaged): reconcile detach's doc with the master it drops

## Progress

Doc corrected and every claim in it re-verified against `main`. Checked on Linux
under WSL, since the path is `#[cfg(unix)]` and a Windows host cannot compile it.

## Next Steps

- None. The behaviour is unchanged; this only makes the existing behaviour
  discoverable.
