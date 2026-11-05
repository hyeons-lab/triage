# 000177: feat/xterm2-migration

## Agent
- Antigravity (gemini-3.1-pro) @ triage branch feat/xterm2-migration

## Intent
Migrate `flutter/triage_client` from the brittle `xterm 4.0.0` git fork to `xterm2` (`^5.4.0`), retire the `xterm` `dependency_overrides` block and redundant client-side parser/mouse workarounds that `xterm2` implements natively, and verify parity across scrollback clearing, reflow, scroll anchoring, selection, and mouse reporting.

## What Changed
- `devlog/plans/000177-01-xterm2-migration.md`: created implementation plan.
- 2026-11-04T18:41-0800 `flutter/triage_client/pubspec.yaml`, `flutter/triage_client/pubspec.lock`: promoted `xterm2: ^5.4.0` to `dependencies` and removed `xterm: ^4.0.0` along with its `dependency_overrides` git pin (`7e867fe15be8e76cca5651f3def8876d801df9a7`).
- 2026-11-04T18:41-0800 `flutter/triage_client/lib/main.dart`, `flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart`, `flutter/triage_client/lib/terminal/terminal_selection.dart`: switched imports from `package:xterm/xterm.dart` to `package:xterm2/xterm.dart`.
- 2026-11-04T18:41-0800 `flutter/triage_client/lib/terminal/terminal_store.dart`: switched import to `package:xterm2/xterm.dart` and simplified `writeToXterm` to delegate directly to `terminal.write(data)` now that `xterm2` natively parses `CSI Ps Z` (`CBT`) and `CSI Ps I` (`CHT`).
- 2026-11-04T18:41-0800 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`: switched import to `package:xterm2/xterm.dart`, simplified `_sendWheelStep` to call `_terminal.mouseInput(up ? xt.TerminalMouseButton.wheelUp : xt.TerminalMouseButton.wheelDown, xt.TerminalMouseButtonState.down, cell)`, and removed the `68/69/70/71` -> `64/65/66/67` string replacements in `_onTerminalOutput` now that `xterm2` uses standard unshifted wheel button IDs (`64/65/66/67`).
- 2026-11-04T18:41-0800 `flutter/triage_client/test/terminal/scrollback_clear_test.dart`, `flutter/triage_client/test/terminal/terminal_reflow_test.dart`, `flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart`, `flutter/triage_client/test/terminal/terminal_selection_test.dart`, `flutter/triage_client/test/terminal/terminal_store_test.dart`, `flutter/triage_client/test/terminal_hardware_key_test.dart`, `flutter/triage_client/test/widget_test.dart`, `flutter/triage_client/integration_test/replay_bench_test.dart`, `flutter/triage_client/test_driver/replay_bench_driver.dart`, `flutter/triage_client/tool/parse_bench.dart`: switched imports to `package:xterm2` and updated `scrollback_clear_test.dart` to assert `xterm2`'s clean detachment of cleared scrollback lines (`top.attached == false` and `controller.selection == null`).

## Decisions
- 2026-11-04T18:31-0800 Replace `package:xterm` with `package:xterm2`: `xterm2` (`^5.4.0`) already passed the Phase -1 benchmark gate (`devlog/000166-spike-term-parse-bench.md`, 2.6-3.7x faster parse throughput and within a single 16.7ms frame on Pixel 10 Pro Fold for 256 KiB replay) and includes upstream implementations for `IndexAwareCircularBuffer.trimStart` (`_absoluteStartIndex` advance + line detach), `replaceWith` rotation reset, `Buffer.resize` cursor-anchor tracking across width reflow, `CSI s`/`CSI u`, `CSI Ps Z` (`CBT`) and `CSI Ps I` (`CHT`), DEC Mode 2026 Synchronized Output, `modifyOtherKeys`, Kitty keyboard protocol, unshifted mouse wheel button IDs (`64/65/66/67`), and viewport-relative mouse reporting (`_getViewportCellOffset`).
- 2026-11-04T18:31-0800 Simplify `writeToXterm` and mouse wheel reporting: delegate `writeToXterm` directly to `terminal.write(data)` now that `xterm2` handles `CBT` and `CHT` natively in `_csiHandlers`, and route `_sendWheelStep` through `_terminal.mouseInput` with `TerminalMouseButton.wheelUp`/`wheelDown` instead of manually formatting SGR/URXVT/normal mouse wheel escape sequences or rewriting `68/69` to `64/65` in `_onTerminalOutput`.

## Commits
- HEAD: feat(client): migrate native terminal emulator from xterm 4.0 fork to xterm2
