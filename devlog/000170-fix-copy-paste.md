# 000170: Fix copy and paste truncation across native and web clients and daemon

## Agent

Antigravity (gemini-2.5-pro) @ triage branch fix/copy-paste (2026-10-20T14:55-0700)
Antigravity (gemini-4-argon) @ triage branch fix/copy-paste (2026-10-21T08:51-0700)

## Intent

Fix copy-and-paste truncation where selecting and copying a multi-line or
multi-kilobyte passage fails to copy or paste the full selected text across
the native Flutter terminal pane, the web Flutter terminal pane, the client
pending-input queue, and the daemon parked-input buffer.

## What Changed

- 2026-10-20T15:43-0700 `flutter/triage_client/lib/terminal/terminal_selection.dart`:
  added `resolveSelectionEndpoints` (expanding `base.x + 1` on backward
  selections so `BufferRangeLine.normalized` does not drop the anchor cell) and
  `shiftCellOffsetForHistoryPage` (shifting row coordinates when older
  scrollback pages are prepended).
- 2026-10-20T15:43-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
  preserved active selections and drag/shift anchors across scrollback history
  paging; prevented `xterm.dart`'s viewport-relative selection listener from
  overwriting `_selectionAnchor` during drag-select; re-applied the final
  drag selection on pointer release both synchronously and in a microtask so
  the release position is never lost; intercepted `Cmd+A` / `Ctrl+Shift+A` to
  select the full scrollback buffer rather than only the bottom `viewHeight`
  rows.
- 2026-10-20T15:43-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
  enabled `Cmd+C`/`Ctrl+C` copy and `Cmd+A`/`Ctrl+Shift+A` full-buffer
  select-all even in exited sessions; routed `attachCustomKeyEventHandler`
  copy through `_copyTextToClipboard` so the `execCommand('copy')` fallback
  works on non-HTTPS tailnet URLs; focused the helper textarea on `Cmd+V` /
  `Ctrl+V` and added a window-level `paste` listener fallback when DOM focus is
  outside the container; preserved xterm.js selection coordinates across
  history-page replays and suppressed `onNearTop` paging during mouse drag
  selection.
- 2026-10-20T15:43-0700 `flutter/triage_client/lib/main.dart`, `crates/triaged/src/session.rs`:
  raised `PendingInputBuffer.capacity` and `PARKED_INPUT_CAP_BYTES` from 4 KiB
  to 1 MiB, preserved UTF-8 codepoint boundaries and closing `\x1b[201~`
  bracketed-paste terminators when truncating at the cap, and updated
  `write_pty_input` (`write_pty_chunk`) to write in 4 KiB chunks (releasing the
  PTY writer mutex between chunks) and retry `ErrorKind::WouldBlock`.
- 2026-10-20T15:43-0700 `crates/triage/src/main.rs`:
  updated `selected_row_text` so empty lines inside a multi-line selection are
  preserved as empty strings instead of being filtered out by `filter_map`.
- 2026-10-20T15:43-0700 `flutter/triage_client/test/terminal/terminal_selection_test.dart`, `flutter/triage_client/test/pending_input_buffer_test.dart`:
  added unit tests for `resolveSelectionEndpoints`,
  `shiftCellOffsetForHistoryPage`, and `PendingInputBuffer` UTF-8 / bracketed
  paste truncation.
- 2026-10-20T23:05-0700 `crates/triaged/src/session.rs`, `flutter/triage_client/lib/main.dart`, `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, `flutter/triage_client/test/pending_input_buffer_test.dart`, `flutter/triage_client/test/terminal/terminal_selection_test.dart`:
  dropped bracketed-paste payloads when remaining buffer room is under 12 bytes
  so an unclosed `\x1b[200~` sequence is never emitted; returned `Cow<[u8]>`
  from `truncate_parked_input_bytes` to avoid cloning fitting buffers; held the
  `SharedPtyWriter` lock across immediately succeeding 4 KiB slices of a single
  message in `write_pty_chunk` (releasing only across `WouldBlock` sleeps) so
  `TerminalOutputSink` query responses cannot interleave mid-paste; matched
  `Cmd+A` and `Ctrl+Shift+A` select-all chords in `attachCustomKeyEventHandler`;
  and asserted captured `FlakyWriter` bytes and right-margin / 4-byte UTF-8
  boundary cases in tests.
- 2026-10-21T08:51-0700 `crates/triaged/src/session.rs`, `flutter/triage_client/lib/terminal/terminal_selection.dart`, `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`, `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, `flutter/triage_client/test/terminal/terminal_selection_test.dart`, `flutter/triage_client/test/terminal_hardware_key_test.dart`:
  enforced a daemon-wide `MAX_TOTAL_PARKED_INPUT_BYTES` (`2 MiB`) cap across
  `SessionManager::parked_denied_input` entries in `park_denied_input` and
  `restore_parked_entry` so worst-case base64 handover serialization stays
  below `MAX_HANDOVER_FRAME_BYTES` (`4 MiB`); extracted `WebSelectionRange`,
  `shiftWebSelectionForHistoryPage`, and `isWebSelectAllShortcut` into
  `terminal_selection.dart` with VM unit tests; unified shortcut helpers across
  stub and web terminal panes; and added widget and call-site unit tests for
  select-all, history-page selection shift, `FlakyWriter` chunk bounds, and
  parked-input aggregate cap truncation.

## Decisions

- 2026-10-20T15:43-0700 See `devlog/plans/000170-01-fix-copy-paste.md` for
  root-cause analysis and implementation plan.

## Commits

- 5fe90ef: fix: prevent copy and paste truncation across clients and daemon
- 0db6ca5: fix: address PR #198 review comments on paste truncation and PTY chunk locking
- HEAD: fix: cap aggregate parked input and harden terminal selection tests

## Progress

- [x] Create `worktrees/fix-copy-paste` on branch `fix/copy-paste`
- [x] Create branch devlog and plan file
- [x] Fix native terminal drag-selection race and backward-selection boundary drop in `terminal_pane_stub.dart`
- [x] Raise client `PendingInputBuffer` and daemon `PARKED_INPUT_CAP_BYTES` and preserve bracketed paste / UTF-8 boundaries
- [x] Fix web terminal copy in exited sessions, clipboard fallback in `attachCustomKeyEventHandler`, and selection-safe history paging in `terminal_pane_web.dart`
- [x] Add unit and regression tests across Flutter and Rust
- [x] Run format, lint, and tests; commit, push, and open PR
