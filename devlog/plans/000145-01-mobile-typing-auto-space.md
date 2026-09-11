# Plan 000145-01: Mobile Auto-Space, Terminal Resize Layout Clipping, and Cera 0.5.6 Upgrade

## Thinking

### Problem Analysis
1. **Mobile Auto-Space**:
   On mobile devices (both mobile web and native Flutter mobile clients on iOS and Android), typing words in sequence does not automatically insert spaces between words. When a user uses glide/swipe typing, taps autocomplete suggestions, or commits word compositions, successive words are concatenated directly without a space separator (e.g. `gitstatus` instead of `git status`).
2. **Terminal Resize Layout Clipping, Character Misplacement, and Cursor Drift**:
   In tools like `agy` (or any terminal CLI with bottom composers), resizing the terminal (or opening the virtual keyboard on Android/iOS, or resizing the macOS desktop app window) causes the bottom section to be clipped off, making it impossible to scroll down to view the composer.
   Additionally, characters are misplaced and the cursor moves erratically, inserting characters wherever it lands.
3. **Snapping to Top and Stick-to-Bottom Loss**:
   When content expands or resizing occurs, sessions at the bottom sometimes snap to the top instead of staying sticky at the bottom of the content.
4. **Cera Upgrade**:
   The workspace needs an upgrade to `cera` version `0.5.6`.

### Root Cause Identification
1. **Mobile Auto-Space**:
   - Virtual keyboard helper textareas and input contexts in Flutter are reset to empty on every commit or input event to keep IME states clean.
   - Virtual keyboards (Gboard, iOS QuickType, Samsung Keyboard) see an empty preceding context, so they do not prepend a space before the next swipe or autocomplete chip.
   - The terminal input stream previously lacked tracking to detect when successive word chunks arrive without an intervening delimiter.
2. **Terminal Resize Layout Clipping and Character Misplacement in `xterm.dart`**:
   - `Buffer.resize` in `xterm.dart` was destructively popping rows from the main buffer:
     ```dart
     for (var i = 0; i < oldHeight - newHeight; i++) {
       if (_cursorY > newHeight - 1) {
         _cursorY--;
       } else {
         lines.pop();
       }
     }
     ```
     When height shrunk (such as when the on-screen keyboard appeared or a window shrunk), any rows below `_cursorY` were permanently popped off the end of `lines`, deleting the bottom lines of the screen where CLI prompt composers live.
   - When height expanded (`newHeight > oldHeight`), it looped `_cursorY++`, shifting `_cursorY` down into newly added blank lines rather than preserving cursor location relative to the actual content. Subsequent keystrokes were written to arbitrary blank lines below the prompt.
   - Width reflow was performed without repositioning the cursor, so wrapping rows shifted the text while leaving the cursor at stale coordinates.
3. **Stick-to-Bottom Layout Race and Rogue Anchor Capture**:
   - In `RenderTerminal.performLayout` (`xterm.dart`), `_offset.applyContentDimensions` invoked `_onScroll` during the layout pass before `correctBy` adjusted the offset. Because `_scrollOffset` had not caught up with `_maxScrollExtent`, `_stickToBottom` was prematurely cleared to false.
   - In `_scrollToCursor` (`terminal_pane_stub.dart`), `jumpTo` captured row 0 as a scroll anchor before layout settled, locking the viewport to the top of the session.

### Solution Design
1. **Mobile Auto-Space Tracker (`mobile_auto_space.dart`)**:
   - Track `_lastEndedWithWordChar`.
   - When incoming text starts with a word character and follows a previous word character, prepend a single space `' '`.
   - Reset tracker on host output, pointer interaction, delimiters (Enter, Backspace, Esc, Tab, Space), and accessory bar taps.
   - Integrate into `terminal_pane_web.dart` and `terminal_pane_stub.dart` guarded by `_isMobile`.
2. **Buffer Resize Refactor in `xterm.dart`**:
   - Width reflow runs first using a `CellAnchor` at the cursor position so the cursor tracks reflowed text.
   - Height adjustment only trims trailing empty lines below the cursor to avoid pushing active content into scrollback. Lines containing content, anchors, or wrapped continuation are never popped.
   - Maintain `savedAbsoluteCursorY` and recompute `_cursorY` relative to surviving lines and scrollback offset.
3. **Stick-to-Bottom Layout Race Guard**:
   - Guard `_onScroll` during `RenderTerminal.performLayout` with `_isPerformingLayout`.
   - Add a 0.5px tolerance check (`_scrollOffset >= _maxScrollExtent - 0.5`) in `_onScroll`.
   - Re-enable `_stickToBottom = true` when attaching/swapping terminal instances.
   - In `terminal_scroll_anchor.dart`, clear anchors within `kScrollPinReleaseGraceLines * lineHeight` to avoid pinning near the bottom.
   - In `terminal_pane_stub.dart`, schedule `_snapToBottom` on resize when unpinned, and suppress anchor capture during `_scrollToCursor`.
4. **Cera 0.5.6 Upgrade**:
   - Update `cera = "0.5.6"` in `Cargo.toml`.
   - Run `cargo update cera`.
   - Add `gpu_depthformer: false` to `cera::EngineConfig` in `crates/triaged/src/summarizer.rs`.
5. **Build, Install, and Reload**:
   - Compile Flutter web bundle and embed into release binaries.
   - Run `scripts/install.sh` to build and atomically install release binaries.
   - Reload `triaged` using zero-downtime handover protocol (`triaged reload`).
   - Build macOS release app (`flutter build macos --release`) and install to `/Applications/Triage.app`.

---

## Plan

1. **Implement Mobile Auto-Space**:
   - Create `flutter/triage_client/lib/terminal/mobile_auto_space.dart`.
   - Add unit tests in `flutter/triage_client/test/terminal/mobile_auto_space_test.dart`.
   - Connect tracker in `terminal_pane_web.dart` and `terminal_pane_stub.dart`.
2. **Fix `xterm.dart` Buffer Resize and Stick-to-Bottom**:
   - In `xterm.dart`: refactor `Buffer.resize` in `buffer.dart` to prevent line popping and maintain cursor coordinates.
   - In `xterm.dart`: guard layout in `render.dart` to preserve `_stickToBottom`.
   - Add unit tests in `buffer_test.dart`.
   - Push commit to `hyeons-lab/xterm.dart` branch `fix/trim-start-reindex-v4`.
   - Update `pubspec.yaml` dependency override to the new commit hash.
3. **Preserve Stick-to-Bottom on Resize and Session Switch**:
   - Update `terminal_scroll_anchor.dart` and `terminal_pane_stub.dart`.
4. **Upgrade Cera to 0.5.6**:
   - Update `Cargo.toml` and `Cargo.lock`.
   - Update `summarizer.rs` for `gpu_depthformer`.
5. **Validation**:
   - Run `flutter analyze` and `flutter test`.
   - Run `cargo fmt --all -- --check`, `cargo clippy`, and `cargo test --workspace`.
6. **Build, Install, and Reload**:
   - Run `scripts/install.sh` to install release binaries.
   - Reload daemon via `triaged reload` and verify zero-downtime handover.
   - Build macOS release app (`flutter build macos --release`) and install to `/Applications/Triage.app`.
7. **Documentation**:
   - Update devlog and plan.
