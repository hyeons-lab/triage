# 000145-03: Emulator Queries, Astral Plane Unicode, and Scrollbar Layout Lifecycle

## Thinking

Auditing the complete branch diff revealed several high-impact areas across multiplatform parity, internationalization, and rendering efficiency:

1. Web terminal emulator query filtering:
   Native terminal_pane_stub.dart filters emulator-generated query replies with isEmulatorQueryResponse(data) before scroll or paste processing. terminal_pane_web.dart lacked this check, causing synthetic CPR ([...R), DA ([?...c), and window size reports emitted by xterm.js in response to remote shell queries to erase saved viewport offsets and snap to the bottom.

2. Astral plane (SMP) Unicode character support and unspaced scripts:
   In Dart UTF-16, characters beyond U+FFFF are represented by surrogate pairs. Slicing with codeUnitAt(0) and codeUnitAt(length - 1) inspected isolated surrogate code units, misclassifying astral symbols as non-word characters. Furthermore, single astral scalar characters have text.length == 2, which falsely triggered multi-character word chunk auto-spacing.
   In addition, continuous scripts without word spaces (CJK ideographs, Japanese Kana, Thai, Lao, Khmer, Myanmar) need auto-space suppression so that phrase commits and continuous text do not have spaces erroneously inserted between words.

3. Scrollbar layout and lifecycle resilience:
   Nesting LayoutBuilder inside AnimatedBuilder in TerminalScrollbar ran layout constraint callbacks on every scroll tick. Inverting them so LayoutBuilder wraps AnimatedBuilder ensures layout constraints are only calculated when dimensions change, while AnimatedBuilder repaints the thumb smoothly. Guarding hasContentDimensions and positions.length == 1 defends against runtime framework assertions.

## Plan

1. In terminal_pane_web.dart, import emulator_query_response.dart and filter isEmulatorQueryResponse(data) in onDataCallback to forward query replies directly without touching viewport scroll state.
2. In mobile_auto_space.dart:
   - Reconstruct 32-bit scalar code points from surrogate pairs at string boundaries via _firstCodePoint and _lastCodePoint.
   - Distinguish single astral characters from multi-character word chunks using isMultiChar.
   - Filter unspaced scripts (CJK ideographs, Hiragana, Katakana, Thai, Lao, Khmer, Myanmar) in _isUnspacedScript.
   - Add zero-allocation fast paths for Cyrillic, Greek, Hangul, and CJK ideographs before regex matching.
3. In storage_native.dart, cache the resolved SharedPreferences instance during fallback write and delete invocations.
4. In terminal_scrollbar.dart:
   - Invert LayoutBuilder and AnimatedBuilder so layout is evaluated only on boundary resize.
   - Guard against positions.length != 1, missing content dimensions, and non-finite pixel offsets.
   - Filter metrics notifications with depth == 0 and reset drag state in didUpdateWidget.
5. In terminal_pane_stub.dart, guard _snapToBottom with hasContentDimensions and include _sessionSavedScrollOffsets in _onTerminalResize fallback resolution.
6. In triage_websocket_client.dart, remove redundant return inside try block to resolve analysis warning.
7. Add comprehensive unit tests in mobile_auto_space_test.dart and terminal_scrollbar_test.dart.
8. Verify all Cargo and Flutter test suites, format, and linters.
