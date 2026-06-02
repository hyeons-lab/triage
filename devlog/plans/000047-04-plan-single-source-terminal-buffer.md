## Thinking
Option A (plan 03) removed the immediate corruption: live `Output` events no longer mutate `session.rows`. That fixes the duplicate-text symptom. It does not fix the deeper structural problem — there are still two buffers per session whose contents diverge between snapshots:

- `xt.Terminal` (xterm) — authoritative live state, owns ANSI parsing, scrollback, alt-buffer, cursor.
- `SessionVm.rows: List<StyledRow>` — frozen at the last snapshot from the daemon.

Whenever `_writeInitialContent` is invoked (mount, `replayRevision` bump, `isExited` flip, cursor change, `replayPending` clear, controller swap — `terminal_pane_stub.dart:108-129`), the pane resets the terminal and replays `widget.fallbackRows`. After Option A those rows are clean, but they are also stale relative to anything that has streamed in since the last snapshot. So a remount or an `isExited` transition between snapshots visually rewinds the terminal to the snapshot frame and loses live content the user already saw. This is a regression risk Option A trades for: the bug it removes (duplicate text) is worse than the bug it exposes (occasional snap-back), but neither is correct.

Option B's principle: **xterm owns the live state, period. The fallback `StyledRow` buffer becomes a snapshot-time view used only for accessibility (the `FLUTTER_TEST` branch) and for the very first replay before xterm has any content.** When we need to "replay" mid-session, we read rows out of xterm itself instead of from a stale snapshot.

There are two natural axes:

### Axis 1 — Replay source
- **B1: extract rows from xterm.** Walk `_terminal.buffer.lines` (or the public equivalent) when we need to replay, converting cells to `StyledRow`/ANSI on demand. Pros: always current. Cons: requires inspecting xterm's API and handling alt-buffer/wrap/cursor decoupling.
- **B2: stop replaying mid-session.** Most of the `didUpdateWidget` triggers don't actually require tearing down and rewriting xterm. The terminal is already correct in place; only a controller swap or a real resync (server-issued `ResyncRequired`) needs a full rewrite. Pros: minimal code. Cons: doesn't help the cold-mount path (e.g. switching to a tab whose pane was disposed).

Likely we want both: keep xterm alive across the trigger storm (B2), and when we genuinely must rebuild (cold mount, resync), seed from xterm if it's available and from the snapshot if not (B1).

### Axis 2 — Pane lifetime
Today `SessionWorkspace` builds `TerminalPane` with `key: ValueKey(session.title)` (`main.dart:2251`). Selecting a different session unmounts the previous pane and disposes its xterm. When the user switches back, we replay from `session.rows`. If we move the live source-of-truth into xterm, we either need to:

- **Keep panes mounted for all sessions** behind an `IndexedStack`, so xterm survives session switches. Cleanest semantics; cost is N live xterms.
- **Persist the xterm `Terminal` instance on `SessionVm`** (move ownership from `_TerminalPaneState` to `SessionVm`). The pane attaches a view to the existing terminal on mount instead of constructing a new one. xterm.dart supports this — the `Terminal` is decoupled from `TerminalView`.

The second is cheaper and matches how `TerminalController` already lives on `SessionVm`. Recommended.

### Tests
- Update `widget_test.dart:'applies daemon snapshot events to replace restored rows'` — under Option B, a mid-session snapshot should NOT erase xterm content. The test currently asserts the new snapshot replaces the visible rows; the right shape becomes: the *fallback row buffer* is replaced, but the live xterm view is not perturbed. The test renders the FLUTTER_TEST fallback path so the existing assertions about row replacement still hold.
- Add a regression test for "remount does not rewind live output": render a session, write live output via `controller.write`, force a `replayRevision++`, and assert the live output is still on screen. Requires either (a) running outside `FLUTTER_TEST` so xterm renders, or (b) exposing a test hook that reports what the pane would replay (e.g. the row count it would write).
- Add a regression test for "exited transition keeps last output visible".

### Scope guard
This plan is documentation only — it will not be implemented on `feat/flutter-mobile-client`. Implementation belongs on a follow-up branch so the mobile-client scaffolding PR can land with a clean, minimal terminal fix.

### Open questions to resolve before implementing
1. xterm.dart 4.x public API for reading buffer cells with style — confirm before committing to B1.
2. Does the daemon ever push a `Snapshot` event that is *narrower* than the live xterm state (e.g. after a server-side resize)? If so, the snapshot path needs to update the canonical size and tell xterm to resize, not just replace rows.
3. Behavior on `Exited`: should we keep the live xterm view (final frame the user saw) or replace it with a "session ended" overlay? Today we flip `isExited` which currently re-triggers a stale replay; under B2 we'd leave xterm alone and just render the chrome change.
4. Memory: how many simultaneous live xterm instances are realistic? On mobile a dozen attached sessions × 10k-line scrollback is noticeable.

## Plan
Implementation belongs on a separate follow-up branch (suggested: `feat/flutter-terminal-single-source`). This plan file captures the design so future-us can pick it up. The steps below describe that future work; **none of them are part of this branch.**

1. Move `xt.Terminal` ownership onto `SessionVm`. Construct it when the session is created; dispose it when the session is removed.
2. Refactor `TerminalPane` to attach a `TerminalView` to the session's existing `Terminal` instead of creating a fresh one in `initState`. Re-create the view but reuse the model across mounts.
3. Collapse `didUpdateWidget`'s 4-branch replay storm. Reset+replay only on:
   - first mount of a session whose `Terminal` is empty (no buffer lines written), or
   - explicit `ResyncRequired` from the daemon, or
   - a confirmed cursor/size mismatch that requires resetting.
   `isExited` flip, `replayRevision` bump, and cursor-only changes no longer replay; they update chrome.
4. When a replay is genuinely required and the live `Terminal` already has content, **seed from xterm**: read the visible/scrollback buffer, convert to `StyledRow` for the cold view, then re-feed via the snapshot ANSI path. Fall back to `widget.fallbackRows` only when the terminal has nothing.
5. Delete the `_pendingLiveWriteBuffer` mechanism — with persistent `Terminal` instances, `_onWrite` always has somewhere to land.
6. Update / add the widget tests described above. Where the existing test asserts the fallback-rows replacement on `emitSnapshot`, keep that assertion (the fallback buffer still updates from snapshots), but add a sibling assertion (via a test-only hook) that the live xterm content was not touched.
7. Address the `_estimatedTerminalRestoreSize` font-metric drift (`9.0`/`18.0` constants vs. the actual `fontSize: 15`) so the initial snapshot is requested at the size we'll actually render at — avoids the immediate post-attach reflow + resize roundtrip.
8. Consider splitting `main.dart` (currently ~2700 lines) into `SessionVm`, websocket-event-loop, pairing UI, and the workspace shell. Not blocking but the file's size makes this kind of architectural change risky.

## Out of scope for Option B
- A wholesale move to a different terminal package.
- Server-side protocol changes (e.g. delta updates between snapshots).
- Reworking the local-mock offline path; its dual-write of input echo is a separate concern.
