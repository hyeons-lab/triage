# 000086 — Persist and track the live session cwd

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/persist-live-cwd-cold-restore

## Intent

Two related cwd bugs reported against the running daemon:

1. Killing the daemon and restoring sessions puts every shell back in `~/`.
2. The side rail always shows `main` for the branch.

Both stem from how the session working directory is tracked and (not) persisted.

## Research & Discoveries

- 2026-06-25T07:13-0300 Live-daemon forensics (pid 1571 = `~/.cargo/bin/triaged`,
  cwd `/`):
  - Every session in `~/.local/state/triage/sessions/sessions.json` has
    `cwd = None` — the launch cwd was never recorded.
  - User shell is `/bin/zsh`; **zero** OSC 7 (`ESC]7;`) sequences across all
    `session-*.log` files → the OSC 7 cwd path never fires for this user.
  - Session shells (children of pid 1571) sit in real dirs
    (`private-gateway`, `pipette-clients`, `leap-android-sdk` — all on `main`;
    home). The one feature-branch dir (`feat/sentry-monitoring`) is a *nested*
    shell (ppid 6463), not a direct session shell.
- **Symptom #1 cause:** `PersistedSession` stores only the launch cwd; the live
  cwd lives in `ActorState` and is never persisted. With launch cwd `None` and
  no OSC 7 to replay, `HistoricalSession::restore` →
  `restorable_cwd(None, None)` = `None` → shell respawns in `~`.
- **Symptom #2 cause (user-confirmed: nested/child process):**
  `poll_child_cwd` reads the *immediate* PTY child's cwd (the login zsh), so
  when work runs in a nested shell/agent that `cd`'d into a worktree, the rail
  shows the parent repo's branch (`main`). The poll is also output-driven, so
  idle sessions never refresh.

## Decisions

