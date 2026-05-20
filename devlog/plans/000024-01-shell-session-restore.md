## Thinking

Argus can already recover historical session content by replaying raw PTY logs into the daemon terminal model. Restarting a shell should build on that recovery path without implying that Argus can resurrect arbitrary processes. The safe boundary is an explicit restore action for sessions whose persisted launch command was a plain shell, with the new PTY starting in the last known cwd from OSC 7 when available and the original launch cwd otherwise.

The restored session should keep the same session id so clients do not need a separate mapping layer. It should transition from historical to live only after the new PTY is spawned and the manifest is updated; failures should leave the historical session intact.

## Plan

1. Add a core request and `SessionApi` method for restoring a historical shell session.
2. Forward that method through the Unix socket transport.
3. Add daemon eligibility checks for plain shell launches and reject non-shell historical sessions.
4. Restart eligible sessions with the existing session id, original command/args, last known cwd fallback, and current size.
5. Persist the manifest after a successful transition and roll back to historical state if persistence fails.
6. Add daemon and IPC tests for successful restore, cwd selection, and rejection of ineligible/live sessions.
7. Run formatting and focused validation before updating the devlog.
