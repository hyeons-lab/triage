# Plan: confirm before closing a terminal session

## Thinking

The Flutter desktop client's workspace header has a close (`Icons.close`) button that
wires straight to `_closeSession(session)`. That method immediately calls
`_client.shutdownSession(...)`, disposes the `SessionVm`, and tears down the terminal pane
— no warning. A misclick permanently ends the remote session and any running processes,
which is unrecoverable. We want a confirmation step in front of the destructive action.

The app has no existing dialog/`showDialog` usage anywhere in `lib/`, so there's no shared
confirmation helper to reuse — I'll add a small one using Flutter's built-in `AlertDialog`,
styled to the app's dark palette (background `0xff161b1d`, border `0xff2a3437`, primary text
`0xffcdd7d6`, secondary `0xff9aa6a8`) and reusing the button conventions already present in
`_PairingView` (a muted `TextButton` for cancel, an `ElevatedButton` for the primary action,
8px radius, 20×12 padding). The primary action is destructive, so it gets a red background
(`0xffb3443f`) rather than the teal used for benign primary actions.

Gating happens inside `_closeSession` itself (rather than at the button) so every caller of
`_closeSession` is protected uniformly, and the existing teardown logic stays untouched after
the guard.

## Plan

1. Add `_confirmCloseSession(SessionVm)` to `_TriageHomeState`: `showDialog<bool>` returning
   true on confirm, false/null on cancel or dismiss. Name the session in the body via
   `session.title`.
2. At the top of `_closeSession`, await `_confirmCloseSession`; bail out unless the result is
   `true`. Leave the shutdown/dispose/teardown logic unchanged below the guard.
3. `flutter analyze lib/main.dart` — confirm no new issues.
4. Devlog + plan + code committed together; open PR.
