# 000173-01: Fix copy and paste truncation

## Thinking

Investigating why copying a passage and pasting it does not paste everything
selected surfaced four distinct truncation and drop paths across the native
Flutter terminal pane, the web terminal pane, the client input queue, and the
daemon input lease parker:

1. **Native Flutter client (`terminal_pane_stub.dart`): drag-selection microtask race with `_endDrag` and `xterm.dart`'s `selectCharacters`**
   - `xterm.dart`'s `RenderTerminal.selectCharacters(from, to)` has two bugs:
     first, `from` is a viewport pixel offset (`_lastDragStartDetails!.localPosition`)
     rather than a buffer cell anchor, so auto-scrolling during a drag shifts
     `from` to the new rows under that pixel and drops scrolled-past lines;
     second, `if (toPosition.x >= fromPosition.x)` compares only columns
     instead of `(row, col)` order, so any multi-line forward selection whose
     ending column is left of its starting column (`toPosition.x < fromPosition.x`)
     omits `+ 1` on the half-open `[begin, end)` range and drops the final
     selected character.
   - `terminal_pane_stub.dart` works around both bugs by tracking
     `_dragAnchorCell` and scheduling `_applyDragExtend()` in a microtask from
     `_handlePointerMove` so it runs after `PanGestureRecognizer`'s synchronous
     `onDragUpdate`.
   - However, in Flutter's `GestureBinding._flushPointerEventQueue()`, the
     final `PointerMoveEvent` and `PointerUpEvent` in a pointer packet are
     dispatched synchronously before microtasks run. `_handlePointerUp` calls
     `_endDrag()`, which sets `_dragSelecting = false` and
     `_dragAnchorCell = null`. When the scheduled microtask later runs
     `_applyDragExtend()`, it hits `if (!_dragSelecting) return;` and exits,
     leaving `xterm.dart`'s broken `selectCharacters` range in the controller.
   - Additionally, on mobile/touch (`onLongPressStart` / `onLongPressMoveUpdate`),
     `xterm.dart` calls `selectWord(from, to)`, which looks up
     `buffer.getWordBoundary(toOffset)` and returns early (`if (toBoundary == null) return;`)
     whenever the finger is over a space, separator (`'.'`, `':'`, `'-'`,
     `'/'`, etc.), or end-of-line blank cell (`codePoint == 0`). Dragging a
     long-press selection across punctuation, spaces, or line ends leaves the
     selection stuck at the last word touched.

2. **Client `PendingInputBuffer` (`flutter/triage_client/lib/main.dart`) and daemon `PARKED_INPUT_CAP_BYTES` (`crates/triaged/src/session.rs`): 4,096-byte cap truncates pastes during lease acquisition**
   - Since PR #181, selecting a session attaches in `Observer` mode
     (`hasInputLease = false`), and the first input or paste event queues its
     bytes in `_pendingInput` while `_acquireInputLeaseAndFlush` requests the
     `InteractiveController` lease. Similarly, on the daemon side, input
     arriving before lease promotion is parked via `park_denied_input`.
   - Both `PendingInputBuffer.capacity` (`main.dart:1015`) and
     `PARKED_INPUT_CAP_BYTES` (`session.rs:225`) are 4,096 bytes (`4 KiB`).
     Pasting a passage larger than 4 KiB into a newly selected session (or
     before lease acquisition completes) silently truncates the paste to
     4,096 bytes.
   - Furthermore, when bracketed paste mode (`\x1b[200~...\x1b[201~`) is
     enabled, truncating the tail strips the closing `\x1b[201~` sequence (and
     can split a multi-byte UTF-8 codepoint), leaving the target shell or TUI
     stuck inside an unclosed bracketed paste.

3. **Web client (`terminal_pane_web.dart`): exited-session copy, HTTP clipboard fallback, and selection-clobbering history paging**
   - `_windowKeyDownListener` and `_eventTargetsTerminal` check
     `!widget.isExited`, blocking `Cmd+C`/`Ctrl+C` keyboard copy when viewing
     an exited session.
   - `attachCustomKeyEventHandler` calls
     `html.window.navigator.clipboard?.writeText(selection)` directly instead
     of `_copyTextToClipboard(selection)`, bypassing the hidden-textarea
     `execCommand('copy')` fallback needed on plain-HTTP tailnet origins.
   - `onScroll` triggers `onNearTop` (`_pageHistoryUp`) whenever
     `viewportY <= 5`, even if the user is actively drag-selecting near the top
     of the viewport (`_isUserGestureActive` or `term.hasSelection()`), which
     clears and rewrites the xterm.js buffer mid-selection.

## Plan

1. **Native terminal selection (`flutter/triage_client/lib/widgets/terminal_pane_stub.dart`)**:
   - In `_handlePointerUp`, when finishing an active `_dragSelecting` gesture,
     update `_dragLastPosition = event.position`, apply `_applyDragExtend()`
     synchronously before `_endDrag()`, and schedule a post-gesture microtask
     with the captured `(anchorCell, endPosition)` so any gesture-recognizer
     callback during pointer-up cannot overwrite the final `[anchor, target]`
     selection.
   - Support touch drag selection accurately so dragging across spaces,
     punctuation, or end-of-line blank cells extends to the target cell rather
     than getting stuck in `xterm.dart`'s `selectWord` null-boundary return.
2. **Client and daemon pending/parked input buffers (`flutter/triage_client/lib/main.dart`, `crates/triaged/src/session.rs`, `flutter/triage_client/lib/terminal/terminal_paste.dart`)**:
   - Increase `PendingInputBuffer.capacity` and `PARKED_INPUT_CAP_BYTES` to
     `1024 * 1024` (1 MiB) so multi-kilobyte pastes on newly selected
     `Observer` sessions or during lease acquisition pass through intact.
   - Ensure that if a buffer cap is ever reached on a payload, truncation never
     splits a multi-byte UTF-8 sequence and preserves the closing bracketed
     paste sequence (`\x1b[201~`) if the chunk opened or ended with bracketed
     paste.
3. **Web terminal selection and copy (`flutter/triage_client/lib/widgets/terminal_pane_web.dart`)**:
   - Allow `Cmd+C`/`Ctrl+C` copy in `_windowKeyDownListener` and
     `_eventTargetsTerminal` when `widget.isExited` is true.
   - Route `attachCustomKeyEventHandler`'s copy branch through
     `_copyTextToClipboard(selection)` so HTTP origins get the legacy
     clipboard fallback.
   - Defer `onNearTop` history paging while `_isUserGestureActive` or
     `_termHasSelection(term)` is true so drag-selecting near the top of the
     viewport does not clear and rewrite the xterm.js buffer mid-selection.
4. **Tests & Verification**:
   - Add unit tests in `flutter/triage_client/test/` for `PendingInputBuffer`
     large paste retention + UTF-8/bracketed-paste-safe cap truncation and for
     `terminal_pane_stub.dart` pointer-move + pointer-up drag-selection
     preservation (including multi-line forward selection where
     `end.x < start.x` and auto-scrolled drag selection).
   - Add Rust unit tests in `crates/triaged/src/session.rs` for large paste
     parking and bracketed-paste-safe truncation at the cap.
   - Run `cargo fmt --all -- --check`, `cargo clippy`, `cargo test`,
     `flutter analyze`, and `flutter test`.
