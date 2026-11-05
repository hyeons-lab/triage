# 000177-01: Migrate Flutter client from xterm 4.0.0 fork to xterm2

## Thinking

`flutter/triage_client` currently depends on `xterm: ^4.0.0` pinned via `dependency_overrides` to a custom git commit (`7e867fe15be8e76cca5651f3def8876d801df9a7`), plus several client-side workarounds in `terminal_store.dart` and `terminal_pane_stub.dart` for bugs in `xterm 4.0.0`:
- `writeToXterm` in `lib/terminal/terminal_store.dart` splits strings on `CSI Ps Z` (`CBT`) and `CSI Ps I` (`CHT`) to emulate backward/forward tab stops that `xterm 4.0.0` left unimplemented.
- `_sendWheelStep` and `_onTerminalOutput` in `lib/widgets/terminal_pane_stub.dart` work around `xterm 4.0.0` encoding `TerminalMouseButton.wheelUp`/`wheelDown` as `68`/`69` (shifted) instead of `64`/`65` (unshifted).
- `test/terminal/scrollback_clear_test.dart` tests the `xterm 4.0.0` fork's workaround where `IndexAwareCircularBuffer.trimStart` left trimmed lines `attached == true` with negative `index` because `xterm 4.0.0` crashed in release builds if trimmed lines were detached.

In `xterm2` (`5.2.0`):
1. `IndexAwareCircularBuffer.trimStart` advances `_absoluteStartIndex += count` AND detaches trimmed lines (`_dropChild(cyclicIndex)`), while `TerminalController.selection` checks `if (!base.attached || !extent.attached) return null;` and `TerminalScrollAnchor.desiredOffset` checks `if (!line.attached) return null;`.
2. `IndexAwareCircularBuffer.replaceWith` detaches unused lines and resets `_startIndex = 0; _length = 0;` before pushing reflowed lines.
3. `Buffer.resize` tracks cursor position across width reflow using `cursorAnchor`.
4. `TerminalParser` natively handles `CSI Ps I` (`_csiHandleCursorForwardTabulation` -> `handler.moveForwardTabs`) and `CSI Ps Z` (`_csiHandleCursorBackwardTabulation` -> `handler.moveBackwardTabs`), `CSI s`/`CSI u`, `CSI ? 2026 h/l` (DEC Synchronized Output), `modifyOtherKeys`, and Kitty keyboard protocol.
5. `TerminalMouseButton.wheelUp`/`wheelDown`/`wheelLeft`/`wheelRight` use standard unshifted IDs `64`/`65`/`66`/`67`, and `RenderTerminal.mouseEvent` uses `_getViewportCellOffset` (0-based viewport coordinates).

## Plan

1. Update `flutter/triage_client/pubspec.yaml`:
   - Move `xterm2: ^5.2.0` from `dev_dependencies` to `dependencies`.
   - Remove `xterm: ^4.0.0` and the `dependency_overrides` block for `xterm`.
2. Update all `package:xterm/xterm.dart` imports to `package:xterm2/xterm.dart` across `lib/`, `test/`, `integration_test/`, and `tool/`:
   - `lib/main.dart`
   - `lib/terminal/terminal_scroll_anchor.dart`
   - `lib/terminal/terminal_selection.dart`
   - `lib/terminal/terminal_store.dart`
   - `lib/widgets/terminal_pane_stub.dart`
   - `test/terminal/scrollback_clear_test.dart`
   - `test/terminal/terminal_reflow_test.dart`
   - `test/terminal/terminal_scroll_anchor_test.dart`
   - `test/terminal/terminal_selection_test.dart`
   - `test/terminal/terminal_store_test.dart`
   - `test/terminal_hardware_key_test.dart`
   - `test/widget_test.dart`
   - `integration_test/replay_bench_test.dart`, `test_driver/replay_bench_driver.dart`, and `tool/parse_bench.dart`
3. Simplify obsolete `xterm 4.0.0` workarounds:
   - In `lib/terminal/terminal_store.dart`, simplify `writeToXterm` to call `terminal.write(data)` directly.
   - In `lib/widgets/terminal_pane_stub.dart`, simplify `_sendWheelStep` to call `_terminal.mouseInput(up ? xt.TerminalMouseButton.wheelUp : xt.TerminalMouseButton.wheelDown, xt.TerminalMouseButtonState.down, cell)` and remove the `68/69/70/71` -> `64/65/66/67` string replacements in `_onTerminalOutput`.
   - Update comments and `test/terminal/scrollback_clear_test.dart` to reflect `xterm2`'s clean detachment of trimmed scrollback lines on `ESC[3J`.
4. Run `flutter pub get`, `flutter analyze`, and `flutter test` to verify all unit and widget tests pass with zero warnings.
