# Fix Terminal Input Focus and Stair-Casing Offset

## Thinking
The user reported that the terminal input gets into a state where text input replaces read-only text, the cursor position is incorrect/misaligned, and Enter does nothing.
There are two main root causes for this behavior:
1. **Focus Divergence (Swallowed Keys / Enter does nothing)**:
   In Flutter Web, platform views like `HtmlElementView` (used to render xterm.js) can lose keyboard focus to Flutter's own global hidden focus capturers. When the user types or presses Enter, the keys are captured by Flutter instead of xterm.js's `<textarea>`, making it feel like Enter does nothing or text is placed/rendered incorrectly.
   - *Solution*: Establish bidirectional focus bridging between Flutter's `FocusNode` and xterm.js's DOM focus. When `_focusNode.hasFocus` changes, programmatically focus xterm.js. Conversely, listen to `_term.onFocus` and request focus on `_focusNode` if it doesn't have it.
2. **Stair-Casing / Cursor Offset (Text replaces read-only text)**:
   In `terminal_pane_web.dart`, `convertEol` is set to `false`. When shell tools or agent prompts output `\n` without `\r`, xterm.js shifts down by one line but stays at the same column. This is called stair-casing. It offsets the visual cursor position, causing subsequent character prints and backspaces to overwrite other lines/prompt text on the screen, corrupting the layout and breaking the line-editor library.
   - *Solution*: Revert/change `convertEol` to `true` in xterm.js options. This ensures `\n` naturally translates to `\r\n` and aligns the cursor correctly to column 0 on all newlines, preventing stair-casing prompt offsets.

## Plan
1. Update `terminal_pane_web.dart` to define `_onFocusSubscription` dynamic variable.
2. Update `initState` in `_TerminalPaneState` to add a focus listener on `_focusNode` that calls `_term.focus()` when it gains focus.
3. Update `_initTerminal` in `_TerminalPaneState` to set `convertEol` option to `true`.
4. Bind `term.onFocus` to request focus on `_focusNode` in `_initTerminal` and store the subscription.
5. Dispose of the focus subscription `_onFocusSubscription` in the `dispose` method.
6. Verify successful compilation using `flutter analyze`.
