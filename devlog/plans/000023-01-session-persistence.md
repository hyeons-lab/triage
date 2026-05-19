## Thinking

Argus already writes raw PTY bytes to per-session logs and uses `wezterm-term` as the daemon-owned terminal model. That means the first persistence slice should not invent a new history store. Persist a small manifest with session identity and launch metadata, then rebuild terminal snapshots by replaying the raw logs into a terminal model when the daemon starts.

This branch should not promise live process resurrection. A daemon-owned PTY child dies when the daemon shuts down or crashes. Replaying terminal contents and metadata is useful now; restarting plain shells or moving PTY ownership into long-lived workers can be separate follow-up work.

## Plan

1. Add a daemon session manifest file under the existing session log directory.
2. Persist new sessions when `SessionManager::start_session` succeeds.
3. Load manifest entries in `SessionManager::new`, replay existing log files into terminal state, and expose them as exited historical sessions.
4. Keep write/input/resize operations rejected for historical sessions while `snapshot`, `styled_rows`, `attach`, and `list_sessions` work.
5. Add focused daemon tests for manifest creation, manager restart, recovered snapshots, and recovered styled history.
6. Run formatting and focused validation before updating the branch devlog.
7. Review follow-up: preserve the client contract that listed sessions can be subscribed before attach by returning an inert closed event stream for historical sessions.
