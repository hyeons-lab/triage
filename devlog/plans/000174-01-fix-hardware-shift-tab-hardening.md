# 000174-01: Harden hardware Tab and Shift+Tab handling

## Thinking

Following the initial hardware `Tab` and `Shift+Tab` support in PR #172, several edge cases remained in desktop and web `TerminalPane`:
1. Pressing `Ctrl+Tab`, `Ctrl+Shift+Tab`, `Alt+Tab`, or `Cmd+Tab` while the terminal had focus intercepted the `Tab` key and sent `\t` or `\x1b[Z` to the PTY instead of letting browser tab switching or OS shortcuts proceed.
2. On Flutter Web, `_tabDispatchInProgress` was an instance field on `_TerminalPaneState`, whereas `_sessionContainers` and `attachCustomKeyEventHandler` callbacks persist across widget remounts, allowing duplicate `Tab` dispatch across remounted panes.
3. Typing `Tab` or `Shift+Tab` while scrolled up in desktop `TerminalPane` did not reset saved scroll offsets or jump to the bottom like other keyboard interactions.

## Plan

1. Make `_tabDispatchInProgress` and `_shouldDispatchTab()` static in `terminal_pane_web.dart` and consolidate web `Tab` dispatch into `_dispatchTabInput({required bool shiftKey})`.
2. Ignore `Tab` key chords when `Control`, `Alt`, or `Meta` modifiers are pressed across desktop (`terminal_pane_stub.dart`) and web (`terminal_pane_web.dart`).
3. Reset saved scroll positions and jump to bottom (guarded by `hasContentDimensions`) when typing `Tab`/`Shift+Tab` on desktop.
4. Guard `attachCustomKeyEventHandler` and `_windowKeyDownListener` against exited and obscured sessions.
5. Expand `terminal_hardware_key_test.dart` to cover all `TargetPlatform.values`, modifier chords, interaction notifications, exited sessions, and modal routes.
