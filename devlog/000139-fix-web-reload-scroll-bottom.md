# 000139: Web Terminal Reload Scroll to Bottom and Mobile Text Input

- **Agent:** Gemini 3.8 Flash (High) @ triage branch fix/web-reload-scroll-bottom
- **Intent:** Automatically position terminal views at the bottom (live prompt / cursor) upon web client reload or session load, and fix mobile virtual keyboard text input in the web client.

## What Changed

- **2026-09-06T07:24-0700** devlog/plans/000139-01-web-reload-scroll-bottom.md: Authored implementation plan covering controller replacement fitting in didUpdateWidget, history replay completion notifications through TerminalSink and TerminalController, suppression of programmatic scroll latching, and xterm.js layout settling.
- **2026-09-06T08:18-0700** devlog/plans/000139-02-mobile-web-text-input.md: Authored implementation plan for capturing mobile soft keyboard input events on the helper textarea.
- **2026-09-06T08:28-0700** flutter/triage_client/lib/widgets/terminal_pane_web.dart: Attached beforeinput, input, and compositionend listeners to helper textarea to route virtual keyboard characters, backspace, enter, and paste. Integrated sticky Ctrl disarming and bidirectional deduplication with xterm.js onData. Suppressed programmatic scroll save during buffer clear and restoration.
- **2026-09-06T08:28-0700** flutter/triage_client/lib/terminal/terminal_sink.dart, flutter/triage_client/lib/terminal/terminal_controller_sink.dart, flutter/triage_client/lib/widgets/terminal_pane.dart: Added onHistoryReplayed hook across sink and controller.
- **2026-09-06T08:28-0700** flutter/triage_client/lib/terminal/terminal_store.dart: Invoked onHistoryReplayed when history replay completes.
- **2026-09-06T08:28-0700** flutter/triage_client/test/terminal/terminal_store_test.dart: Added unit tests verifying onHistoryReplayed notification through store and controller sink.

## Decisions

- **2026-09-06T07:24-0700 Decision: History Replay Completion Hook**: Add `onHistoryReplayed()` to `TerminalSink`, implemented via `TerminalControllerSink` to notify listeners on `TerminalController`. This decouples the decoding store from platform rendering while providing views an explicit signal to restore scroll positions once the snapshot is in memory.
- **2026-09-06T07:24-0700 Decision: Always Re-trigger Fit and Replay on Controller Replacement**: When `didUpdateWidget` receives a replaced `controller` with matching session title (the placeholder-to-remote-session transition on reload), do not gate `_triggerFullReplayOrReset()` on `!_initialContentWritten`. The incoming session has never received `onViewFit` and requires fit notification to flush its staged history.
- **2026-09-06T07:24-0700 Decision: Suppress Scroll Capture During Programmatic Replay**: Guard `onScrollCallback` with `_suppressScrollSave` while history is being cleared, decoded, and rendered into xterm.js, preventing transient chunk layout states from latching `_sessionSavedViewportY = 0`.
- **2026-09-06T08:28-0700 Decision: Directly Intercept Helper Textarea Input Events**: Mobile virtual keyboards (such as Gboard and iOS soft keyboards) run in composition mode where xterm.js's internal input filter drops text events. Intercepting beforeinput on the helper textarea, translating input types, and sending directly through the session input router restores soft keyboard input without interfering with hardware keyboards.
- **2026-09-06T08:28-0700 Decision: Bidirectional Input Deduplication**: Track timestamps and text of inputs handled by xterm.js onData and mobile beforeinput with a 100ms window, clearing matched entries immediately to guarantee no dropped or duplicated keystrokes.

## Issues

- None.

## Progress

- [x] Initial research and root-cause diagnosis via Chrome remote debugging and CDP
- [x] Create worktree and branch devlog / plan
- [x] Implement `onHistoryReplayed` in `TerminalSink`, `TerminalControllerSink`, and `TerminalController`
- [x] Wire `onHistoryReplayed` in `TerminalStore._reduceHistory`
- [x] Implement controller replacement fit and replay in `terminal_pane_web.dart`
- [x] Implement `_suppressScrollSave` and post-replay scroll restoration in `terminal_pane_web.dart`
- [x] Implement mobile virtual keyboard input handling and sticky Ctrl integration in `terminal_pane_web.dart`
- [x] Verify test suites across Dart and Rust
- [x] Rebuild web bundle and perform zero-downtime daemon reload
- [x] Commit and open PR

## Commits

- HEAD: fix(web): support virtual keyboard text input and bottom scroll positioning on reload
