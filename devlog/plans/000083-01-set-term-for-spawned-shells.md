# Plan 000083-01 — set TERM for spawned shells

## Thinking

Symptom: backspace at a new session's shell prompt inserts a space and doesn't
delete; backspace works inside Claude in the same terminal.

The split (shell broken, Claude fine) is the tell. Claude drives the screen with
absolute cursor positioning; the shell's line editor (zsh ZLE) drives it with
relative motions loaded from terminfo, keyed off `$TERM`. So the difference is
terminfo availability, i.e. `$TERM`.

Verified the byte path is otherwise correct: the client sends `\x7f`, the daemon
writes it verbatim, the shell's normal erase (`\b \b`) renders fine in xterm.dart.
Reproduced through the real daemon and saw the shell echo a space on backspace,
with `TERM=[]`. Confirmed in isolation that an empty/unset `TERM` makes zsh emit
a space, while any real `TERM` (even `dumb`) makes it erase correctly.

`spawn_pty_runtime` never sets `TERM`; `portable_pty` doesn't default it; so the
shell inherits the daemon's environment, which is empty when the daemon runs
headless. The correct `TERM` is determined by the client's emulator (xterm.dart),
not the daemon's launch context, so it should be set unconditionally.

## Plan

1. In `spawn_pty_runtime` (`crates/triaged/src/session.rs`), after
   `scrub_inherited_agent_session_env`, set `command.env("TERM",
   "xterm-256color")` and `command.env("COLORTERM", "truecolor")`.
2. Add a regression test that spawns a shell printing `$TERM` and asserts it is
   `xterm-256color`.
3. Build + install the daemon and redeploy the running instance via
   `triaged --handover` (zero session loss).
4. Verify backspace now erases by re-driving a real session over the IPC socket.
5. Commit devlog + plan + code; open a draft PR.
