## Thinking

Review of #116 flagged that `AdoptedMasterPty`'s type doc claims the descriptor
closes "when the session ends", and that it also closes when the actor is torn
down during a handover detach. The fix was written and pushed, but #116 merged
about three minutes before that push landed, so the branch carried it and `main`
never received it. The doc on `main` still says the wrong thing.

Checking the claim rather than accepting it, because the mechanism is not the
obvious one. `SessionActor::detach` sets `worker` and `reader` to `None`, which
detaches the `JoinHandle`s — the reading that suggests the thread simply keeps
running until `process::exit`, leaving the master alive. That reading is wrong.
`detach` takes `self` **by value** (`session.rs:2725`), so at the end of the
function it drops the whole `SessionActor`, and with it the command `Sender`.
The worker's `try_recv` then returns `Err(TryRecvError::Disconnected)`, which
`break`s the actor loop (`session.rs:2935`); `run_actor` returns, `ActorState`
unwinds, and the `master` it owns (`session.rs:2762`) is dropped. So the master
does close on a handover detach. The `JoinHandle`s do not hold the loop open —
the channel does.

That close is harmless, and the reason belongs next to the type rather than in a
PR description where nobody maintaining this will find it: the successor never
shares this descriptor. `SCM_RIGHTS` installs an independent one in that process
(`handover.rs:254`), and `extract_handover_state` sends a `libc::dup`
(`session.rs:2963`), not this fd. The child holds its slave side regardless.

## Plan

- Re-apply only the `handover.rs` doc correction from the stranded commit: list
  all three points the descriptor closes (actor loop end, an early return in
  `spawn_adopted_pty_runtime` before the actor takes ownership, and a handover
  detach) and record why the last is safe.
- Deliberately **not** carrying over the other half of that commit, which
  stripped `[1m]` from devlog 000098's Agent line. That change was declined on
  #118 and again on #119: the suffix is part of the literal model id, not a
  terminal escape, and rewriting it would name a different model than the one
  that did the work.
- Verify every factual claim in the doc against `main` before writing it down,
  then run the check set `AGENTS.md` documents — `cargo fmt --all -- --check`,
  `cargo clippy --all-targets --all-features -- -D warnings`,
  `RUSTDOCFLAGS="-D warnings" cargo doc` (the change is doc comments, so a broken
  intra-doc link is the live risk), and `cargo test --workspace` — on Linux,
  since this path is `#[cfg(unix)]`.
