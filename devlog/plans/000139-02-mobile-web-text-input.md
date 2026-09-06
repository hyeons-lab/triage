# Plan 000139-02: Fix Mobile Web Virtual Keyboard Text Input

## Thinking

### Problem Analysis
On mobile web browsers (Safari on iOS and Chrome on Android), users can connect to Triage, select sessions, and tap the terminal screen to raise the on-screen soft keyboard. However, typing letters or numbers on the virtual keyboard produces no output on the terminal. The accessory bar buttons (Esc, Tab, Enter, Ctrl, arrows) work because they dispatch raw input bytes directly through Flutter button handlers, but the soft keyboard itself is completely ignored.

### Root Cause Identification
1. **Input Method Editor (IME) Event Model on Mobile Browsers**:
   - Desktop browsers emit standard `keydown` and `keypress` events (e.g., `key: 'a'`) when keys are pressed. `xterm.js` handles these on desktop, translates them to terminal bytes, calls `preventDefault()`, and fires `term.onData`.
   - Mobile virtual keyboards (such as Gboard, Samsung Keyboard, and iOS virtual keyboard) operate as IMEs to support autocorrect, predictive typing, and swipe gestures.
   - On Android Chrome, mobile keyboards emit `keydown` with `keyCode: 229` (`key: 'Unidentified'`), followed by DOM `beforeinput` and `input` events targeting the helper `<textarea class="xterm-helper-textarea">`.
2. **xterm.js Input Event Filtering**:
   - In `xterm.js`'s internal `_inputEvent(e)` handler:
     ```javascript
     if (e.data && "insertText" === e.inputType && (!e.composed || !this._keyDownSeen) && !this.optionsService.rawOptions.screenReaderMode)
     ```
   - Because the mobile keyboard fired a `keydown` before `input`, `this._keyDownSeen` is true. Because mobile virtual keyboards operate in composition mode, `e.composed` is true.
   - The expression `(!e.composed || !this._keyDownSeen)` evaluates to `false`.
   - As a result, `xterm.js` drops virtual keyboard insertions on the floor and never calls `triggerDataEvent` or fires `term.onData`.
3. **Missing Textarea Event Listeners in Web Client**:
   - `terminal_pane_web.dart` only binds `term.onData` and a top-level `window.onKeyDown` listener (which skips events when the textarea is focused).
   - Neither `terminal_pane_web.dart` nor `xterm.js` listens to `beforeinput` or captures text entered into the helper textarea.

### Solution Design
1. **Listen to Helper Textarea Input Events**:
   - In `_bindContainerEvents()`, query `textarea.xterm-helper-textarea` within `_container`.
   - Attach `beforeinput`, `input`, and `compositionend` event listeners to the textarea.
2. **Handle Mobile Input Actions**:
   - `inputType == 'insertText'`: extract `event.data`, forward through `_sendMobileInput(data)`, and call `event.preventDefault()`.
   - `inputType == 'deleteContentBackward'`: forward backspace byte (`\x7f`), and call `event.preventDefault()`.
   - `inputType == 'deleteContentForward'`: forward delete sequence (`\x1b[3~`), and call `event.preventDefault()`.
   - `inputType == 'insertLineBreak'` or `inputType == 'insertParagraph'`: forward newline (`\r`), and call `event.preventDefault()`.
   - `inputType == 'insertFromPaste'`: extract `event.data` and route to `_handlePaste()`.
3. **Fallback Text Extraction**:
   - If `beforeinput` is not canceled or if `input` fires with text in `textarea.value`, read `textarea.value`, clear `textarea.value = ''`, and forward the text.
   - On `compositionend`, forward `event.data` and clear `textarea.value = ''`.
4. **Coordinate with Sticky Ctrl & Multi-line Paste**:
   - Create `_sendMobileInput(String text)` that checks `_ctrlArmed`. If armed, fold single characters into control codes via `controlByteForChar(text)` and disarm.
   - If incoming text is multi-line, route to `_handlePaste()` to preserve bracketed paste formatting and confirmation dialogs.
5. **Ensure Clean Listener Teardown**:
   - In `_unbindContainerEvents()`, remove all three listeners from the textarea so session swaps and container reuse do not leak listeners or cause duplicate input.

---

## Plan

1. **Implement Helper Textarea Listeners in `terminal_pane_web.dart`**:
   - Define fields for `_textareaBeforeInputListener`, `_textareaInputListener`, and `_textareaCompositionEndListener`.
   - Implement `_sendMobileInput(String text)` with sticky Ctrl and multi-line paste integration.
   - In `_bindContainerEvents()`, attach `beforeinput`, `input`, and `compositionend` listeners to `textarea`.
   - In `_unbindContainerEvents()`, detach listeners from `textarea`.
2. **Validation and Testing**:
   - Run `flutter analyze` to ensure clean static analysis.
   - Run `flutter test` across client tests.
   - Run `cargo check --workspace` and `cargo test --workspace`.
3. **Update Devlog**:
   - Document changes and rationale in `devlog/000139-fix-web-reload-scroll-bottom.md`.
