# Devlog: Clickable Terminal URLs in Unified GPU Grid Renderer

- **Agent:** Antigravity (Gemini 4 Hydrogen High) @ triage branch feat/clickable-terminal-urls
- **Intent:** Detect `http://` and `https://` URLs across single and soft-wrapped terminal rows in the unified Flutter GPU grid renderer (`RenderTerminalGrid` + `TerminalPane`), highlight them visually, show a pointer cursor on hover, and open them externally on click/tap without breaking drag selection, mobile long-press selection, or TUI mouse reporting.

## What Changed

- `2026-11-12T23:56-0800`: Added `lib/terminal/terminal_links.dart` to detect `http://` and `https://` URLs across single and soft-wrapped (`wrapsNext`) logical rows, track accurate cell column spans (accounting for wide/continuation cells), trim outer trailing punctuation while preserving balanced parentheses and IPv6 bracket hosts, and stop safely at unloaded scrollback gaps.
- `2026-11-12T23:56-0800`: Added `TerminalCellBuffer.revision` (incremented in `notifyListeners`) and updated `RenderTerminalGrid` (`lib/widgets/terminal_grid_render_box.dart`) to cache visible URL spans, render passive subtle underlines and cursor-colored hover underlines across all segments of `hoveredLink`, and expose strict `hitTestCellOffset` / `linkAtOffset`.
- `2026-11-12T23:56-0800`: Wired hover tracking (`MouseRegion`), cursor updates (`click` / `text` / `basic`), external browser launch via `openExternalUri` (or optional `onOpenUrl`), `Ctrl+click`/`Cmd+click` bypass when `mouseMode > 0`, and mobile tap vs. long-press guard in `TerminalPane` (`lib/widgets/terminal_pane.dart`).
- `2026-11-12T23:56-0800`: Added unit and widget test suites in `test/terminal/terminal_links_test.dart`, `test/terminal/terminal_grid_render_box_test.dart`, and `test/terminal/terminal_pane_links_test.dart`.

- `2026-11-13T06:40-0800`: Fixed copy/paste on remote clients. Windows TUI (`crates/triage/src/main.rs`): added `BracketedPasteKeyDecoder` to rebuild `Event::Paste` from the per-key events crossterm emits on Windows, plus Ctrl+Shift+V / Shift+Insert reading the Windows clipboard directly. Flutter web (`terminal_pane.dart`, `web_paste_*.dart`): Ctrl+V defers to the native DOM `paste` event, with a `Clipboard.getData` fallback after 50ms.

- `2026-11-13T16:38-0800`: Rebased `feat/clickable-terminal-urls` onto the stacked `feat/terminal-cell-sync` -> `feat/d1-approval-judge` -> `feat/mcp-worker-sessions` chain. Unified duplicate `registerWebPasteListener` / `_disposeWebPasteListener` definitions between PR #212 (`platform_env_web.dart`) and PR #215 (`web_paste_*.dart`) into `platform_env_web.dart` (preserving capture-phase listener, `_isExternalEditableActive()`, `stopPropagation()`, and `text` fallback while removing the duplicate `web_paste_stub.dart` / `web_paste_web.dart` files), and gated `is_explicit_paste_chord` in `crates/triage/src/main.rs` with `#[cfg(any(windows, test))]` for clean non-Windows clippy builds.

## Decisions

- **Strict hit-testing (`hitTestCellOffset`)**: `RenderTerminalGrid.getCellOffset` clamps out-of-bounds coordinates for drag selection, which would trigger false URL hits in right/bottom margins; adding a non-clamping `hitTestCellOffset` keeps link hovers and clicks scoped to actual rendered glyphs.
- **`mouseMode > 0` gating**: TUI applications capture plain mouse clicks in `mouseMode > 0`, so plain clicks continue forwarding to the PTY and hover uses `SystemMouseCursors.basic`, while holding `Ctrl` or `Cmd` surfaces `SystemMouseCursors.click` and opens the URL without forwarding mouse reports.
- **Synchronous `HardwareKeyboard` hover refresh & selection guards**: Modifier transitions refresh hovered links synchronously for immediate cursor feedback; dragging past slop, clicking while a non-collapsed selection is active, or triggering mobile long-press selection cancels link activation so selection behavior stays intact.

## Issues

- Windows terminals deliver bracketed paste as individual key events, and `navigator.clipboard.readText()` fails on insecure `http://` origins, so paste truncated or failed on remote clients.

## Commits

- `e947156`: feat(client): make http/https URLs clickable in terminal grid
- `ca0c2ad`: fix(client): restore paste in Windows TUI and Flutter web terminal
- `HEAD`: fix(client): unify web DOM paste helper and gate Windows paste helper after stack rebase

## Progress

- [x] Add `lib/terminal/terminal_links.dart` with wrapped-row URL detection, punctuation trimming, and cell-hit mapping
- [x] Track `TerminalCellBuffer.revision` and render passive + hovered URL underlines and strict `hitTestCellOffset` in `RenderTerminalGrid`
- [x] Wire hover cursor, click/tap link activation, Ctrl/Cmd bypass for `mouseMode > 0`, and `openExternalUri` launch in `TerminalPane`
- [x] Add comprehensive unit and widget tests for URL detection, wrapped links, hover/click/drag/selection/mouse-mode interactions
- [x] Validate with `flutter analyze`, `flutter test`, `flutter build web --release`, Rust checks, and reload `triaged`