- 2026-06-25T07:13-0300 **Track the PTY foreground process group's cwd**
  (`tcgetpgrp`) instead of the PTY leader's, falling back to the child pid. The
  foreground pgrp is "what the terminal is actually running," which is the right
  signal for the branch indicator. Known limitation: a *transient* child of the
  foreground process (e.g. an agent's short-lived `git` subprocess) is not
  tracked — only the foreground group leader.
- 2026-06-25T07:13-0300 **Persist the live cwd on change** (user-chosen trigger)
  via an unconditional actor→manager channel + a dedicated persistence thread,
  *not* the summarizer debounce loop (which is gated on the summarizer being
  enabled).

## Plan

See `devlog/plans/000086-01-persist-and-track-live-cwd.md`.

## What Changed

- 2026-06-25T07:29-0300 `crates/triaged/src/session.rs` — **Part A (branch
  always "main"):** `ActorState::poll_child_cwd` now resolves the PTY
  *foreground process group* (`foreground_cwd_pid` via `libc::tcgetpgrp`),
  falling back to the direct PTY child, so the tracked cwd follows a `cd` made in
  a nested shell/agent rather than staying pinned to the login shell. Added
  `refresh_idle_cwd`, called on the actor loop's idle output timeout, so quiet
  sessions still refresh their cwd/branch without new output. Seeded
  `last_cwd_poll` at spawn so the first poll waits one interval (keeps the
  post-spawn snapshot deterministic, avoids racing the initial snapshot).
- 2026-06-25T07:29-0300 `crates/triaged/src/session.rs` — **Part B (restore →
  `~/`):** `PersistedSession` gains `#[serde(default)] last_known_cwd`;
  `ManagedSession::Live` gains a `last_known_cwd` field seeded from the
  launch/restored cwd. New unconditional actor→manager channel (`cwd_update_tx`)
  + `start_cwd_persistence` thread that records the live cwd into the manifest on
  every change (`record_live_cwd`); `apply_cwd` reports a change via
  `report_cwd_change`. `persisted()` writes `last_known_cwd`;
  `HistoricalSession::restore` prefers it over the launch/replayed cwd. Added
  `#[allow(clippy::large_enum_variant)]` on `ManagedSession` (the live variant is
  inherently large and few are held).
- 2026-06-25T07:29-0300 `crates/triaged/src/main.rs` — call
  `manager.start_cwd_persistence()` at daemon startup (independent of the
  summarizer).
- 2026-06-25T07:29-0300 Tests: `session_manager_restores_persisted_last_known_cwd_without_osc7`,
  `session_manager_restore_ignores_unusable_last_known_cwd`,
  `persisted_session_deserializes_legacy_manifest_without_last_known_cwd`.

### Code-review fixes (max-effort multi-agent review)

- 2026-06-26T16:57-0300 `crates/triaged/src/session.rs` — addressed all findings
  from a max-effort `/code-review` (10 finder angles + verify + sweep):
  - **Idle git churn:** poll callers (`refresh_idle_cwd`, `handle_output` None
    branch) now go through `apply_polled_cwd`, which skips `apply_cwd` (and its 3
    `git` execs in `resolve_session_context`) when the polled cwd is unchanged —
    so idle non-OSC-7 sessions no longer spawn git every 750ms.
  - **Write amplification / keystroke latency:** the cwd-persistence thread now
    coalesces a burst of `cd`s within a `CWD_PERSIST_SETTLE` (500ms) window into a
    single manifest write (`run_cwd_persistence_loop` + `flush_cwd_updates`),
    mirroring the summarizer's `run_debounce_loop`, instead of one full-manifest
    rewrite per `cd` (`record_live_cwd` removed).
  - **Demote loses cwd:** `demote_dead_live_session` now carries the live
    `last_known_cwd` into the persisted entry, so exit-then-restore no longer
    resets to the launch dir / clobbers the manifest with `None`.
  - **Handover:** adoption now reads the inherited PTY's foreground process group
    (`pty_foreground_pgid`, shared with the live `foreground_pgid`) so a
    nested-shell cwd is recovered at adoption instead of reverting to the login
    shell's dir; `adopted_session_cwd` gained a `foreground_pgid` arg.
  - **pgid-as-pid staleness:** `poll_child_cwd` falls back to the direct child
    pid when `child_cwd(foreground_pgid)` fails (dead group leader of a pipeline).
  - **Historical restore:** `last_known_cwd` is now `is_dir`-guarded before
    overriding the displayed cwd, so a removed worktree doesn't surface a dead
    path in the side rail for a never-restored session.
  - **Doc fix:** corrected the misleading `start_cwd_persistence` comment about a
    second call.
  - Tests: added `demoting_dead_live_session_preserves_last_known_cwd`; extended
    `adopted_session_cwd_prefers_the_live_process_over_replay_and_launch` to cover
    the foreground-pgid preference.

### PR #99 review responses (Copilot)

- 2026-06-26T18:30-0300 `crates/triaged/src/session.rs`:
  - **Idempotent `start_cwd_persistence`:** early-returns when `cwd_update_tx` is
    already set, so a second call can't spawn a duplicate thread / split updates
    across channels; rolls the sender back if the thread fails to spawn.
  - **Same-dir branch refresh:** reverted the output-driven poll path to call
    `apply_cwd` directly (only the *idle* path keeps the unchanged-cwd dedup), so
    a same-directory `git switch`/`checkout` — which produces output — still
    refreshes the side rail. Idle git churn stays fixed.
  - **Restore precedence:** rewrote `HistoricalSession::restore` to pick the cwd
    by validated precedence `last_known_cwd > replayed OSC 7 > launch`, each
    `is_dir`-checked. Kept `last_known_cwd` ahead of the replayed OSC 7 cwd
    (against the reviewer's suggested flip): the replayed value is the *login
    shell's* dir and can lag work done in a nested subshell — preferring it would
    reintroduce the "always main" symptom this change fixes. The `is_dir`
    validation on all candidates supersedes the earlier single guard.

## Validation

- 2026-06-25T07:29-0300 `cargo test -p triaged` — 123 passed, 1 ignored.
- 2026-06-26T16:57-0300 after review fixes: `cargo test -p triaged` — 124 passed,
  1 ignored; `cargo clippy --workspace --all-targets --all-features -- -D warnings`
  — clean. (`flatc` required on PATH via `/opt/homebrew/bin`.)
- 2026-06-26T18:00-0300 CI "Format and Lint" caught a `cargo doc -D warnings`
  failure: the public `start_cwd_persistence` doc used intra-doc links
  (`[`CWD_PERSIST_SETTLE`]`, `[`run_debounce_loop`]`) to private items, which
  `rustdoc::private_intra_doc_links` rejects. Switched them to plain code spans.
  Reproduced/verified locally with
  `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps --locked`.

## Commits

- HEAD — fix(triaged): persist and track the live session working directory
  (feature + the max-effort code-review fixes, squashed into one commit)
