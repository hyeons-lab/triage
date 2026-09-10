# Plan: Refactor Terminal Input & Session Switching Lifecycle

## Thinking

The user reported:
1. Total input failure across terminal sessions in the Flutter web client ("I can't input in any now").
2. Full-screen terminal sessions like Codex/Astra appearing on screen and then immediately disappearing/blanking out.
3. The terminal input logic has grown fragile, fragmented across multiple layers (nested timers, DOM traversals, manual VT100 translations, async attach loops, destructive blur and clear sequences).

### Root Causes of Fragility

1. **Destructive blur on dispose**:
   `_TerminalPaneState.dispose()` explicitly called `textarea.blur()` and `_term.blur()`.
   When switching sessions or updating widgets, disposing the prior pane stripped browser DOM focus to `document.body`, breaking keyboard input until manually clicked or retried.

2. **Uncoordinated History Replay & Screen Blanking**:
   - `_loadDaemonSessionInto` called `session.noteViewFit(...)` before `TerminalPane` mounted or bound to the new `session.terminalController`. Staged history was written to an unbound controller with no write listeners, losing the entire initial render.
   - `_onSessionViewFit` re-triggered `_refreshSessionSnapshot(session, includeHistory: true)`, which called `session.applyHistory(...)` a second time.
   - In `TerminalStore._reduce(HistoryBytes)`, `_sink.clear()` called `controller.clear()`.
   - In `terminal_pane_web.dart`, `onClear()` invoked `js_util.callMethod(term, 'write', ['\x1b[2J\x1b[3J\x1b[H'])`, sending raw VT100 clear-screen and clear-scrollback escape sequences. For full-screen TUI apps (Codex, Claude Code, vim, etc.) in the alternate screen buffer, this permanently wiped the rendered screen, making sessions appear and then disappear.

3. **Complex, Fragile Input Dispatch Chain**:
   - `_setupSessionInputListener` in `main.dart` introduced an asynchronous `attachSession` retry chain on every keystroke when `session.status != 'attached'`. Keystrokes typed while a session was transitioning from `'idle'` or `'loading'` were dropped synchronously.
   - `_eventTargetsTerminal` had an 8-branch gate checking `_containerEventOwners` identity, Flutter focus trees, Shadow DOM roots, and tag names. During session transitions, ambient window keydowns were falsely rejected.
   - `_windowKeyDownListener` manually mapped keys through `_keyboardEventToInput(event)`. If xterm's textarea wasn't focused, only keys in that hardcoded map were sent; other keys, shortcuts, or IME inputs were lost.

### Architecture for Robust, Simplified Terminal Input

1. **Direct Focus Ownership**:
   - The active mounted `TerminalPane` owns keyboard focus.
   - When the pane is mounted or selected, activate and focus xterm's helper textarea (`term.focus()`).
   - Never call `.blur()` in `dispose()`. Let the browser manage focus naturally across DOM transitions.
   - Eliminate redundant retry timers (50ms, 150ms, 300ms cascades).

2. **Streamlined Ambient Input & Fallback**:
   - When a keystroke occurs:
     - If focus is already in the terminal's textarea, let xterm.js process it natively through its standard `onData` callback.
     - If focus is on `document.body` or an uneditable element while this terminal is the active view, immediately forward the keystroke via `_keyboardEventToInput` and call `_activateTerminal(force: true)` to return native focus to xterm.
     - Only defer when focus is on a real editable text field outside the terminal (the rail search box, a modal dialog).
   - In `_eventTargetsTerminal`, simply check if the mounted pane is current and not exited, and that the user is not editing an external text field.

3. **Direct, Synchronous Input Transport**:
   - Revert `_setupSessionInputListener` in `main.dart` to a clean, synchronous write: when `_client.isConnected` and `sessionId != null`, dispatch `_client.writeInput(sessionId: sessionId, clientId: _clientId, bytes: utf8.encode(keys))` directly.
   - Drop the async `attachSession` loops on keystrokes. Lease acquisition is handled reliably when the session is selected in `_selectSession` and `_loadDaemonSessionInto`.

4. **Stable Session Switch & Safe Clear**:
   - In `terminal_pane_web.dart`: In `onClear()`, remove `js_util.callMethod(term, 'write', ['\x1b[2J\x1b[3J\x1b[H'])`. Use only `term.clear()` so buffer lines are cleared without blasting terminal-destroying escape sequences into alternate screen apps.
   - In `main.dart`: Remove early `session.noteViewFit` from `_loadDaemonSessionInto`. Let `TerminalPane` report view fit after `_bindController()` has registered `onWrite` on the controller.
   - In `_onSessionViewFit`: Use `includeHistory: false` on the snapshot refresh. The session's history is already staged and applied on attach; resizing the daemon PTY sends live repaints without needing a second destructive snapshot replay.

---

## Plan

1. **Simplify `flutter/triage_client/lib/widgets/terminal_pane_web.dart`**:
   - In `onClear()`: Remove `js_util.callMethod(term, 'write', ['\x1b[2J\x1b[3J\x1b[H'])`.
   - In `_eventTargetsTerminal`: Accept events if `identical(_currentMountedPane, this)` is true and no external editable input holds focus.
   - In `didUpdateWidget`: Bind controller first, then notify `widget.onViewFit` with fitted dimensions, and focus.
   - In `dispose()`: Remove destructive `textarea.blur()` and `_term.blur()` calls.

2. **Simplify `flutter/triage_client/lib/main.dart`**:
   - In `_setupSessionInputListener`: Restore direct `_client.writeInput` without async attach chaining.
   - In `_loadDaemonSessionInto`: Remove the premature `session.noteViewFit` call before widget binding.
   - In `_onSessionViewFit`: Use `includeHistory: false` so that the first view fit resizes the host without triggering a second history replay that clears the terminal.
   - In `_selectSession`: Ensure `session.status = 'attached'` when selecting an active remote session.

3. **Validation**:
   - Run `flutter test` across all 454 tests.
   - Verify `cargo check --workspace` and `cargo test --workspace`.
   - Build web bundle: `flutter build web --release`.
   - Install binary: `cargo install --locked --path crates/triaged`.
   - Ad-hoc codesign: `codesign -s - -f ~/.cargo/bin/triaged`.
   - Reload daemon via zero-downtime handover protocol: `~/.cargo/bin/triaged reload` with `WaitMsBeforeAsync: 10000`.
   - Reload client cache: `triage client reload`.

4. **Devlog & Commit**:
   - Update `devlog/000144-fix-web-terminal-focus-lifecycle.md` with real timestamps.
   - Commit with Conventional Commits and push to `origin/fix/web-terminal-focus-lifecycle` with explicit destination refspec.
