# 000066 — fix/terminal-scroll-anchor-on-trim

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch fix/terminal-scroll-anchor-on-trim

## Intent

On the native/desktop build, scrolling up while output streams causes the
viewport to drift (the content under the user keeps moving up). New output should
append below without moving a scrolled-up viewport, and stay pinned to the bottom
when the user is at the bottom. Confirmed by the user: native build, only after
heavy output.

## Research & Discoveries

- 2026-06-11T22:06-0700 Native pane renders via `xterm.dart`
  (`terminal_pane_stub.dart` → `xt.TerminalView`); web uses xterm.js. xterm.dart
  already implements stick-to-bottom (`render.dart` `_stickToBottom`), and our
  code only force-scrolls on session select / resume-from-sleep
  (`focusCursorRevision`), never on output. So below the scrollback cap, behavior
  is already correct.
- 2026-06-11T22:06-0700 Root cause is the scrollback trim at `maxLines: 10000`
  (`main.dart`). xterm.dart measures scroll offset from the top of the buffer and
  does not compensate `offset.pixels` when lines are trimmed off the top
  (`IndexAwareCircularBuffer.push` bumps `_absoluteStartIndex`), so a scrolled-up
  viewport drifts one line per trimmed line.
- 2026-06-11T22:06-0700 `BufferLine` (public, `package:xterm/xterm.dart`) mixes
  in `IndexedItem` with a public `index` getter that decreases as lines trim
  above it and `attached` that flips false once the line is trimmed. This lets us
  anchor the viewport to a buffer line using only public API. `lineHeight` is on
  `TerminalViewState.renderTerminal`.

## Decisions

- 2026-06-11T22:06-0700 Anchor-to-buffer-line over forking xterm.dart or bumping
  maxLines — thin wrapper, public API only, fixes the real invariant
  (top-relative content stability) without touching the package.

## What Changed

- 2026-06-11T22:24-0700 `flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart`
  (new) — `TerminalScrollAnchor`: pure logic that pins the viewport to a
  scrollback `BufferLine` and computes the corrected scroll offset as the buffer
  trims. Extracted so it's unit-testable without a laid-out render tree.
- 2026-06-11T22:24-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`
  — wired the anchor in: capture on user scroll (`_onScrollChanged`/
  `_captureScrollAnchor`), re-pin after each terminal change via a post-frame
  callback coalesced per frame (`_onTerminalContentChanged`/`_repinScrollAnchor`).
  Listeners added/removed in `_bindTerminal`/`_unbindTerminal`, scroll listener
  in `initState`/`dispose`, anchor cleared on session swap in `didUpdateWidget`.
  A `_suppressAnchorCapture` guard stops our own `jumpTo` from re-capturing.
- 2026-06-11T22:24-0700 `flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart`
  (new) — drives a real `xt.Terminal` past `maxLines` and asserts the anchor's
  desired offset follows the pinned line through trims, stays put at the bottom,
  and drops once the line is trimmed away.

### Copilot review feedback (PR #73)

- 2026-06-15T21:36-0700 `terminal_scroll_anchor.dart` — bottom-detection
  threshold was a fixed `1.0px`; the docstring promised "within a line". Switched
  to `maxScrollExtent - lineHeight` so the anchor releases a full line shy of the
  bottom and matches xterm.dart's stick-to-bottom hand-off.
- 2026-06-15T21:36-0700 `terminal_pane_stub.dart` — wrapped `position.jumpTo` in
  `_repinScrollAnchor` in `try/finally` so `_suppressAnchorCapture` always resets;
  a throwing `jumpTo` (transient scroll-range issue) would otherwise wedge the
  guard on and silently stop all future anchor capture.
- 2026-06-15T21:36-0700 `terminal_scroll_anchor_test.dart` — `_fullTerminal` now
  writes 3 extra lines after the buffer caps so the trim path actually runs before
  assertions (matching its docstring), and tests compute `maxScrollExtent` as
  `(lineCount - viewHeight) * lineHeight` via a `_maxExtent` helper instead of full
  content height, so clamping/bottom-detection see the value the widget passes in.

## Issues

- 2026-06-11T22:24-0700 `TerminalPane` renders a plain fallback view under
  `FLUTTER_TEST` (no real `TerminalView`/`ScrollController`), so a widget test
  can't exercise the scroll path. Resolved by extracting `TerminalScrollAnchor`
  and unit-testing it against a real xterm.dart buffer; the widget wiring itself
  is validated manually. Full `flutter test` (86 tests) and `flutter analyze`
  (clean on changed files) pass.

## Progress

- [x] Diagnose root cause (scrollback-trim drift in xterm.dart)
- [x] Write plan 000066-01
- [x] Implement anchor capture + re-pin in `terminal_pane_stub.dart`
- [x] `flutter analyze` + `flutter test` + new regression test
- [ ] Commit, push, open PR

## Commits

- d0f25b6 — fix(client): keep terminal scroll position anchored across scrollback trims
- HEAD — fix(client): address PR #73 review (anchor threshold, jumpTo guard, test extents)
