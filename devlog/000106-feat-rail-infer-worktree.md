# 000106 — feat/rail-infer-worktree

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/rail-infer-worktree

## Intent

The side rail leads most rows with `main`. Sessions start in the repo root (the
primary checkout, always on `main`), and `SessionVm.railTitle` is branch-first,
so every root row opens with the same uninformative word while the part that
differs is demoted to a session-id suffix. Make that first line name the
worktree a root session is actually driving.

## What Changed

- 2026-07-22T16:47-0700 `flutter/triage_client/lib/main.dart` — `SessionVm` now
  remembers the last distinct linked worktree it was observed on
  (`_inferredWorktreeRoot`/`_inferredBranch`/`_inferredWorktreeAt`) and
  `railTitle` leads a root/`main` row with it. `railTitle` split into a
  `DateTime.now()` getter and a testable `railTitleAt(now)`; the deferral fires
  only when the live context is uninformative (no distinct current worktree, and
  the branch absent or `main`/`master` per `_isDefaultBranch`), so a real
  current worktree or a live feature branch always wins. The inferred label
  expires after `SessionVm.stickyWorktreeTtl` (30 min) with no new observation
  (`_freshInferredWorktreeLabel`). A new `applyContext` is the single funnel for
  every context source — the attach constructor, the connect-time seed (with
  `updateCwd: false`, since the bulk response carries no cwd), and the live
  `session_context_updated` handler — and records the worktree via
  `_recordInferredWorktree`. A root observation leaves the memory intact rather
  than clearing it, which is what lets the label survive the gaps between
  `git -C worktrees/x` commands.
- 2026-07-22T16:47-0700 `flutter/triage_client/test/session_rail_identity_test.dart`
  — new `railTitle inferred worktree` group: a root row leads with the worktree
  it was seen driving; the label expires after the TTL and a fresh observation
  refreshes it; a live feature branch and a distinct current worktree are never
  overridden; a later worktree replaces the earlier inference; a never-touched
  row stays on `main`; the inferred lead uses the worktree leaf when its branch
  is empty; and an attach straight into a worktree survives a revert (the
  constructor seed).
- 2026-07-22T17:10-0700 Review-round hardening (`/review-fix-loop max`, 4
  reviewers): pinned the inference to the repo it belonged to
  (`_inferredRepoRoot`) and gated `railTitleAt` on `repoRoot != null`, so a
  session that leaves the repo (to `/tmp`) or moves to a *different* repo's
  `main` shows its own location, never the old worktree; `_recordInferredWorktree`
  now reuses `worktreeName`'s distinctness test instead of duplicating it (and
  drops its always-redundant params); `kStickyWorktreeTtl` became the
  `SessionVm.stickyWorktreeTtl` static const to match the file's naming; the
  inferred label filters a default branch (`master`) to the worktree leaf,
  mirroring the live path. Per a user decision, the hover glance card heading and
  screen-reader label now follow the inference too, via `glanceTitleAt(now)` and
  a shared `_activeInferredLead`, with the rail `itemBuilder` resolving one `now`
  for both title and label per frame — so the visible line, the card, and the
  label never disagree and two inferred rows stay distinguishable to assistive
  tech. New tests cover leaving-the-repo, the different-repo guard, the
  default-branch leaf, and the glance title following/reverting with the title.

## Decisions

- 2026-07-22T16:20-0700 Client-side, not daemon — Every worktree observation
  already reaches the client as a context field, and `git -C worktrees/x`
  chdirs git into the worktree so the daemon *does* report it, just transiently.
  Making the memory client-side is zero daemon/wire change; the reliability
  ceiling ("did the daemon catch the `git -C` process at least once") is
  unchanged and a daemon-side enhancement could later raise it without touching
  this contract. Smallest surface that satisfies the accepted behavior (sticky,
  may flicker, reverts when idle).
- 2026-07-22T16:20-0700 Inference never overrides ground truth — It only fills
  in when the live lead would be `main`/absent with no current worktree. A
  feature branch on the primary checkout, or a session genuinely inside a
  worktree, is already informative and is shown as-is. The hover/glance card
  keeps the *live* context (branch `main`, no worktree) deliberately: the rail
  lead is an inference for findability, the card is ground truth.
- 2026-07-22T16:20-0700 Match `main`/`master` by name — The client has no cheap
  way to ask git which branch is default, and the user treats the primary
  checkout as synonymous with `main`. Matching those two names is the honest
  approximation.
- 2026-07-22T16:20-0700 30-minute TTL — Long because these are long-lived agent
  sessions that revisit a worktree every few minutes while active, refreshing
  the stamp; the window only expires once the session truly stops touching it.
- 2026-07-22T17:10-0700 Hover card and screen-reader label follow the inference
  (user decision) — Leaving them on the live context left the card heading
  contradicting the visible line and gave assistive tech two identical labels
  for two visually distinct rows. `glanceTitleAt` now reads "repo · <inferred>"
  when the inference is leading, while the card *body* keeps listing the live
  branch/cwd as ground-truth detail. The workspace header is untouched — it keeps
  `displayTitle`, since it has no sibling to disambiguate against.

## Research & Discoveries

- 2026-07-22T16:10-0700 `git -C <path>` chdirs the `git` process into `<path>`
  before running, so while a `git -C worktrees/x …` command runs the foreground
  process's cwd *is* the worktree. The daemon's `resolve_session_context`
  (`crates/triaged/src/session.rs`) polls the foreground pgid's cwd every 750 ms
  (`CWD_POLL_INTERVAL`) for non-OSC-7 shells (zsh), so it can observe and
  broadcast the worktree — the signal is transient, not absent.
- 2026-07-22T16:10-0700 The in-a-worktree case already worked end to end: live
  `session_context_updated` (main.dart) mutates a row's branch/worktree as it
  `cd`s. Only the root-on-`main` case was unserved.

## Issues

- 2026-07-22T16:05-0700 First reading of Copilot-style concern about the signal
  being unavailable was wrong: the worktree *is* observable via the transient
  `git -C` cwd. The fix is stickiness, not new signal extraction.

## Lessons Learned

- Put clock-dependent logic behind a `…At(DateTime now)` method with a
  `DateTime.now()` convenience getter, mirroring the existing
  `formatRelativeActivity(stamp, now)` — no fake-async or `runningUnderFlutterTest`
  gating needed since no periodic timer is introduced.

## Next Steps

- If transient capture proves too lossy for very fast `git -C` commands, a
  daemon-side enhancement (scan the foreground subtree's argv for
  `worktrees/<name>` tokens, or lengthen the observation) can raise reliability
  without changing the client contract.

## Commits

- HEAD — feat(triage_client): lead a root/main rail row with the worktree it drives
