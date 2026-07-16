# 000090 — fix/terminal-scrollback-reflow

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/terminal-scrollback-reflow

## Intent

Fix the Flutter desktop client reflowing only the visible frame on resize while
scrollback keeps its old wrapping — and the related live-frame corruption where a
full-screen TUI (Claude Code) redraws garbled after a resize. Both are one bug.

## Research & Discoveries

- 2026-07-15T20:20-0700 Root cause is `reflowEnabled: false` on the session
  `xt.Terminal` at `flutter/triage_client/lib/main.dart:212`. With reflow off,
  xterm-4.0.0's resize (`buffer.dart` ~464) only pads/truncates each line instead
  of re-wrapping, so old wrap points freeze. The visible text only looks correct
  because the program repaints it at the new width after SIGWINCH; scrollback
  above gets no repaint and no reflow. The program's differential redraw then
  collides with mis-sized cells → the overlapping-character corruption.

- 2026-07-15T20:20-0700 The daemon already reflows correctly — on resize it
  replays the whole session log at the new width (`reflow_from_log`,
  `crates/triaged/src/session.rs:3440`). The defect is purely the client's local
  xterm buffer.

- 2026-07-15T20:20-0700 `git log -S "reflowEnabled: false"` shows the flag landed
  in the initial Flutter scaffold (#54) as a default, not a fix for a known reflow
  bug — so flipping it regresses nothing intentional.

- 2026-07-15T20:20-0700 Scroll-anchor safety: `terminal_scroll_anchor.dart` holds
  a raw `xt.BufferLine` and reads `line.index`/`line.attached`. xterm reflow does
  `lines.replaceWith(...)`, which detaches every old line
  (`circular_buffer.dart:234`). A discarded anchor line reads `attached == false`
  and `desiredOffset` already drops it (line 59) → view follows the bottom.
  Graceful degradation, no corruption. Selection anchors are clamped `CellOffset`s
  guarded by buffer identity, which reflow preserves.

## Decisions

- 2026-07-15T20:20-0700 Minimal fix: flip the single flag on the interactive
  session terminal — the only `xt.Terminal` in the client. The `maxLines: 1`
  sites in main.dart are Flutter `Text` widgets (title/subtitle), not terminals.
  The web pane (xterm.js) is a different engine that already reflows; out of
  scope.

## What Changed

- 2026-07-15T20:35-0700 `flutter/triage_client/lib/main.dart` — flip the session
  `xt.Terminal` from `reflowEnabled: false` to `true` (with a comment on why and
  on the scroll-anchor tolerance). Single-line behavioral change; no other call
  site touched.

- 2026-07-15T20:35-0700 `flutter/triage_client/test/terminal/terminal_reflow_test.dart`
  — new. Drives a real `SessionVm.terminal`: widening rejoins a soft-wrapped
  scrollback line, narrowing re-splits a line that previously fit, and a hard
  newline is NOT rejoined on widening (reflow must respect logical-line
  boundaries). Guards the flag through the actual object it is set on.

- 2026-07-15T21:05-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`
  — drop the cached shift-click selection anchor in `_onTerminalResize`. Review
  finding: with reflow on, a width resize moves content between rows, so the
  cached `_selectionAnchor` (a buffer coordinate) goes stale — and the existing
  identity guard in `_extendSelectionTo` can't catch it because reflow mutates
  lines within the *same* `Buffer` object. Without this, a shift-click-to-extend
  right after a resize would extend from a pre-reflow row (bounded/clamped, but
  wrong text). The live highlight is unaffected; only the extend-from point is
  invalidated. This regression is specific to enabling reflow — with reflow off a
  width resize did not move rows, so the anchor stayed valid.

## Testing

- 2026-07-15T20:35-0700 `flutter test` — 111 passing (108 prior + 3 new reflow
  tests). `flutter analyze` on the touched files — no new issues (the repo-wide
  count is all pre-existing: generated code, a deprecated `onReorder`, and prior
  null-aware warnings).
- Mutation-checked: reverting the flag to `false` fails the reflow tests first,
  so they discriminate the fix rather than passing regardless. (In the narrowing
  test the discriminating assertion is the one on `KLMNOP` landing on its own
  row; the `isNull` check on the full string is a sanity check that holds under
  plain truncation too — noted in the test comment.)
- The selection-anchor drop in `_onTerminalResize` is a defensive one-liner
  guarded by comments. It is not unit-tested: the pane's shift-click state is
  private and would need a full laid-out `TerminalView` + simulated resize and
  pointer events, disproportionate to a two-field reset. The path it protects is
  a rare sequence (select → resize → shift-click-extend with no fresh drag
  between).

## Review

- 2026-07-15T21:05-0700 `/review-fix-loop max`. Round 1 (three adversarial
  reviewers: reflow correctness/interactions, test quality, conventions/sweep)
  surfaced: (1) the stale selection-anchor regression above [fixed]; (2) the
  narrowing test's `isNull` assertion did not discriminate reflow from truncation
  and its comment overclaimed [comment corrected; the `KLMNOP` assertion is the
  real discriminator]; (3) a coverage gap — no guard that a hard newline is not
  over-joined on widening [test added]. Confirmed clean: scroll-anchor degrades
  gracefully (detached line → drop), no onResize re-entrancy, alt-screen exempt
  from reflow, only one real `xt.Terminal` in the client (the `maxLines: 1` sites
  are `Text` widgets), no AI attribution anywhere.
- 2026-07-15T21:25-0700 Round 2 (two reviewers: the selection-anchor drop, and a
  fresh-eyes sweep) found: (1) the anchor was cleared on *any* resize, but reflow
  only runs on a width change — a height-only resize dropped a still-valid anchor;
  now gated on `width != _terminal.viewWidth` (viewWidth still holds the old width
  because `onResize` fires before the terminal stores the new one); (2) two
  wording inaccuracies — the stub comment said the drop makes shift-click "start a
  fresh selection" (it is a no-op until the next select), and the devlog/plan
  implied multiple `xt.Terminal(maxLines: 1)` constructions when there is one
  terminal and the `maxLines: 1` sites are `Text` widgets. All corrected. Tests
  confirmed sound (first-match + exact-equality can't pass for the wrong reason;
  `getText()` skips blank cells so trailing-cell fragility is a non-issue).

- 2026-07-16T00:35-0700 PR #103 Copilot review claimed the width gate
  (`width != _terminal.viewWidth`) can never be true because `onResize` fires
  after xterm stores the new width. This is a false positive: xterm calls
  `onResize` at `terminal.dart:362`, before `_viewWidth = newWidth` at `:368`, so
  `viewWidth` inside the callback is still the old width. Verified empirically and
  captured the ordering as a regression test (`onResize fires before the terminal
  stores the new width`) so an xterm bump that reordered it would fail loudly
  rather than silently disabling the gate. No code change.

## Next Steps

- On-device verification: rebuild `Triage.app` with the reviewed fixes, install
  to `/Applications`, and resize with Claude Code attached to confirm scrollback
  re-wraps and the live frame no longer corrupts.
- Commit + PR — pending explicit user confirmation.

## Commits

- 639a133 — fix(triage_client): reflow terminal scrollback on resize
- HEAD — test(triage_client): guard onResize-before-viewWidth timing
