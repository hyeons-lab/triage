# 000086-01 — Persist and track the live session cwd

## Thinking

Two reported symptoms, both rooted in how the session working directory is
tracked:

1. **Daemon kill → restore puts the shell back in `~/`.** The on-disk manifest
   (`PersistedSession`) only stores the *launch* cwd, and for these sessions the
   launch cwd is `None` (verified in the live `sessions.json`). The live cwd is
   held only in `ActorState.current_working_directory` and is never persisted.
   The user's shell is zsh, which emits no OSC 7 (verified: 0 OSC 7 sequences in
   any session log), so `HistoricalSession::restore` — which rebuilds cwd from
   `persisted.cwd` plus OSC 7 log replay — recovers nothing and
   `restorable_cwd(None, None)` returns `None`, so the restored shell spawns in
   `~`.

2. **Side rail always shows "main".** The branch is computed live as
   `git branch --show-current` in the tracked cwd, so it is only ever as correct
   as the tracked cwd. `poll_child_cwd` reads the cwd of the *immediate* PTY
   child (the login zsh). When real work happens in a nested shell / agent that
   `cd`'d into a worktree (confirmed scenario), the login shell stays in the
   parent repo (on `main`), so the rail shows the parent's branch. The poll is
   also output-driven, so idle sessions never refresh.

The unifying fix: track the cwd of the PTY's **foreground process group** (what
the terminal is actually running) instead of just the PTY leader, refresh it
even while idle, and **persist** it so a hard kill restores into it.

## Plan

### Part A — track the foreground process-group cwd (symptom #2)

1. Add `ActorState::foreground_cwd_pid()`: on unix, `libc::tcgetpgrp(master_fd)`
   (master fd via `self.master.as_raw_fd()`); return the fg pgid when `> 0`,
   else fall back to `self.child.process_id()`. Non-unix: just the child pid.
2. `poll_child_cwd` resolves `child_cwd(foreground_cwd_pid())` instead of the
   raw child pid. Keep the 750ms throttle.
3. Idle refresh: in the actor loop's output `recv_timeout` **Timeout** branch,
   run the throttled poll (only while `!shell_reports_cwd`) and `apply_cwd` on a
   change, so idle nested shells update their branch without new output.

### Part B — persist the live cwd (symptom #1)

4. `PersistedSession` gains `#[serde(default)] last_known_cwd: Option<PathBuf>`
   (back-compat with existing manifests).
5. `ManagedSession::Live` gains a `last_known_cwd: Option<PathBuf>` field,
   initialized from the launch/restored cwd, mutated under the sessions lock.
6. Actor → manager channel: new unconditional `cwd_tx:
   Option<Sender<(SessionId, PathBuf)>>` on `ActorState`, threaded through the
   `spawn_*` constructors. `apply_cwd` sends on it **only when the cwd changed**
   and a session id is assigned.
7. `SessionManager::start_cwd_persistence(self: &Arc<Self>)` spawns a thread
   that drains the channel, updates the matching `Live.last_known_cwd`, and
   re-persists the manifest. Called from `main.rs` at startup (not gated on the
   summarizer, unlike the debounce loop). Manager owns the `Sender`; actors get
   a clone like they do for `global_senders`.
8. `ManagedSession::persisted()` for `Live` writes `last_known_cwd`.
9. `HistoricalSession::restore`: seed `current_working_directory` from
   `last_known_cwd` (validated via `restorable_cwd`/`is_dir`) before the launch
   cwd; OSC 7 replay still overrides when present.

### Tests

- `foreground_cwd_pid` falls back to the child pid when no fg pgrp.
- `poll`/restore: a `PersistedSession` with `last_known_cwd` set restores into
  it; missing field deserializes to `None` (back-compat).
- `restore` prefers `last_known_cwd` over launch cwd; falls back when the dir no
  longer exists.
- Idle-timeout poll updates cwd without output (where feasible to unit-test).

### Validation

`cargo test -p triaged` and
`cargo clippy --workspace --all-targets --all-features -- -D warnings`.
