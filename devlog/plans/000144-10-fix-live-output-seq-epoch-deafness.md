# 000144-10: Fix live output dropped after an output_seq epoch reset

## Thinking

`stuck-codex` (`session-218`) presented as a Codex session that would not take input:
the Codex UI was on screen, the cursor blinked, and typing produced nothing.

Server-side inspection contradicted the report. Reading the session straight off the
daemon's control socket (`SnapshotSession` over `$TMPDIR/triage-501/triage.sock`) showed
`exited: false`, a cursor at row 33 col 7, and `visible_rows` containing both the typed
prompts and Codex's replies to them:

```
› sassdnttyenfgccssasaddd does!
■ Conversation interrupted - tell the model what to do differently.
› tasdfasdfsdfas
• Could you resend your request? I couldn't make out what you need.
› sdfasdfasdf
• What would you like me to work on?
› sdfss
```

So input was reaching the PTY and Codex was responding. The session was never stuck; the
web client was not rendering. Deployment was ruled out as a cause first: the running
daemon was the current binary and the served `main.dart.js` was byte-identical to the
latest build, so every fix on this branch was already live.

That located the fault in the one path that can silently discard output: `output_seq`
de-duplication. `TerminalStore._isDuplicate` drops any live chunk at or below the history
high-water. But `output_seq` counts events within a single daemon *instance* — a handover
renumbers an adopted session from a low value while its byte log continues unbroken (the
daemon lists one adopted session twice, reporting identical `bytes_logged` under very
different `output_seq`). A client holding a pre-handover high-water therefore scores every
renumbered chunk as a duplicate, permanently: history stays frozen on screen, the cursor
keeps blinking because xterm is alive and focused, and keystrokes keep reaching the PTY
while nothing they produce is ever drawn. That is exactly the reported symptom, and it is
why the previous nine plans did not touch it — they addressed focus, leases, layout, and
the `awaitingHistory` buffering, all one branch later than the dedup baseline.

Two further defects made the state unrecoverable rather than merely transient:

1. `Attach` resets `_appliedLiveSeq` and `_appliedLogBytes` but not `historyHighWaterSeq`,
   so a stale baseline outlived the attach lifecycle it belonged to.
2. `TerminalState.copyWith` wrote `historyHighWaterSeq ?? this.historyHighWaterSeq`, so no
   caller could clear or null the baseline at all. The full-replay path intends to *set*
   the baseline from the snapshot; when `throughOutputSeq` was null it silently retained
   the stale value instead.

The history path already treats a regressed sequence as a new epoch (`isSequenceRegressed`).
The live path had no equivalent. A plain "lower seq means new epoch" rule cannot be reused
there, because ordinary re-delivery de-duplication depends on rejecting lower seqs. The
two are separable by magnitude: the daemon replays at most `EVENT_REPLAY_BUFFER` (1024)
events to a lagging subscriber and sends `ResyncRequired` beyond that, so no genuine
re-delivery can regress further than 1024. Anything below that is a new numbering epoch.
This gives a bound derived from the daemon's own contract rather than a tuned constant.

`_appliedLogBytes` is deliberately *not* reset on an epoch change: log byte offsets survive
a handover (the same session reports one `bytes_logged` across the adoption), so the value
stays valid and still anchors the next history delta-merge.

## Plan

1. In `flutter/triage_client/lib/terminal/terminal_state.dart`:
   - Add a `resetHistoryHighWaterSeq` flag to `copyWith` so the baseline can be cleared;
     `?? this` cannot express "clear".
2. In `flutter/triage_client/lib/terminal/terminal_store.dart`:
   - Add `kSeqEpochResetWindow = 1024`, documented against the daemon's `EVENT_REPLAY_BUFFER`.
   - Add `_isSeqEpochReset`, comparing an incoming seq against `max(highWater, appliedLiveSeq)`.
   - In `_reduceLive`, rebase on an epoch reset (clear `_appliedLiveSeq` and the baseline,
     keep `_appliedLogBytes`) before the duplicate check.
   - In the `Attach` reducer, clear the baseline alongside the other two dedup inputs.
3. In `flutter/triage_client/test/terminal/terminal_store_test.dart`:
   - Add a regression test replaying a handover: history at seq 90000, live at 90001, then
     live renumbered to 1 and 2 must still render.
4. Validate and deploy:
   - `flutter test`, `flutter analyze`, `dart format` on the edited files only.
   - `flutter build web --release`, then `triage client upgrade --src build/web`, which
     copies into the override dir and hot-reloads the daemon's web cache without a restart.
   - Verify by served content length, not by the reload command's success message.
