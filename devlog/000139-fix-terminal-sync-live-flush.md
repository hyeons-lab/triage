# 000139 — fix/terminal-sync-live-flush

**Agent:** Muse Code @ triage branch fix/terminal-sync-live-flush

## Intent

Fix the client appearing frozen (no output updates until the user types) in sessions running `agy`, and investigate the missing in-terminal composer input box on the Android app.

## What Changed

- 2026-09-04T22:11-0700 `flutter/triage_client/lib/terminal/terminal_store.dart` — an open synchronized-output (Mode 2026) block now flushes every 100ms (`kSyncOutputLiveFlushInterval`) while staying open. Previously a sustained stream re-armed the 50ms idle watchdog on every chunk, so the screen froze for the whole generation and painted only at the closing marker. Small back-to-back frames still land atomically. Timer is cancelled on block close, cap force-flush, reset, and dispose.
- 2026-09-04T22:11-0700 `flutter/triage_client/test/terminal/terminal_store_test.dart` — new test: open block flushes progressively during sustained streams, remainder closes at the end marker without loss/duplication, interval stops after close.
- 2026-09-04T22:11-0700 `flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart` — new pure helpers `shouldReleaseScrollPin` (downward scroll within 3 lines of the bottom releases the pin) and `shouldRestoreSavedOffset` (revisit restores only when the buffer has not grown).
- 2026-09-04T22:11-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart` — pin release snaps to the bottom (clearing alone would leave the viewport parked short of a still-growing bottom); revisit drops stale saved offsets instead of yanking away from live output; scroll direction state reset on terminal swap and programmatic jumps.
- 2026-09-04T22:11-0700 `flutter/triage_client/test/terminal/terminal_scroll_anchor_test.dart` — unit tests for both helpers.
- 2026-09-06T07:12-0700 `flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart` — moved the two new helpers above the `TerminalScrollAnchor` doc comment. They had been inserted between that comment and its class, which silently reassigned the class's documentation to `shouldReleaseScrollPin`.
- 2026-09-06T07:20-0700 Rebased onto `origin/main` (c677c4c). Dropped `shouldRestoreSavedOffset`, `_sessionSavedScrollMaxExtents` and their tests: #160 landed per-session saved `TerminalScrollAnchor`s, which supersede them. Kept the pin release, merged into #160's `_captureScrollAnchor`; the release path now also calls `_saveScrollOffset` so retiring the pin retires the stored offset and anchor with it. Renumbered the devlog and plan from 000136 to 000139 (#157 took 000136 upstream).
- 2026-09-06T08:40-0700 `flutter/triage_client/lib/terminal/terminal_store.dart` — `dispose` now clears `_inSynchronizedOutput`, and the three block-close sites (end marker, capacity cap, idle watchdog) go through one `_closeSyncBlockAndFlush` helper. A live-flush tick writes to the sink part-way through, so a listener reacting to that write can dispose the store mid-tick; the tick then resumed, still saw the flag set, and armed a fresh timer on a disposed store, which re-armed itself every interval from then on.
- 2026-09-06T08:40-0700 `flutter/triage_client/test/terminal/terminal_store_test.dart` — regression test for that race, with a sink that disposes the store from inside `write`. It asserts on `nonPeriodicTimerCount` rather than a later write, because `dispose` clears the buffer and the leaked timer's flush is therefore silent.
- 2026-09-06T08:40-0700 Doc comment corrections: `shouldReleaseScrollPin` no longer claims "all pure doubles" (`graceLines` is an `int`), and `_lastScrollPixels` documents that programmatic jumps store the offset they jumped to rather than nulling it.

## Decisions

- 2026-09-06T08:40-0700 Declined a sub-pixel epsilon on `shouldReleaseScrollPin`'s bottom comparison (review suggestion). The grace band is `graceLines * lineHeight`, about 51px at the default 3 lines, so float rounding of a few ulps cannot decide the branch; an epsilon would only matter at `graceLines: 0`, which no caller uses. Left it out rather than adding an unexplainable constant.
- 2026-09-06T07:20-0700 On rebase, #160's saved-anchor restore replaces this branch's `shouldRestoreSavedOffset` guard rather than sitting alongside it. An anchor tracks its buffer line as the buffer grows and trims, so it cannot go stale the way a raw pixel offset does, and the `maxScrollExtent` heuristic it needed becomes dead weight. The pin release is kept and matters more after #160, not less: persisting anchors across session switches means a saved pin re-applies on every revisit, so without a release the treadmill follows the user between sessions.

- 2026-09-04T22:11-0700 Time-based progressive flush (100ms) rather than byte-threshold: a full-screen repaint frame can legitimately be ~200KB, so a byte threshold would tear frames mid-repaint; a 100ms cadence keeps small frames atomic in practice while bounding staleness during streams.
- 2026-09-04T22:11-0700 No change to the Android composer rendering path: replayed 1.25MB of real `agy` bytes (including a composer frame) through the exact xterm.dart fork the app uses at 80x12 through 102x41, and the composer renders at every size. The remaining composer suspect is device-side (viewport, fitted size with keyboard open, or focus).

## Issues

- 2026-09-04T22:11-0700 `flutter test` cannot run in this sandbox (flutter_tester needs a loopback server socket; SDK self-update and telemetry paths are outside the writable roots). Worked around with a /tmp SDK copy plus a plain-`dart` harness running the byte-identical reducer with FakeAsync: 9/9 pass. `dart analyze` clean, files formatted. Re-run `flutter test` outside the sandbox.
  - Resolved 2026-09-06T07:12-0700: re-ran outside the sandbox. Full suite green, including the pre-existing `session scroll preservation` widget tests that cover the changed pane paths. After the rebase onto c677c4c: 431/431 pass and `flutter analyze` reports no issues.
- 2026-09-04T22:11-0700 `git fetch origin` fails here (SSH to GitHub denied), so the worktree is based on local `main` at 56bec41, not a freshly fetched `origin/main`.
  - Resolved 2026-09-06T07:20-0700: fetched outside the sandbox and rebased onto `origin/main` at c677c4c, which had moved three commits ahead (#157, #158, #160).

## Commits

- 9d1b5f2: fix(client): flush open synchronized-output blocks during sustained streams
- HEAD: fix(client): close synchronized blocks through one helper and stop a post-dispose re-arm

## Progress

- [x] Root-cause the freeze (2026 blocks up to 844KB in daemon session logs; watchdog starvation in `TerminalStore`)
- [x] Implement progressive flush + regression test
- [x] Verify via standalone harness + analyze + format
- [x] Move fix into worktree
- [x] Verify with the real `flutter test` outside the sandbox
- [x] Rebase onto current `origin/main`, reconcile with #160's scroll cache, renumber devlog (431/431, analyze clean)
- [x] Address PR #161 review feedback (Copilot + Antigravity)
- [ ] Rebuild Android APK with the fix and install on device (blocked: Java/adb sockets denied in this sandbox; user runs `flutter build apk --release` + `adb install -r` themselves)
- [x] Root-cause the Android composer (scroll-pin treadmill + stale revisit restore, native pane only; web unaffected by construction)
- [x] Implement pin release on downward chase + snap, stale-restore guard, unit tests
- [ ] On-device confirmation of both fixes (needs fresh APK build)

## Next Steps

- Build `flutter build apk --release` from this worktree and sideload onto the Pixel 10 Pro Fold.
- Confirm the freeze is gone on-device; capture the composer case (screenshot or scroll check).
