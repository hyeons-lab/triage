# 000083 — fix/session-term

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/session-term

## Intent

Backspace at a shell prompt in a new triage session inserts a space instead of
deleting the previous character. Backspace works correctly once inside a Claude
session in the same terminal. Find the root cause and fix it.

## Research & Discoveries

- 2026-06-21T15:10-0300 — Traced the whole input/output path:
  - Client (`flutter/triage_client`): native pane is `terminal_pane_stub.dart`
    (the non-web impl), rendering through `xterm: ^4.0.0`. Plain Backspace sends
    `\x7f` (xterm keytab default) and the daemon writes input bytes verbatim
    (`session.rs` `write_input`), so the byte reaching the shell is correct —
    confirmed by Claude (same path) working.
  - xterm.dart renders the shell's normal erase (`\b \b`) correctly; a written
    probe test confirmed it. So the output rendering is not at fault. It does,
    however, render a *bare* `\x7f` as a cursor-advancing blank — a red herring
    here, since shells never echo a bare DEL (no session log contains `0x7f`).
- 2026-06-21T15:20-0300 — Reproduced end-to-end by driving a real session over
  the daemon's Unix socket (StartSession → AttachSession InteractiveController →
  WriteInput `abc` then `0x7f`). The shell echoed `abc ` (a literal space), not
  an erase. Querying the session's environment showed **`TERM=[]`** (empty),
  `SHELL=/bin/zsh`, `erase=^?`.
- Isolated confirmation (zsh under a PTY):
  - `TERM` unset / empty → `abc ` (bug)
  - `TERM=dumb` / `xterm-256color` → `abc\b \b` (correct erase)

## Decisions

- 2026-06-21T15:24-0300 — Root cause: `spawn_pty_runtime` never sets `TERM`,
  and `portable_pty` 0.9.0 doesn't default it, so spawned shells inherit the
  daemon's `TERM`. A headless daemon (login service, or one re-exec'd via the
  self-update handover) has an empty `TERM`; with no terminfo, zsh's ZLE can't
  emit cursor-left to redraw and renders a backspace as a space. Claude is
  immune because it positions the cursor with hardcoded absolute sequences
  rather than terminfo.
- Fix: pin `TERM=xterm-256color` and `COLORTERM=truecolor` on the spawned
  command, set after the env scrub so they're authoritative. The correct
  terminal is defined by the client's emulator (xterm.dart, xterm-256color /
  truecolor class), not by however the daemon was launched — so set it
  unconditionally.

## What Changed

- 2026-06-21T15:24-0300 `crates/triaged/src/session.rs` — in
  `spawn_pty_runtime`, set `TERM=xterm-256color` and `COLORTERM=truecolor` on the
  `CommandBuilder` after `scrub_inherited_agent_session_env`. Added a regression
  test (`spawned_session_pins_term_for_the_client_emulator`) that spawns a shell
  and asserts it reports `TERM=<xterm-256color>`.

## Issues

- A blanket `RUST_LOG=debug` while watching a handover earlier in the day blew
  the 5s adoption timeout (separate finding); used a targeted filter instead.

## Commits

- HEAD — fix(triaged): pin TERM for spawned sessions so backspace works
