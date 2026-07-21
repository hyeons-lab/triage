# 000098 — fix/session-shell-fallback

## Agent

Claude Code (Opus 4.8, 1M context).

## Intent

Fix "Error creating session" on every new-session attempt from the native
Android client against a Windows daemon, and stop the create path from
swallowing the daemon's reason.

## What Changed

- `flutter/triage_client/lib/main.dart`
  - Added `newSessionShellFallbackChain(preferred)` — the preferred shell
    followed by every other `NewSessionShell`, derived from `values`.
  - `_createSession` now loops that chain instead of consulting a hand-written
    `cmd <-> bash` pairing, keeping the first shell that spawns.
    `TriageAuthException` still short-circuits so pairing errors reach the
    pairing screen.
  - The create-failure `catch` now `debugPrint`s the error it had been
    discarding.
- `flutter/triage_client/test/widget_test.dart` — asserts every starting point
  reaches every shell, preferred first.

## Decisions

- **Client-side chain rather than a daemon-advertised platform.** The correct
  long-term shape is for `hello` to report the daemon's OS, since only the
  daemon knows what it can spawn. That is a protocol change across the JSON
  and FlatBuffers paths plus `triage.fbs`, and it is not required for
  correctness here — trying the other shells reaches the same answer. A failed
  spawn returns in ~11 ms, and a client whose platform matches the daemon
  succeeds on the first attempt and never tries another.
- **Chain built from `NewSessionShell.values`**, not a hand-maintained pairing.
  The pairing is exactly what broke: it covered `cmd <-> bash` and left
  `defaultPosix` with no fallback, which is the one case that needed it.
- **Menu gating left alone.** `showNewSessionShellMenuForPlatform` still hides
  the picker off Windows. With the chain in place the Android client recovers
  on its own; widening the menu is a UI decision worth making separately.

## Issues

The failure was invisible from the client. `_createSession`'s `catch (e)`
discarded `e` and set a fixed "Error creating session" string, so the daemon's
`spawning PTY child` never reached the user, `debugPrint`, or the rail. Root
cause had to be recovered by driving the WebSocket protocol by hand. The
`debugPrint` added here is the minimum needed to keep the next instance of
this from being opaque.

## Research & Discoveries

- Reproduced against the live Windows daemon by scripting the protocol
  (`pairing_challenge` -> `GET /pair?device_code=...` for the PIN -> `pair` ->
  `hello` -> `start_session`). Same-host approval means the daemon hands back
  the PIN without interaction, so the whole flow scripts cleanly — a useful
  harness for any future daemon-side repro.

  | command | result |
  | --- | --- |
  | `/bin/sh -lc 'exec "${SHELL:-/bin/sh}"'` | `request_failed: spawning PTY child` |
  | `cmd.exe` | ok |
  | `bash` | ok |

- Replaying the new chain as an Android client would run it against that same
  daemon: `defaultPosix` fails, `cmd` succeeds, session created.
- **Resize is a separate, still-open bug.** Reported alongside this one:
  content does not reflow when the view changes size on Android. The daemon
  side was cleared — `resize_session` applies the new size (verified 80x24 ->
  120x30) and `reflow_from_log` genuinely rewraps: a 100-character line
  occupying two rows at 80 columns came back as one row at 120. Whatever is
  wrong is client-side, in the pane's fit -> `sendResizeOut` path or in how the
  resulting snapshot is rendered. Not addressed here.

## Review

PR #115, first round:

- **An empty session id broke out of the chain.** `startSession` degrades a
  response carrying no `session_id` to `''` rather than throwing, so the loop
  marked it spawned and stopped. The `sessionId.isNotEmpty` guard below then
  skipped the whole subscribe/attach block and the method returned with the
  rail still reading "Creating session..." — no success, no error, nothing to
  retry. A real dead end, not a theoretical one. Now treated as a failed
  attempt so the chain continues.
- **`debugPrint` carried no stack trace**, which is what distinguishes a spawn
  failure from a later subscribe/attach failure; the message alone does not.
  Now `catch (e, stackTrace)`.
- **Devlog H1 was missing its number.** Every other devlog opens
  `# 0000NN — <branch>`; this one opened with the branch alone.

Both code findings are covered by tests that were confirmed to fail without
their fix, rather than being assumed to.

Renumbered 000096 -> 000098 after #113 merged and took 000096, with #114
taking 000097. Parallel branches all picked the same next number; with #113
landed, the convention's "highest in devlog/, incremented" resolves to 000098
here.

## Commits

- e35c117 — fix(triage_client): try every shell when creating a session
- 85856be — fix(triage_client): treat an id-less start_session as a failed attempt
- HEAD — docs(devlog): renumber to 000098 after 000096 landed on main

## Progress

Fix implemented and verified end-to-end against the live daemon.
`flutter analyze` clean for the touched code; `flutter test` 140 passing.

## Next Steps

- Investigate the Android reflow bug from the client side (see above).
- Consider having `hello` advertise the daemon's OS, which would let the menu
  and the initial shell reflect the machine that actually spawns them instead
  of the device holding the phone.
