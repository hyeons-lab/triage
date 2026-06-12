# Plan 000066-01 — Native terminal: keep scroll position anchored when scrollback trims

## Thinking

### Symptom
On the desktop/native build, when the user scrolls up (so they are no longer
pinned to the bottom) and new output keeps streaming, the viewport "keeps
changing" — the content they are reading drifts upward. Desired behavior:

- Scrolled up → keep the same content under the viewport; new output appends
  below without moving what the user is looking at.
- Scrolled to the bottom → stay pinned to the bottom (follow new output).

### Root cause
The native pane renders through `xterm.dart` (`terminal_pane_stub.dart` →
`xt.TerminalView`). xterm.dart already implements stick-to-bottom correctly
(`render.dart`: `_stickToBottom = _scrollOffset >= _maxScrollExtent`, applied in
`performLayout`), and our code does not force-scroll on output (only on session
select + resume-from-sleep via `focusCursorRevision`). So below the scrollback
cap the view is stable and content appends below — correct.

The drift appears only after heavy output, once the buffer reaches its cap
(`maxLines: 10000`, set in `main.dart`). xterm.dart measures the scroll offset
from the **top** of the buffer (`_scrollOffset = _offset.pixels`,
`_maxScrollExtent = terminalHeight - viewportHeight`, where `terminalHeight =
buffer.lines.length * cellHeight`). When the buffer is full, each new line drops
the oldest line off the top (`IndexAwareCircularBuffer.push` →
`_absoluteStartIndex++`). Total height stays constant, so `_maxScrollExtent`
stays constant and xterm.dart leaves `offset.pixels` unchanged — but the content
shifted up by one line. At a fixed pixel offset the viewport now shows the next
line down. Net effect: one line of upward drift per trimmed line. This is a
known gap in xterm.dart (it does not compensate the scroll offset on trim).

### Fix approach — anchor to a buffer line while scrolled up
xterm.dart's `BufferLine` mixes in `IndexedItem`, which exposes a public `index`
getter computed as `_absoluteIndex - _owner._absoluteStartIndex`. As lines are
trimmed off the top, a retained `BufferLine`'s `index` decreases by exactly the
number of trimmed lines, and `attached` flips to false once the line itself is
trimmed away. `Buffer.lines` and `BufferLine` are both public (exported via
`package:xterm/xterm.dart`).

So we pin the viewport to a specific buffer line:

1. Whenever the **user** scrolls, capture an anchor = the `BufferLine` currently
   at the top of the viewport, plus the sub-line pixel remainder. If the user is
   at the bottom, clear the anchor (let xterm's stick-to-bottom drive).
2. On every terminal change, after layout, if an anchor is held and still
   attached, re-pin: `desired = anchor.index * lineHeight + withinLineOffset`,
   clamped to `[0, maxScrollExtent]`, and `jumpTo` it if it moved. This exactly
   cancels the trim drift. If the anchor was trimmed away (`!attached`), drop it.

`lineHeight` and the render object come from
`_terminalViewKey.currentState.renderTerminal.lineHeight`. We guard a
re-entrancy flag so our own `jumpTo` doesn't re-capture the anchor.

### Why not alternatives
- Bumping `maxLines` only delays the cap; not a fix and costs memory.
- Forking xterm.dart to compensate in `performLayout` is heavier and harder to
  maintain than a thin wrapper anchor that only uses public API.
- Distance-from-bottom anchoring is wrong: new output is appended below the
  viewed content, so the viewed line's distance-from-bottom grows; top-relative
  anchoring (by buffer line) is the correct invariant.

### Risks / edge cases
- Drag-select auto-scroll also calls `jumpTo`; skip anchor capture while
  `_dragSelecting` so the two don't fight.
- Session swap replaces `widget.terminal`; reset the anchor in `didUpdateWidget`.
- First frame / mid-rebuild: guard on `_scrollController.hasClients` and wrap
  render access in try/catch (the render object asserts a laid-out viewport).
- Must not interfere with stick-to-bottom: while at bottom the anchor is null and
  we no-op, leaving xterm.dart in control.

## Plan

1. Add anchor state to `_TerminalPaneState` in
   `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
   - `xt.BufferLine? _scrollAnchorLine;`
   - `double _scrollAnchorWithinLine = 0;`
   - `bool _suppressAnchorCapture = false;` (re-entrancy guard)
2. Add helpers:
   - `double? _lineHeight()` — read `renderTerminal.lineHeight`, guarded.
   - `_captureScrollAnchor()` — from current scroll position + lineHeight, set or
     clear the anchor (clear when at/near bottom or while drag-selecting).
   - `_repinScrollAnchor()` — recompute desired offset from the anchor line's
     current `index` and `jumpTo` if moved; drop anchor if detached.
3. Wire listeners:
   - `_scrollController.addListener(_onScrollChanged)` → capture anchor unless the
     change came from our own programmatic jump.
   - Listen to the terminal (`_terminal.addListener(_onTerminalContentChanged)`)
     and on change schedule `_repinScrollAnchor` via a post-frame callback (so it
     runs after xterm.dart's `performLayout` updated content dimensions). Add/
     remove this in `_bindTerminal`/`_unbindTerminal` so it follows session swaps.
4. Reset the anchor on terminal swap in `didUpdateWidget`; dispose listeners in
   `dispose`.
5. Validate: `flutter analyze`, `flutter test`. Add a unit/widget test that
   drives the terminal past `maxLines` while scrolled up and asserts the visible
   top line is stable (anchor `index` re-pinned), plus that bottom-pinned stays
   at bottom.
6. Devlog + plan + code committed together; open PR.
