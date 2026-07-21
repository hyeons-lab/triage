## Thinking

"Error creating session" in the side rail on every attempt, from the native
Android client against a Windows daemon.

Reproduced against the live daemon by driving the WebSocket protocol
directly (pair -> `hello` -> `start_session`):

| command                              | result                          |
| ------------------------------------ | ------------------------------- |
| `/bin/sh -lc 'exec "${SHELL:-/bin/sh}"'` | `request_failed: spawning PTY child` |
| `cmd.exe`                            | ok                              |
| `bash`                               | ok                              |

So the daemon is healthy and two of the three shells work; the client is
asking for the one that cannot spawn.

`newSessionShellMenuOrderForPlatform` derives the shell list from
`defaultTargetPlatform` — the platform of the *client*, which says nothing
about the machine running `triaged`. On Android it yields exactly
`[defaultPosix]`, so:

- `_newSessionShell` initializes to `defaultPosix` (`/bin/sh`), which cannot
  spawn on a Windows daemon; and
- `showNewSessionShellMenuForPlatform` is false off Windows, so there is no
  menu to pick a working shell from.

The existing fallback made this terminal rather than merely wrong: it paired
`cmd <-> bash` but mapped `defaultPosix => null`, i.e. the one starting point
that *needs* a fallback on a foreign daemon is the one with none. It rethrows
and the rail shows the error. The `catch (e)` then discards `e`, so the
daemon's actual reason never surfaces anywhere.

The principled fix is for the daemon to advertise its OS in `hello` and the
client to pick from that. That is a protocol change across the JSON and
FlatBuffers paths plus the schema, and it is not needed to make this correct:
the client can simply try the other shells. Spawn failures are immediate
(~11 ms observed), and on a daemon whose platform matches the client the first
attempt succeeds and nothing else is tried.

## Plan

- Add `newSessionShellFallbackChain(preferred)`: the preferred shell followed
  by every other `NewSessionShell`. Derived from `values` rather than a
  hand-written pairing so it cannot go stale as variants are added.
- Rewrite the `_createSession` spawn step as a loop over that chain, keeping
  the first success and remembering the last error.
  - Rethrow `TriageAuthException` immediately: credentials are not a shell
    problem, no other command fares better, and the pairing screen depends on
    it propagating (see PR #101).
- `debugPrint` the failure reason in the catch, which currently drops `e`.
- Leave the menu gating alone. With the chain in place the Android client
  recovers without user action, and widening the menu is a separate UI call.
- Verify: `flutter analyze`, `flutter test`, and replay the exact chain an
  Android client would run against the live Windows daemon.
