# Plan: fix terminal scrollback reflow on resize (Flutter client)

## Thinking

**Symptom (user report + screenshot).** Resizing the Flutter desktop client
(`Triage.app`) reflows only the current visible text; scrollback history keeps
its old wrapping. Worse, a full-screen TUI running in the session (Claude Code)
renders corrupted after a resize — digits from its in-place status updates
(timers, token counts) overwrite letters elsewhere ("Bunning", "op5ional",
"Backgrou33", "l141t").

**Root cause.** `flutter/triage_client/lib/main.dart:210-214` constructs the
session's `xt.Terminal` with `reflowEnabled: false`. xterm-4.0.0's resize
(`buffer.dart` ~464) then takes the non-reflow branch:

```dart
if (terminal.reflowEnabled && !isAltBuffer) {
  reflow(lines, oldWidth, newWidth);            // re-wrap the whole buffer
} else {
  lines.forEach((item) => item.resize(newWidth)); // just pad/truncate each line
}
```

With reflow off, existing lines are only padded (widen) or truncated (narrow) —
their old wrap points are frozen. That is both symptoms at once:
- Scrollback keeps old wrapping (the visible "current text" only looks right
  because the program repaints it at the new width after SIGWINCH).
- The program's differential repaint after SIGWINCH collides with mis-padded /
  mis-truncated cells instead of a cleanly reflowed grid → overlapping garbage.

The daemon side is already correct: on resize it replays the whole session log
at the new width (`crates/triaged/src/session.rs:3440 reflow_from_log`). The bug
is confined to the client's local xterm buffer.

**Why `reflowEnabled: false` exists.** `git log -S` shows it landed in the
initial scaffold (#54) as a conservative default, not a fix for any known reflow
bug. Flipping it regresses nothing intentional.

**Safety: scroll-anchor interaction.** `lib/terminal/terminal_scroll_anchor.dart`
pins the viewport by holding a raw `xt.BufferLine` and reading `line.index` /
`line.attached`. xterm reflow does `lines.replaceWith(reflowResult)`, which
`_detach()`es every old line (`circular_buffer.dart:234`) and re-adopts the
reflowed set. Consequences:
- A held anchor line that reflow reused → re-attached with a corrected `index` →
  `desiredOffset` stays correct.
- A held anchor line that reflow merged/discarded → `attached == false` →
  `desiredOffset` already returns null and drops the anchor (line 59), so the
  view falls back to following the bottom. Graceful, not corruption.

**Safety: selection anchors.** `_selectionAnchor` is a `CellOffset` (coords),
guarded by a buffer-identity check and clamped into the current grid in
`_applySelection`. Reflow replaces lines *within* the same Buffer object, so the
identity guard still holds; a mid-resize shift-click could extend from a shifted
coordinate, but it is clamped and is a rare edge. No corruption path.

**Sufficiency.** Enabling reflow makes the client behave like a real terminal
(iTerm/Terminal/Ghostty all reflow), which is exactly what Claude Code's
SIGWINCH repaint assumes — so the flip should fix both the scrollback wrapping
and the live distortion. Alt-screen apps (vim/htop) are unaffected: reflow is
skipped for the alt buffer, which has no scrollback and fully repaints anyway.

**Scope.** There is exactly one `xt.Terminal` in the client — the interactive
session terminal at main.dart:210 — so the flip is the whole client-side change.
The `maxLines: 1` sites in main.dart are Flutter `Text` widgets (title/subtitle),
not terminals. The web pane (xterm.js) is a different engine and reflows already;
out of scope.

## Plan

1. **The fix.** In `flutter/triage_client/lib/main.dart:212`, change
   `reflowEnabled: false` → `reflowEnabled: true`. Add a short comment noting
   real terminals reflow and that the scroll anchor tolerates the line-object
   swap via `line.attached`.

2. **Regression test.** Add a widget/unit test in `flutter/triage_client/test/`
   (alongside the existing terminal tests) that:
   - writes soft-wrapped content wider than a narrow width into the real
     `xt.Terminal`,
   - resizes to a wider width,
   - asserts the previously-wrapped scrollback line is now rejoined on one row
     (i.e. reflow actually ran), which fails with `reflowEnabled: false`.
   Mutation-check it: revert the flag and confirm the test fails first.

3. **Scroll-anchor guard test (if not already covered).** Add/confirm a
   `terminal_scroll_anchor` test that a reflow-driven `replaceWith` detaching the
   anchored line makes `desiredOffset` return null (anchor dropped, follow
   bottom) rather than throwing.

4. **Validate CI-locally:** `flutter analyze` clean, `flutter test` green.

5. **On-device verification:** `flutter build macos --release`, replace
   `/Applications/Triage.app`, run Claude Code in a session, then drag-resize the
   window narrower and wider. Confirm (a) scrollback re-wraps, and (b) no
   character-overlap corruption in the live frame. Screenshot before/after.

6. **`/review-fix-loop max`** until clean.

7. Devlog updated throughout. Do **not** commit / push / open a PR without
   explicit confirmation.

## Verification

- `flutter analyze` — no new issues.
- `flutter test` — all green, including the new reflow regression test
  (mutation-verified against the reverted flag).
- Manual: resized `Triage.app` with Claude Code attached shows reflowed
  scrollback and no distortion.
