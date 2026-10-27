# 000174: fix/hardware-shift-tab-hardening

## Agent

Antigravity @ triage branch fix/hardware-shift-tab-hardening

## Intent

Harden hardware `Tab` and `Shift+Tab` handling across desktop and web clients so modifier chords (`Ctrl+Tab`, `Alt+Tab`, `Cmd+Tab`), exited sessions, and retained web session containers behave cleanly without swallowing browser/OS shortcuts or duplicating keystrokes (`devlog/plans/000174-01-fix-hardware-shift-tab-hardening.md`).

## What Changed

- `2026-10-27T13:35-0700` `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`: Ignore `Tab` when `Control`, `Alt`, or `Meta` modifiers are active so browser and OS shortcuts proceed without emitting spurious characters into the PTY; reset saved scroll offsets and jump to the bottom (when `hasContentDimensions` is true) when `Tab`/`Shift+Tab` is typed.
- `2026-10-27T13:35-0700` `flutter/triage_client/lib/widgets/terminal_pane_web.dart`: Make `_tabDispatchInProgress` and `_shouldDispatchTab()` static so the microtask deduplication latch is shared across cached/resumed session containers and newly mounted pane instances; ignore `Tab` when `Control`, `Alt`, or `Meta` keys are held or when the session is exited; consolidate dispatch into `_dispatchTabInput({required bool shiftKey})` and delegate from `attachCustomKeyEventHandler` to `activePane`.
- `2026-10-27T13:35-0700` `flutter/triage_client/test/terminal_hardware_key_test.dart`: Test `Tab` and `Shift+Tab` across all `TargetPlatform.values` and add widget tests for `Ctrl+Tab`/`Alt+Tab`/`Cmd+Tab` modifier chords, `controller.notifyInteraction()`, `isExited` focus pass-through, and modal dialog route suppression.

## Decisions

- `2026-10-27T13:35-0700` Make web `_tabDispatchInProgress` static: Terminal containers and `_term` instances are retained across session switches, so making `_tabDispatchInProgress` static ensures adopted session containers share the single-turn dispatch latch with newly mounted `_TerminalPaneState` instances.
- `2026-10-27T13:35-0700` Ignore `Tab` when `Ctrl`, `Alt`, or `Meta` are pressed: Standard browser tab switching (`Ctrl+Tab`, `Ctrl+Shift+Tab`) and OS shortcuts (`Alt+Tab`, `Cmd+Tab`) must not be consumed by terminal `Tab` interception.

## Commits

- `HEAD`: fix(terminal): harden hardware Tab and Shift+Tab modifier and lifecycle guards
