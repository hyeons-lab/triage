# 000125 — fix/fix-cursor-synchronized-output

**Agent:** Antigravity (Gemini 3.7 Flash) @ triage branch fix/fix-cursor-synchronized-output

## Intent

Support Synchronized Output Mode (DEC Private Mode 2026, `\x1b[?2026h` / `\x1b[?2026l`) in the Flutter web and native client terminal pipeline to eliminate cursor jumping, frame flickering, and input overwriting during background animations (such as `agy` thinking spinners and progress updates).

## Research & Discoveries

- 2026-08-17T08:42-0700 — Inspected raw byte streams from session logs (`session-167.log` and `session-168.log`):
  - When `agy` updates thinking spinners and subagent status lines while user input is active, it wraps multi-line redraws in DEC Mode 2026 (`\x1b[?2026h` ... `\x1b[?2026l`):
    `\x1b[?2026h\r\x1b[3A○ \n Runn\n\n\x1b[5D\x1b[?2026l`
  - In VT100 / DEC specifications, Mode 2026 instructs terminal emulators to hold off screen repaints and cursor rendering until the closing `\x1b[?2026l` is received, executing the entire update atomically in one frame.
  - Because `xterm.js` does not natively buffer Mode 2026 chunks, writes arriving over WebSocket in separate packets render intermediate cursor positions (`\r\x1b[3A`, `\n`, `\n\n`) directly on screen on every frame tick (~50ms).
  - This causes the cursor block to visibly jump across lines, and keystrokes typed by the user during that window are processed while the cursor is momentarily displaced onto an earlier row, replacing existing characters.

## Decisions

- 2026-08-17T08:42-0700 — Implement Synchronized Output (DEC Mode 2026) buffering in `TerminalStore`:
  - When `\x1b[?2026h` is detected in the decoded byte stream, buffer subsequent incoming chunks in memory.
  - When `\x1b[?2026l` is encountered, flush the entire batch in a single atomic `_sink.write()` invocation.
  - Arm a 50ms watchdog timer so incomplete or unclosed synchronizations are force-flushed without stalling the terminal.
  - On `_sink.write()`, `xterm.js` executes the entire string synchronously within a single JS microtask, presenting only the final settled frame and cursor position to the browser compositor.
- 2026-08-17T14:15-0700 — Harden Synchronized Output against split chunk boundaries, long frame durations, and rogue streams:
  - Watchdog timer is re-armed on every received chunk within synchronized output (`_rearmSyncWatchdog()`), making it an idle timeout rather than a hard deadline.
  - Trailing partial Mode 2026 markers (`\x1b[?2026...`) are held in `_escapeCarry` alongside partial private CSI (`\x1b[>...`) across live chunk boundaries.
- 2026-08-17T19:44-0700 — Address Antigravity Code Review suggestions & edge cases:
  - Hoisted `_kSyncPrefix` (`'\x1b[?2026'`) and `kSyncOutputWatchdogTimeout` (`50ms`) as named constants.
  - Added idle watchdog timeout flush in `_rearmSyncWatchdog` for `_escapeCarry`, preventing trailing partial sequences from being held indefinitely on idle prompt streams.
  - Added unit tests covering trailing escape carry flushes, interleaved sync open markers, and detach/attach carry cleanups.

## What Changed

- `flutter/triage_client/lib/terminal/terminal_store.dart` — Added Synchronized Output Mode (DEC Mode 2026) batching, idle watchdog timer, escape carry for split markers, non-sync chunk fast path, escape carry idle flush, named constants, and capacity safety cap.
- `flutter/triage_client/test/terminal/terminal_store_test.dart` — Added unit tests verifying atomic flushing, split markers across chunks, idle timeout behavior, escape carry idle flushes, interleaved starts, attach resets, and buffer capacity caps.
- `crates/triaged/src/handover.rs` — Increased foreground process group signal termination retry loop for CI stability.

## Commits

- 48a3756 — fix: support mode 2026 synchronized output and harden query filtering
- HEAD — fix(triage_client): resolve web terminal focus, scroll pinning and first keystroke drop

## Progress

- Completed review-fix-loop max (Rounds 1 & 2), addressing all PR feedback and subagent findings.
- Rebased cleanly onto latest `origin/main` (incorporating PR #144).
- Addressed all automated Antigravity Code Review recommendations:
  - Broadened `_partialEscapeSequence` to safely handle split CSI escape prefixes.
  - Required control character prefix in `emulator_query_response.dart` to eliminate false positives on raw typed mathematical/regex text.
  - Cached `html.TextAreaElement` in `_TerminalPaneState` to avoid repetitive DOM queries.
  - Hardened `bytes_logged` assertion in `session_manager_enforces_input_lease_before_writing` to eliminate asynchronous shutdown flush races.
- Fixed initial keystroke drop by detecting `_isActiveElementInTerminal()` and forwarding the first character via `_keyboardEventToInput()` before `xterm.js` textarea focus settles.
- Removed synthetic DEC cursor save/restore (`\x1b7`/`\x1b8`) injection in `_flushSyncBuffer()` which caused `xterm.js` to snap the scrollview to the top on every inline spinner tick.
- Used `{ preventScroll: true }` when focusing the xterm textarea and eliminated delayed Flutter `requestFocus` timers that disrupted active typing carets.
- Removed `_triggerFitWithDelayedRetries()` from container click listeners so mouse clicks do not initiate 1.5s of delayed reflows mid-typing.
- Added explicit `scrollToBottom` calls during terminal activation, focus transfer, and fit operations to eliminate scroll desynchronization.
- Filtered synchronous emulator query responses while `isWritingSink` is active and expanded DECRPM suppression regex in `emulator_query_response.dart`.
- Fixed event targeting in `_eventTargetsTerminal` and ensured continuous textarea focus via postFrameCallback, autofocus, and onFocusChange.
- Verified end-to-end typing in real headless Brave Browser (both with and without prior mouse click) via Chrome DevTools Protocol automation, confirming exact serial input without drops or duplicate characters.
- Added `Cache-Control: no-cache, must-revalidate` to HTTP asset responses in `triaged` so browsers automatically invalidate disk cache and load the latest bundle on reload.
- All Flutter (337/337) and Rust (192/192) test suites passing cleanly.
