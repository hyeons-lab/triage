## Thinking

Reported symptom: the first session shown on startup cannot accept keyboard input,
but creating a new session (or switching to another session and back) restores input.

The persistent `xt.Terminal` now lives on `SessionVm` (single-source buffer work).
The native `TerminalPane` (`terminal_pane_stub.dart`) binds keyboard output exactly once,
in `initState`:

    _terminal.onOutput = _onTerminalOutput;

`_onTerminalOutput` is what forwards xterm keystrokes into the `TerminalController` input
listeners, which forward them to the daemon `writeInput`. Without it bound, every keystroke
is silently dropped.

On startup the first selected session is rendered first as a **loading placeholder**
`SessionVm` (`_loadingDaemonSession`, title `triage / <sid>`) and then replaced in place by
the **attached** `SessionVm` (`_loadDaemonSession`, same title `triage / <sid>`). Because
`TerminalPane`'s `key: ValueKey(session.title)` is identical across the swap, Flutter reuses
the same `_TerminalPaneState` and calls `didUpdateWidget` rather than `initState`.

`didUpdateWidget` rebinds the controller, the resize callback, and the focus revision — but it
never rebinds `onOutput` to the new `SessionVm.terminal`. So the attached session's terminal has
`onOutput == null` and input is dead.

A freshly created session mounts a brand-new pane (a title not currently in the tree as the
selected pane), so `initState` runs, `onOutput` is bound, and input works — exactly the
observed asymmetry. Switching to another session and back also remounts a fresh pane.

The web pane (`terminal_pane_web.dart`) is unaffected: it routes input through
`_sessionInputRouter` keyed by the constant `terminalId` and rebinds that router on controller
change, so the swap is already handled there.

## Plan

1. In `terminal_pane_stub.dart` `didUpdateWidget`, detect `!identical(oldWidget.terminal, widget.terminal)`:
   clear the old terminal's `onOutput`, bind `_onTerminalOutput` to the new terminal, and refocus
   so the swapped-in terminal accepts input.
2. Run focused Flutter tests (`cursor_position_test.dart`, `widget_test.dart`).
3. Rebuild and reinstall the macOS app; verify input works on the first session.
4. Update the branch devlog.
