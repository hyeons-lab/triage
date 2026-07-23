# 000106-01 — Infer the worktree a root/main session is driving

## Thinking

### The complaint

Most side-rail rows lead with `main`. Sessions start in the repo root (the
primary checkout, always on `main`), and `SessionVm.railTitle` leads with the
branch — so every root row opens with the same uninformative word and the part
that differs is demoted to a session-id suffix. The user wants that first line
to name the *worktree the session is working on*, not the repo root.

### What already works

`railTitle` is branch-first, then a distinct worktree leaf, then `displayTitle`.
When a session's cwd is genuinely *inside* a linked worktree, the daemon resolves
`branch = feat/x`, `worktree_root = worktrees/x`, and the rail already leads with
`feat/x`. Live `session_context_updated` pushes keep this current as the session
`cd`s around. So the in-a-worktree case is solved; only the **root-on-`main`**
case is not.

### Why the signal is transient, not absent

The user's workflow drives worktrees from the primary checkout with
`git -C worktrees/x …` rather than `cd`-ing in. Git's `-C <path>` `chdir`s the
`git` process into that path before running, so while the command runs the
foreground process's cwd *is* the worktree. The daemon's cwd poll
(`resolve_session_context`, 750 ms interval, active for non-OSC-7 shells like
zsh) can observe it and broadcast a context update naming `worktrees/x`. But the
instant the command finishes the foreground reverts to the shell at the repo
root and the next poll snaps the rail back to `main`.

So the worktree *is* observable — just not durably. "Infer the worktree" =
**remember the last worktree a row was seen driving and keep leading with it**
until the session moves to a different worktree or goes quiet.

### Where to do it: client-side

Every worktree observation already reaches the client as a context field (seed
on connect, the attach snapshot, and live `session_context_updated`). Making the
memory client-side means **zero daemon or wire-protocol change** — the reliability
ceiling is entirely "did the daemon catch the `git -C` process at least once",
which a daemon-side enhancement could later raise without changing this contract.
This is the smallest surface that satisfies the accepted behavior (sticky, may
flicker, reverts when idle).

### The rule

- On every context observation, if it names a **distinct linked worktree**
  (`worktree_root` present and ≠ `repository_root`), record `(worktreeRoot,
  branch, observedAt)` as the session's inferred worktree, refreshing the stamp.
- `railTitle` defers to the inferred worktree **only** when the live context is
  uninformative — no distinct current worktree, and the branch is absent or the
  default (`main`/`master`). A live feature branch or a real current worktree
  always wins; the inference never overrides ground truth.
- The inferred label expires after `kStickyWorktreeTtl` (30 min) with no new
  observation, so a session that stops touching the worktree reverts to `main`.
  Each re-observation (including a repeated `git -C worktrees/x`) refreshes it.

### Consequences that fall out for free

- `indistinguishableRailRows` keys off `railTitle`, so two root rows now driving
  *different* worktrees get different titles and stop being flagged
  indistinguishable — the session-id suffix drops exactly when there is finally
  something better to show, and stays when there is not (same worktree / none).
- The meta line (`repo`, plus a distinct current worktree) is unchanged: a root
  row leads with the inferred worktree and still shows `triage` beneath.
- The hover/glance card keeps showing the **live** context (branch `main`, no
  current worktree). That is deliberate: the rail lead is an inference for
  findability; the card is ground truth.

### Testability

`DateTime.now()` in a getter is untestable, so the logic lives in
`railTitleAt(DateTime now)` (the `railTitle` getter passes real time) and
`applyContext(..., {DateTime? now})` stamps the observation. Tests drive both
clocks explicitly. No periodic timer is added, so no `runningUnderFlutterTest`
gating is needed (unlike the activity ticker).

## Plan

1. `flutter/triage_client/lib/main.dart`
   - Add top-level `const Duration kStickyWorktreeTtl = Duration(minutes: 30);`.
   - `SessionVm`: add private `_inferredWorktreeRoot`, `_inferredBranch`,
     `_inferredWorktreeAt`.
   - Add `void applyContext({repoRoot, worktreeRoot, branch, cwd, updateCwd =
     true, DateTime? now})` that assigns the live fields (cwd only when
     `updateCwd`) and records a distinct linked worktree via a private
     `_recordInferredWorktree`.
   - Split `railTitle` into `String get railTitle => railTitleAt(DateTime.now())`
     and `String railTitleAt(DateTime now)` implementing the deferral rule, with
     `_isDefaultBranch` and `_freshInferredWorktreeLabel(now)` helpers.
   - Record in the constructor body too (so an attach directly at root after a
     prior worktree op is covered on reconnect via seed anyway; harmless when a
     fresh VM has no worktree).
   - Route the **seed** path (`updateCwd: false`) and the **live**
     `session_context_updated` handler through `applyContext`.
2. `flutter/triage_client/test/session_rail_identity_test.dart`
   - New `railTitle inferred worktree` group: root/`main` row leads with an
     observed worktree; expires after the TTL back to `main`; a live feature
     branch is never overridden; a distinct *current* worktree still wins; a
     later different worktree replaces the inferred one; never-observed stays
     `main`; the existing branch/worktree/fallback tests still hold.
3. Validate: `flutter analyze --no-fatal-infos`, `flutter test`.
4. `/review-fix-loop max`, then open a PR (with confirmation).
