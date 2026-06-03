## Thinking
A code review surfaced "lots of duplicate text" and "buffers updated in multiple places with different data" in the native interactive terminal. Tracing the data flow shows two independent buffers per session:

1. `xt.Terminal` — an ANSI-parsing emulator (`package:xterm`).
2. `SessionVm.rows: List<StyledRow>` — a plain line buffer used as fallback content for replay (e.g. on remount, resize, or `replayRevision` bump).

These buffers are mutated in two different places with different semantics:

- The WebSocket `Output` event handler in `main.dart` (the `if (event.containsKey('Output'))` branch) calls `session.terminalController.write(translatedText)` (which the terminal pane forwards to xterm — ANSI-aware) **and** naively appends the raw text to `session.rows` by splitting on `\n`. Embedded ANSI escapes, carriage returns, alt-buffer toggles, and progress-bar overstrikes get stored verbatim as `StyledSpan.text`.
- Snapshot/restore/resync paths (`_applySnapshotToSession`) overwrite `session.rows` with server-provided, structured styled rows.

When `_writeInitialContent` later replays `widget.fallbackRows` (= `session.rows`) into the terminal during a remount or replay bump, `styledSpanToAnsi` wraps each span's `text` with SGR codes and writes it verbatim. The embedded raw bytes get reinterpreted by xterm — clear-screen escapes fire mid-rewrite, the cursor jumps, and CR-overstrikes that were a single redraw in the live stream become stacked duplicate rows separated by `\r\n`.

The cleanest minimal fix (Option A) is to **stop the second writer**: live `Output` events go only to the terminal controller. `session.rows` is owned entirely by the snapshot path. Between snapshots `session.rows` is stale relative to the live terminal, which is fine because xterm holds the truth; on the next snapshot it catches up.

Test impact: the widget test `buffers output while daemon session placeholder is loading` asserts that mid-stream live output is findable via `find.text(...)` *before* the post-select refresh snapshot resolves. That assertion depends on the buggy naive-append behaviour (the test renders the fallback rows path because `FLUTTER_TEST` is set, so it only sees what's in `session.rows`). With Option A the same content will be reflected once the refresh snapshot resolves — the test should move the assertion to after the refresh and assert the fresh snapshot is what populates the rows. This is the correct end-to-end contract: the daemon snapshot is the source of truth for fallback display.

Out of scope (deferred to Option B):
- The `isExited` transition triggers a replay against the last snapshot rows, which is stale relative to recent live output. Today this is masked by the dual-write polluting `session.rows`. After Option A, an `Exited` event without a fresh snapshot would visually rewind the terminal to the last snapshot. We'll address that in Option B by making xterm authoritative and extracting rows from it for replay.
- The local mock input handler in `_setupSessionInputListener` also writes to both `session.rows` and `terminalController`. That's a local-only echo path for the offline hardcoded sessions and is not part of the live-output corruption.

## Plan
1. Create this plan file and update the branch devlog.
2. Edit `flutter/triage_client/lib/main.dart`: in the `Output` event branch (around lines 1251–1275), delete the naive `session.rows` mutation block. Keep the `terminalController.write` call and the `session.outputSeq = outputSeq` assignment. The outputSeq dedup guard above (`if (outputSeq <= session.outputSeq) return;`) stays unchanged.
3. Update `flutter/triage_client/test/widget_test.dart`: in `buffers output while daemon session placeholder is loading`, move the `find.text('live output during attach')` assertion to after `delayedRefresh.complete(...)` resolves with a snapshot that includes the line; remove the pre-refresh assertion. Adjust the helper-emitted snapshot rows accordingly.
4. Run `flutter test` in `flutter/triage_client` and confirm all suites pass.
5. Update `devlog/000047-feat-flutter-mobile-client.md` (Decisions, What Changed, Progress, Commits).
6. Stage and commit the plan, devlog update, code, and test edits in one logical unit.
7. Author the follow-up Option B plan (`000047-04-…`) as a planning document only — no implementation in this branch.
