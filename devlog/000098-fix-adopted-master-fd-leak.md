# 000098 — fix/adopted-master-fd-leak

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch fix/adopted-master-fd-leak

## Intent

Close a PTY-master descriptor leak found by running real handovers against the
live daemon after #113 merged, not by reading the code.

## What Changed

- 2026-07-21T11:45-0700 `crates/triaged/src/handover.rs` — `AdoptedMasterPty` holds
  an `OwnedFd` instead of a bare `RawFd`, so an adopted session releases its master
  when the session ends and on every early return in `spawn_adopted_pty_runtime`.
  Construction moved behind `unsafe fn from_raw_fd`, which is the single place the
  ownership claim is made; the accessors read through `raw()`.
- 2026-07-21T11:30-0700 `crates/triaged/src/session.rs` — `UnadoptedFds::next_fd`
  (peek) became `take_next` (pop) and `claim` is gone, making ownership of a
  descriptor linear. Rewrote the guard's `SAFETY` note, which claimed something
  untrue (see Issues).
- 2026-07-21T11:30-0700 `crates/triaged/src/handover_tests.rs` — added
  `adopted_master_closes_its_fd_on_drop`.

## Decisions

- 2026-07-21T11:30-0700 Fix ownership, not just the missing `Drop`. `next_fd`
  only peeked at the queue and `claim` popped it *after* the session went live, so
  between those two points the guard and the session's `AdoptedMasterPty` both
  held the same descriptor. That was harmless only because the master never closed
  anything. Adding a `Drop` on its own would have closed it twice on the failure
  path, and since descriptors are recycled immediately, the second close lands on
  whatever unrelated fd inherited the number. Moving ownership at hand-off gives
  exactly one owner at every instant: the guard holds what was never handed out,
  the master holds the rest.
- 2026-07-21T11:30-0700 Test the `Drop` on the type directly rather than through a
  live adopted session. `FdProbe` (added in #113) identifies a descriptor by
  `(dev, ino)`, which works because a fresh temp file has an inode nothing else
  shares — but every `/dev/ptmx` clone reports the *same* inode, so on a real PTY
  master "closed, and the number reissued to another master" would be
  indistinguishable from "still open". A temp-file probe tests the close itself
  without that ambiguity.
- 2026-07-21T11:30-0700 This reverses the trade-off recorded on the
  `close handover fds that no session adopts` commit in #113, which chose
  `UnadoptedFds` over a `Drop` on `AdoptedMasterPty` because a `Drop` would
  "change when a *live* session's master closes". It does — and that is the
  behaviour needed. On the handover path it is safe: the successor's descriptor is
  an independent one installed by `SCM_RIGHTS` and the sender passes a `libc::dup`,
  so the session survives through the successor's copy and the child's slave side.

## Issues

- **The leak is not a corner case.** Every handover re-adopts *every* session, so
  one swap makes the whole set adopted, and from then on each session that ends
  leaks a descriptor for the life of the daemon. A natively spawned session is
  unaffected — `portable_pty`'s master owns its descriptor. That asymmetry is why
  it survived review: the code reads fine until you notice `AdoptedMasterPty` holds
  a bare `RawFd`.
- **The guard's `SAFETY` note was false.** It read "an unclaimed fd never reached a
  `MasterPty`, so no session holds it", but `spawn_adopted_pty_runtime` wraps the
  fd in an `AdoptedMasterPty` as its first act, well before `claim` ran. The
  invariant the comment asserted did not hold; it was the missing `Drop` that made
  the code safe, not the invariant. Rewritten to describe what the guard actually
  holds.

## Research & Discoveries

- 2026-07-21T11:00-0700 **Found by shutting down two stale sessions on the live
  daemon.** Destroying them removed both from the daemon but released only two of
  each one's three descriptors, leaving one open on each of their PTY devices
  (`15,6`, `15,16`); the daemon's `ptmx` fd count fell 28 → 26 for two sessions
  destroyed. The reader and writer are `dup`s and closed themselves; the master did
  not.
- 2026-07-21T11:00-0700 A daemon keeps the master of a session whose shell has
  already exited, so "Adopting N inherited live sessions" counts *tracked* sessions,
  not live ones. Two of the ten on this daemon had no shell, which is what made the
  leak observable at all.

- 2026-07-21T11:45-0700 Use `OwnedFd` rather than a hand-written `Drop`. Both close
  at the same moment, but `OwnedFd` makes the leak unrepresentable instead of
  fixed by convention, and it removes the `unsafe` close entirely — the only
  remaining `unsafe` is the single ownership claim in `from_raw_fd`, where it
  belongs. This is also what the Copilot review on #113 asked for ("making the
  handover fds RAII-owned (e.g. `Vec<OwnedFd>` / store `OwnedFd` in
  `AdoptedMasterPty`)"); `UnadoptedFds` answered the queued-fd half of that comment
  in #113, and this answers the rest.

## Review

PR #116, first round — all findings were about the ownership story being stated
less tightly than the code now enforces it:

- 2026-07-21T14:40-0700 `AdoptedMasterPty.fd` was still `pub`. The type's whole
  purpose is that exactly one owner holds the descriptor, and a public field lets
  a caller build or replace one without passing through `from_raw_fd` — the only
  place that invariant is written down. Made private; the sole reader was the
  type's own `raw()`.
- 2026-07-21T14:40-0700 Narrowed `from_raw_fd` to `pub(crate)`. Both call sites
  (`spawn_adopted_pty_runtime` and its test) are in this crate, so an `unsafe`
  constructor need not be reachable beyond it.
- 2026-07-21T14:40-0700 `UnadoptedFds`' struct doc still said it owns each
  descriptor "until the session it belongs to is live", which `take_next` made
  false — ownership now moves at the pop, before the session exists. That is the
  same class of stale claim as the `SAFETY` note this branch already rewrote, so
  it now states the linear-ownership rule explicitly.
- 2026-07-21T14:40-0700 The drop test asserted "an adopted session leaked its PTY
  master when it ended", but exercises `AdoptedMasterPty` directly with no session
  involved. Message now names the type and keeps the consequence as context.
- 2026-07-21T14:40-0700 A devlog entry in `000096` had lost its list marker and
  timestamp, leaving `found in production, not in review.**` as a dangling line
  with an unmatched bold. It was malformed in the commit that introduced it
  (833ad91), not by a later edit. Restored the marker and the lead-in.
- 2026-07-21T14:40-0700 The PR description said switching to `OwnedFd` was left
  out as a follow-up, while the diff does switch to it. The description was stale,
  not the code; corrected on the PR.

## Next Steps

- Nothing outstanding for this change. `UnadoptedFds` could itself hold `OwnedFd`s
  for symmetry, which would remove its `unsafe` block too, but it is already
  correct and the churn would touch #113's tests for no behavioural gain.

## Commits

- 6831ec7 — fix(triaged): own an adopted session's PTY master so it closes when the session ends
- 833ad91 — docs(devlog): record the production handover results from #113
- f6fd257 — docs(devlog): renumber to 000098 after 000097 landed on main
- HEAD — fix(triaged): constrain AdoptedMasterPty's descriptor to one owner
