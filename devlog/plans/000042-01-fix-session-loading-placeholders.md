## Thinking

The merged session-loading changes create placeholders with the final `triage / <session_id>` title before the attach path has finished. That makes title-based WebSocket event routing find the placeholder and consume live events too early. The replacement path also destroys the terminal cache for the same title that a mounted `TerminalPane` keeps using, which can leave the selected pane bound to a disposed xterm instance.

The smallest safe change is to keep loading placeholders visible but not event-ready, then drain buffered events once the attached `SessionVm` replaces the placeholder. For terminal lifecycle, same-title replacement should dispose only the old controller listeners and let the mounted `TerminalPane` update to the new controller without destroying the cached xterm.

## Plan

1. Update `_processWebSocketEvent` to buffer events when the matched session is still `loading`.
2. Update daemon placeholder replacement to skip `TerminalPane.destroySession` when the replacement keeps the same terminal title.
3. Add widget coverage for an output event emitted while a daemon session placeholder is still loading.
4. Run Flutter tests for `flutter/triage_client`.
