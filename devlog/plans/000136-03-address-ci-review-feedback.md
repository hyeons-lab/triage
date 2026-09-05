# Plan: Address CI Review Feedback for Safe Multi-Line Paste

## Thinking

The automated Antigravity Code Review and Copilot review on PR #157 highlighted several correctness, layout, and cross-platform refinement opportunities:

1. **Horizontal Layout Overflow on Portrait Mobile Screens**:
   - In `flutter/triage_client/lib/widgets/multiline_paste_dialog.dart`, the dialog's title uses a `Row` containing an unwrapped `Text('Multi-Line Paste Warning')`. On narrow devices (e.g. small portrait phones), this can overflow horizontally. Wrapping the title text with `Expanded` and adding `overflow: TextOverflow.ellipsis` prevents layout exceptions.
   - The dialog provides three text action buttons ("Cancel", "Paste as Single Line", "Paste (Execute Commands)"). In narrow portrait layouts, side-by-side placement can overflow. Setting `actionsAlignment: MainAxisAlignment.end` and `actionsOverflowButtonSpacing: 8` enables Flutter's `OverflowBar` to stack the buttons vertically when horizontal space is constrained.

2. **Unicode Surrogate-Pair Splitting during String Truncation**:
   - In `multiline_paste_dialog.dart`, preview lines exceeding 200 characters are sliced with `line.substring(0, 200)`. If the character at index 199 is a UTF-16 high surrogate (`0xD800` to `0xDBFF`) and index 200 is a low surrogate (`0xDC00` to `0xDFFF`), slicing at 200 cuts the surrogate pair in half. This leaves an unpaired high surrogate at the end of the string, which can cause rendering glitches or terminal decoder warnings.
   - Slicing should check if `codeUnitAt(end - 1)` is a high surrogate (`>= 0xD800 && <= 0xDBFF`) and decrement the slice boundary to 199.

3. **Symmetrical Web Selection Clearing**:
   - Native desktop and mobile platforms clear the terminal selection when pasting via `_xtermController.clearSelection()`. On the web side (`terminal_pane_web.dart`), the selection remains highlighted after paste completion. Calling `js_util.callMethod(_term, 'clearSelection', [])` inside `_handlePaste` establishes visual consistency across web and native platforms.

4. **Zero-Allocation UTF-8 Byte Count Estimation**:
   - Copilot and Antigravity flagged that `text.length` counts UTF-16 code units rather than bytes, under-reporting payload sizes for non-ASCII and emoji text. Computing `utf8.encode(text).length` causes heap allocations and GC spikes on large clipboard buffers.
   - Implementing `estimateUtf8Bytes(String text)` in `terminal_paste.dart` computes exact UTF-8 byte lengths in a single non-allocating pass over character code units: 1 byte for ASCII (< 0x80), 2 bytes for 0x80..0x7FF, 4 bytes for surrogate pairs (0xD800..0xDBFF paired with low surrogates, skipping the low unit), and 3 bytes for remaining code points.

5. **Test Coverage & Verifications**:
   - Add unit tests for `estimateUtf8Bytes` covering ASCII, multi-byte Unicode (e.g. Cyrillic, Greek, CJK), emoji surrogate pairs, and mixed text.
   - Add unit tests for surrogate pair truncation at the 200-character boundary.
   - Add a widget test testing `showMultiLinePasteDialog` within narrow portrait mobile constraints (e.g. 320x568) to verify that action buttons wrap and render cleanly without horizontal overflow.

## Plan

1. **Update `terminal_paste.dart`**:
   - Add `estimateUtf8Bytes(String text)` with single-pass zero-allocation UTF-8 byte counting.
   - Export `estimateUtf8Bytes`.

2. **Update `multiline_paste_dialog.dart`**:
   - Wrap the title text with `Expanded(child: Text(..., overflow: TextOverflow.ellipsis))`.
   - Add `actionsAlignment: MainAxisAlignment.end` and `actionsOverflowButtonSpacing: 8` to `AlertDialog`.
   - Add `_truncatePreviewLine` helper that guards against splitting UTF-16 high surrogates at boundary index 200.
   - Use `estimateUtf8Bytes(text)` instead of `text.length` for calculating payload size.

3. **Update `terminal_pane_web.dart`**:
   - In `_handlePaste(String text)`, call `js_util.callMethod(_term, 'clearSelection', [])` after input transmission.

4. **Extend `terminal_paste_test.dart`**:
   - Add unit tests for `estimateUtf8Bytes` across ASCII, multi-byte UTF-8, and emoji surrogate pairs.
   - Add unit test for surrogate pair truncation safety.
   - Add widget test under narrow screen dimensions (e.g. 320px width) to verify vertical action button stacking without layout overflow.

5. **Run Validation Checks**:
   - Run `flutter analyze` and `flutter test`.
   - Run `cargo fmt --all -- --check` and `cargo clippy`.

6. **Thematic Skill Synthesis**:
   - Update `~/.gemini/review-refinements.md` with generalized takeaways under the core thematic pillars.

7. **Resolve GitHub Review Threads**:
   - Resolve the open Copilot review thread on `multiline_paste_dialog.dart` via GraphQL.

8. **Devlog and Commit**:
   - Update `devlog/000135-fix-safe-multiline-paste.md`.
   - Commit changes using Conventional Commits style: `fix(client): address review comments for safe multiline paste`.
   - Push to `origin/fix/safe-multiline-paste` using explicit destination refspec.
