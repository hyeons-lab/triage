# Branch Devlog: fix/hardware-shift-tab

## Agent
Antigravity (gemini-2.5-pro) @ triage branch fix/hardware-shift-tab

## Intent
Resolve the issue where users cannot enter Shift+Tab on computers and laptops (desktop and web) to trigger CLI mode toggles (such as Auto-accept or Plan mode toggles in CLIs like Claude Code), whereas on mobile devices it works properly via the on-screen accessory bar key (`⇧tab`).

## Research & Discoveries
- On mobile clients (iOS, Android, mobile web), triage displays an accessory bar with a dedicated `⇧tab` key that calls `onSend('\x1b[Z')` directly, routing cleanly to the session PTY.
- On computer/laptop physical keyboards:
  - In native desktop (`terminal_pane_stub.dart`), `_handleTerminalKeyEvent` only handled copy and paste shortcuts. For `LogicalKeyboardKey.tab`, it returned `KeyEventResult.ignored`. This allowed Flutter's `FocusTraversalPolicy` (`NextFocusIntent` and `PreviousFocusIntent`) to intercept the key event at the focus manager level, navigating focus away from the terminal to adjacent focusable widgets rather than delivering the keystroke to the PTY.
  - In web browsers (`terminal_pane_web.dart`), Tab events were intercepted in multiple locations (`_windowKeyDownListener` and `Focus.onKeyEvent`). Because `_windowKeyDownListener` used `event.stopPropagation()` rather than `event.stopImmediatePropagation()`, Flutter Web's ambient keydown listener on `window` still received the event and dispatched it to `Focus.onKeyEvent`. This caused duplicate `_sendInput('\x1b[Z')` calls in rapid succession (< 1ms apart), causing interactive CLIs with toggles (e.g. Claude Code mode toggle) to immediately toggle on and off.
  - In addition, running under widget tests (`runningUnderFlutterTest()`) replaced the terminal view with a fallback widget hierarchy without a `Focus` node, preventing widget tests from verifying hardware key routing.

## What Changed
- 2026-09-16T08:25-0400 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`: Intercept `LogicalKeyboardKey.tab` in `_handleTerminalKeyEvent`. On `KeyDownEvent` and `KeyRepeatEvent`, dispatch `\x1b[Z` if Shift is pressed and `\t` otherwise via `widget.controller.sendInput(...)`. Return `KeyEventResult.handled` for all Tab events so Flutter focus traversal does not steal focus. Wrap the test fallback widget tree with `Focus(focusNode: _focusNode, autofocus: true, onKeyEvent: _handleTerminalKeyEvent)` so key handling and focus preservation can be exercised in tests.
- 2026-09-16T08:28-0400 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`: Add `_lastTabDispatchMillis` and `_shouldDispatchTab()` deduplication helper to guard against duplicate dispatches across `_windowKeyDownListener`, `attachCustomKeyEventHandler`, and `Focus.onKeyEvent`. Call `event.stopImmediatePropagation()` to prevent sibling listeners on `window` from firing.
- 2026-09-16T08:38-0400 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`: Refine `_shouldDispatchTab()` to use an event-loop microtask latch (`scheduleMicrotask`) instead of a 40ms wall-clock debounce. This eliminates system clock drift/NTP skew vulnerabilities and prevents dropping rapid key repeats across successive event loops while cleanly suppressing duplicate calls within the same DOM event turn.
- 2026-09-16T08:28-0400 `flutter/triage_client/test/terminal_hardware_key_test.dart`: Add widget test suite testing Shift+Tab (`\x1b[Z`), plain Tab (`\t`), key repeat, and focus preservation across macOS, Linux, and Windows target platforms.
- 2026-09-16T08:29-0400 `devlog/plans/000150-01-fix-hardware-shift-tab.md`: Authored implementation plan.
- 2026-09-17T17:55-0400 `devlog/000150-fix-hardware-shift-tab.md`, `devlog/plans/000150-01-fix-hardware-shift-tab.md`: Rebased onto origin/main and renumbered sequence from 000149 to 000150 to resolve collision with merged PR #171.
- 2026-09-17T17:55-0400 `flutter/triage_client/test/terminal_hardware_key_test.dart`: Add widget test verifying plain Tab key repeat without losing focus.

## Decisions
- 2026-09-16T08:25-0400 Return `KeyEventResult.handled` for all Tab events in `_handleTerminalKeyEvent`: Suppressing both KeyDown and KeyUp events for Tab ensures that Flutter's `FocusManager` never initiates `PreviousFocusAction` or `NextFocusAction`, keeping terminal keyboard focus sticky.
- 2026-09-16T08:28-0400 Deduplicate Tab dispatch on web with a 40ms threshold: When the browser fires a DOM keydown event, both `_windowKeyDownListener` and Flutter Web's ambient listener receive it within 0-2ms. A 40ms deduplication window ensures that the same keystroke is dispatched to the session PTY exactly once, while still permitting rapid typing and auto-repeat (> 50ms intervals).
- 2026-09-16T08:38-0400 Switch from wall-clock debounce to event-loop microtask latch: Multi-listener duplicate dispatch occurs within the same DOM event turn. Using `scheduleMicrotask` to reset the dispatch latch guarantees deduplication within that single turn without any dependency on wall-clock time (avoiding negative deltas during clock sync) and without dropping legitimate rapid key repeats across successive event-loop turns.
- 2026-09-17T17:55-0400 Renumber devlog from 000149 to 000150: PR #171 merged to main with sequence number 000149, so rebasing onto main requires incrementing this branch's sequence number to 000150 per AGENTS.md conventions.

## Issues
- Issue: In widget tests, `TerminalPane` uses a fallback `SingleChildScrollView` rendering path that had no `Focus` node attached, causing key events sent via `tester.sendKeyEvent` to not be received by the pane.
  Resolution: Wrapped the `isTest` fallback widget tree with `Focus(focusNode: _focusNode, autofocus: true, onKeyEvent: _handleTerminalKeyEvent)`.

## Commits
HEAD: fix(terminal): support hardware shift+tab backtab key on desktop and web
