# Devlog 000190: fix/smooth-resize-and-redraw

**Agent:** Gemini @ triage branch `fix/smooth-resize-and-redraw`

## Intent

Eliminate visible top-to-bottom layout jumps and mid-redraw tearing during keyboard open/close animations and full-screen CLI redraws:

1. **Client vertical resize anchoring:** Keep the active cursor/bottom rows visible when `TerminalCellBuffer.resize()` shrinks and pull resident scrollback lines down when it grows, instead of slicing from row `0` and padding blank bottom lines.
2. **Keyboard settle coalescing:** Debounce mobile `didChangeMetrics()` resize dispatches across the ~250 ms OS keyboard animation so opening/closing the keyboard triggers at most one `SIGWINCH` instead of firing mid-slide, and keep `stickToBottom` pinned synchronously during resize layout.
3. **Daemon redraw coalescing:** Extend `DECSET 2026` synchronized-update max hold from `40 ms` to `150 ms` and hold `PollTerminalSync` briefly across PTY `SIGWINCH` resize and unwrapped cursor-home/erase-display bursts so TUI redraws land atomically.
4. **Row text run batching:** Batch contiguous single-width printable ASCII runs with uniform style/foreground in `RenderTerminalGrid.paint()` to cut per-frame `TextPainter` draw calls.

## Progress

- [x] Create stacked worktree `fix/smooth-resize-and-redraw` on `feat/mobile-composer-and-chips`
- [x] Write branch devlog and plan (`devlog/plans/000190-01-smooth-resize-and-redraw.md`)
- [x] Track heuristic repaint bursts and resize quiescence in `triage-term` and `triaged`
- [x] Bottom-anchor `TerminalCellBuffer.resize()` and smooth keyboard metrics settle + synchronous bottom pinning in `TerminalPane`
- [x] Batch contiguous styled ASCII runs in `RenderTerminalGrid.paint()`
- [x] Add Rust + Flutter tests, verify full workspace + Flutter + APK build, update devlog, and commit

## What Changed

- `2026-11-15T22:24-0800 crates/triage-term/src/lib.rs`, `crates/triaged/src/session.rs`: Added `note_resize_burst` and `should_hold_sync_poll` on `TerminalModeTracker`, extended DEC Mode 2026 sync hold to `150 ms`, added `30 ms` post-resize hold for `SIGWINCH` coalescing, and added an `8 ms` quiet / `35 ms` max-cap burst hold when `CSI J` (`0|2`), `CSI H`/`f`, or `CSI A` repaints stream without `?2026h`.
- `2026-11-15T22:24-0800 flutter/triage_client/lib/terminal/terminal_cell_buffer.dart`: Updated `TerminalCellBuffer.resize()` to keep bottom/cursor lines visible on vertical shrink and pull resident scrollback lines down on vertical grow instead of anchoring from row `0`.
- `2026-11-15T22:24-0800 flutter/triage_client/lib/widgets/terminal_pane.dart`: Raised mobile `didChangeMetrics()` settle delay to `260 ms` across keyboard slide animations and snapped bottom-pinned offsets synchronously inside `_onTerminalResize`.
- `2026-11-15T22:24-0800 flutter/triage_client/lib/widgets/terminal_grid_render_box.dart`: Batched contiguous single-width printable ASCII text runs sharing foreground and bold/italic attributes in `RenderTerminalGrid.paint()`.
- `2026-11-15T22:24-0800 flutter/triage_client/test/terminal/terminal_cell_buffer_test.dart`, `test/terminal/terminal_grid_render_box_test.dart`, `test/terminal_hardware_key_test.dart`: Added tests for resize bottom anchoring and run-batched painting and updated keyboard animation settle timing to `300 ms`.
- `2026-11-16T07:52-0800 crates/triaged/src/session.rs`: Bumped `note_resize_burst` to `50 ms` and burst hold windows to `(10 ms quiet, 45 ms max)` for real non-keyboard resizes.
- `2026-11-16T07:52-0800 flutter/triage_client/lib/terminal/terminal_cell_buffer.dart`, `lib/widgets/terminal_pane.dart`, `lib/widgets/terminal_grid_render_box.dart`: Added `trailingBlankViewportRows`, read raw OS insets via `View.maybeOf` alongside `MediaQuery.maybeViewInsetsOf`, preserved full-height primary PTY rows across soft-keyboard and composer open/close, and clamped auto-bottom layout extent (`keepKeyboardCursorVisible`) so prompts remain visible above the keyboard without triggering `SIGWINCH`.
- `2026-11-16T07:52-0800 flutter/triage_client/test/terminal_hardware_key_test.dart`: Added test verifying soft-keyboard inset open/close preserves primary PTY rows without emitting `SIGWINCH` resize.
- `2026-11-16T09:52-0800 crates/triage-term/src/lib.rs`, `crates/triaged/src/session.rs`: Added `CSI 2K` burst tracking, handed off active resize holds to burst quiescence once PTY output arrives, raised burst hold windows to `(180 ms sync, 22 ms quiet, 110 ms max)` and initial `SIGWINCH` grace to `90 ms`.
- `2026-11-16T09:52-0800 flutter/triage_client/lib/main.dart`, `lib/widgets/terminal_grid_render_box.dart`, `lib/widgets/terminal_pane.dart`: Removed `ValueKey(session.title)` on `TerminalPane` so session switches swap buffers in place while keeping `RenderTerminalGrid` and `_glyphCache` warm; gated occlusion/wake resume refit on actual PTY size drift without double-jiggling `rows - 1`; unified `RenderTerminalGrid.effectiveTotalLines` with `TerminalPane._effectiveMaxScrollExtent` and `_autoBottomTarget` so bottom pinning and `maxScrollExtent` never diverge.
- `2026-11-16T09:52-0800 flutter/triage_client/test/widget_test.dart`, `test/terminal_hardware_key_test.dart`: Updated occlusion resume and drift reclaim assertions and added bottom-stick regression coverage with trailing blank rows.

## Decisions

- `2026-11-15T22:24-0800 Decision`: Hold multi-chunk repaint bursts inside `ActorCommand::PollTerminalSync` rather than `OutputState::poll_sync_frame` so unit tests driving `OutputState` directly stay synchronous while live WebSocket streams coalesce full-screen redraws.
- `2026-11-16T07:52-0800 Decision`: Keep primary-screen PTY `rows` unchanged when soft keyboard or mobile composer opens at unchanged `cols`, reading `View.maybeOf(context)?.viewInsets.bottom` because `Scaffold(resizeToAvoidBottomInset: true)` strips `MediaQuery.viewInsets.bottom` from descendants. This avoids `SIGWINCH` full-screen top-to-bottom CLI redraws on keyboard open/close while alt-screen TUI apps still resize normally.
- `2026-11-16T09:52-0800 Decision`: Trim `trailingBlankViewportRows` inside `RenderTerminalGrid.effectiveTotalLines` itself (instead of separating `autoBottomExtent` from `newMaxExtent`) so `maxScrollExtent`, `_snapToBottom`, and `_saveScrollOffset` always agree on a single bottom coordinate.

## Commits

- `8f2aab1`: `fix(terminal): coalesce resize redraws and bottom-anchor keyboard transitions`
- `603bed7`: `fix(mobile): preserve primary PTY rows across soft keyboard open and close`
- `HEAD`: `fix(client,daemon): stop unhide refit churn, keep bottom pin unified, and coalesce TUI redraws`
