# feat/confirm-close-session

**Agent:** Claude Code (claude-opus-4-8) @ triage branch feat/confirm-close-session

## Intent

The workspace-header close button (`Icons.close`) in the Flutter desktop client ends a
terminal session with no confirmation — a single misclick calls
`_client.shutdownSession(...)`, disposes the `SessionVm`, and destroys the terminal pane,
permanently killing the remote session and its running processes. Add a confirmation
prompt in front of the destructive action.

## What Changed

- 2026-06-16T16:31-0700 `flutter/triage_client/lib/main.dart` — `_closeSession` now awaits
  a new `_confirmCloseSession(session)` guard and returns early unless the user confirms;
  the existing shutdown/dispose/teardown logic is unchanged below the guard.
- 2026-06-16T16:31-0700 `flutter/triage_client/lib/main.dart` — Added
  `_confirmCloseSession`, a `showDialog<bool>` styled `AlertDialog` matching the app's dark
  palette (bg `0xff161b1d`, border `0xff2a3437`) and the `_PairingView` button conventions:
  a muted `TextButton` "Cancel" and a destructive-red (`0xffb3443f`) `ElevatedButton`
  "Close session". The body names the session via `session.title` and warns the action
  cannot be undone.

## Decisions

- 2026-06-16T16:31-0700 Gate inside `_closeSession` rather than at the button callback — any
  current/future caller of `_closeSession` is protected uniformly, and the teardown path
  stays a single block after the guard.
- 2026-06-16T16:31-0700 Built a one-off `AlertDialog` instead of adding a shared
  confirmation widget — `lib/` had zero existing `showDialog` usages, so there was no
  pattern to extend and only one destructive action needs guarding today. Used a red primary
  button (`0xffb3443f`) to signal destructiveness, distinct from the teal (`0xff2b6f6f`) used
  for benign primary actions in `_PairingView`.

## Research & Discoveries

- 2026-06-16T16:31-0700 The Flutter client has no dialog infrastructure at all — no
  `showDialog`/`AlertDialog`/`Dialog` anywhere under `lib/`. Confirmation patterns must be
  introduced from Flutter's built-ins and themed by hand against the app palette.

## Issues

- 2026-06-16T16:31-0700 `flutter analyze lib/main.dart` reports 3 issues, all pre-existing
  and unrelated to this change (lines 2173, 2337, 3049 — null-aware element, deprecated
  `onReorder`, unnecessary `!`). No new issues introduced by the dialog.

## Next Steps

- Manual check: clicking the workspace-header close button now shows the confirm dialog;
  "Cancel"/dismiss leaves the session intact, "Close session" proceeds with the existing
  teardown.

## Commits

- HEAD — feat(client): confirm before closing a terminal session
