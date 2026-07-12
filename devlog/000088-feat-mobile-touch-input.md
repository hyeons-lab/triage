# 000088 — Mobile touch input: soft keyboard + key accessory bar

**Agent:** Claude (claude-opus-4-8) @ triage branch feat/mobile-touch-input

## Intent

Make the native Flutter app usable from a phone (iOS + Android). First slice of
Phase 7: get the existing shared-codebase app to accept input on a touch device
so it can be driven over Tailscale. Rendering (`xterm.dart`) already works; the
input path did not.

## Research & Discoveries

- 2026-07-11T22:38-0700 `terminal_pane_stub.dart:766` passed
  `hardwareKeyboardOnly: true` unconditionally. Added for a macOS-desktop IME
  desync, but it disables xterm's IME `TextInput` connection — the path that
  raises the **soft keyboard** on iOS/Android. Net effect: on a phone the
  terminal renders but cannot receive typed input. This is the single blocker to
  on-device usability.
- No `Platform.isIOS`/`isAndroid` UX branches existed anywhere in `lib/`;
  `defaultTargetPlatform` was used only for the copy chord. All pointer handling
  (shift-click, primary-button drag-select) is desktop-oriented.

## Decisions

- 2026-07-11T22:38-0700 Make `hardwareKeyboardOnly` platform-conditional
  (`!_isMobile`) rather than dropping it — desktop keeps the macOS IME fix.
- 2026-07-11T22:38-0700 Put the accessory bar in the native pane, not
  `SessionWorkspace`, so it never renders on the web client.
- 2026-07-11T22:38-0700 Apply sticky Ctrl by intercepting `_onTerminalOutput`
  (`codeUnit & 0x1f`) rather than synthesizing hardware key events, since
  soft-key input already flows through that seam.

## Plan

See `devlog/plans/000088-01-mobile-touch-input.md`.

## What Changed

- 2026-07-11T22:50-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`:
  - **Soft keyboard:** `hardwareKeyboardOnly` is now `!_isMobile` — desktop keeps
    the hardware-keyboard path (and the macOS IME-desync fix), iOS/Android use
    the IME path that raises the soft keyboard. `_isMobile` is a getter over
    `defaultTargetPlatform` (iOS/Android).
  - **Accessory bar:** `build()` now returns `Column[Expanded(terminal),
    if (_isMobile) _buildAccessoryBar()]`; the bar is a horizontally-scrollable
    row of keys a soft keyboard lacks (Esc, Ctrl, Tab, ▲▼◀▶, ^C, `/ | - ~`).
    Keys use a raw `GestureDetector` (no focus node) and re-focus the terminal
    after each tap so the keyboard is never dismissed. Mobile padding tightened
    to 8 (was 22).
  - **Sticky Ctrl:** the `ctrl` key arms `_ctrlArmed`; `_onTerminalOutput` folds
    an armed Ctrl into the next single character via the new top-level
    `controlByteForChar` (`codeUnit & 0x1f`), then disarms. Reset on session
    swap in `didUpdateWidget` so it can't leak across sessions.
- 2026-07-11T22:50-0700 `flutter/triage_client/test/terminal_control_byte_test.dart`
  — unit tests for `controlByteForChar` (letter case-folding, the `@[\]^_`
  range, null for no-control chars, single-char guard).

## Issues

- 2026-07-11T22:38-0700 The native pane's `build()` short-circuits to a plain
  fallback view under `FLUTTER_TEST`, so the accessory bar / TerminalView path is
  unreachable in widget tests. Tested the sticky-Ctrl mapping by extracting it to
  the top-level `controlByteForChar` and unit-testing that directly, rather than
  fighting the fallback gate.

## Validation

- 2026-07-11T22:50-0700 `flutter analyze lib/widgets/terminal_pane_stub.dart` —
  no issues in the changed file. `flutter analyze --no-fatal-infos
  --no-fatal-warnings` (CI's command) passes (pre-existing backlog only, none in
  this file). `flutter test` — 100 passed. Matches the CI "Flutter (analyze +
  test)" job; CI does not build iOS/Android.
- 2026-07-11T22:50-0700 `/review-fix-loop max` — 2 rounds, stopped clean. Fixed:
  sticky Ctrl reset on session swap; arrow-glyph `fontFamilyFallback`. Skipped
  (by-design): Ctrl staying armed across multi-char IME input.

## On-device session — 2026-07-12 (Pixel 10 Pro Fold, Android)

Ran the app on a real device over Tailscale. The soft-keyboard fix works (typing
confirmed on-device). On-device testing surfaced several mobile issues, fixed
this session; the last remaining input complaints are inherent to raw terminal
input (see Lessons).

### What Changed (this session)

- 2026-07-12T07:01-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`
  — added an **Enter** key (`\r`) to the accessory bar; the Android soft
  keyboard's return maps to an IME action that never reaches the terminal.
- 2026-07-12T07:01-0700 `flutter/triage_client/lib/main.dart`:
  - **Rail as full-screen overlay on mobile** — `build()` branches: mobile shows
    a full-screen workspace with the rail as a scrim-backed, slide/fade-animated
    overlay (`AnimatedPositioned` + `AnimatedOpacity`, `_sessionRailAnimationDuration`)
    that dismisses on select; desktop keeps the side-by-side `Row`. A ☰ menu
    button (`WorkspaceHeader.onOpenRail`) reopens it. Fixes the RenderFlex
    overflow / squished terminal.
  - **Rail scroll vs reorder** — `ReorderableDelayedDragStartListener` on touch
    (long-press reorders, drag scrolls); mouse keeps the immediate handle.
  - **Refit on device switch** — generalized `_redrawActiveSessionOnResume` →
    `_refitActiveSession` (re-asserts this device's terminal size on the shared
    PTY), still called on resume; a manual header button is a follow-up.
  - **`displayTitle`** — `repo · worktree` → `repo · branch` → cwd leaf →
    session id, so sessions are identifiable; the stable `title` key is untouched.
    Rail tile + header use it. Seeded from `_seedSessionContexts()` on connect.
- 2026-07-12T07:01-0700 `flutter/triage_client/lib/services/triage_websocket_client.dart`
  — `listSessionContexts()` (best-effort; a pre-upgrade daemon errors, swallowed).
- 2026-07-12T07:01-0700 **Daemon: `list_session_contexts`** (session identity in
  the list). `crates/triage-core/src/session.rs` (SessionApi trait method +
  blanket impl), `crates/triaged/src/session.rs` (`SessionManager` impl reading
  cached context off-lock via a new `ActorCommand::Context`), `crates/triage-transport-ws/src/lib.rs`
  (`ClientRequest::ListSessionContexts` / `ServerResult::SessionContexts` /
  `SessionContextEntry` / handler / test), `crates/triage-core/schema/triage.fbs`
  + `crates/triage-transport-ws/src/flatbuffers_proto.rs` (FB parity). Response
  carries git fields per session (no cwd; cwd rides `session_context_updated`).

### Issues

- 2026-07-12 **Live handover to deploy the daemon change failed.** The live
  daemon (pid 13793) had run 13 days (June 28 build); the handover protocol
  changed since (#97/#98), so the new binary never completed adoption (old daemon
  never logged "Received handover request"; the client stalled ~30s then was
  killed). Compounded by an intermittent Bash sandbox. Reverted
  `~/.cargo/bin/triaged` to the June-28 backup — live daemon + 32 sessions
  unharmed. The daemon change is built + tested but NOT deployed; deploy via a
  planned cold restart (`launchctl kickstart -k`, cold-restores sessions) when
  agent sessions are idle, or investigate the handover incompatibility.

### Lessons Learned

- Raw terminal input on mobile cannot offer predictive suggestions, swipe
  auto-space, or tap-to-position-cursor: the client streams each keystroke to the
  PTY and the remote shell owns line editing — there is no local text buffer.
  The fix for all three is an optional line-input bar (compose-then-send), not a
  keyboard config. Cursor movement is via arrow keys / readline chords.
- The handover IPC socket path derives from `TMPDIR`; a manual handover must run
  with the daemon's `TMPDIR` (here they matched, so this was not the failure).

## Validation

- 2026-07-11T22:50-0700 `flutter analyze lib/widgets/terminal_pane_stub.dart` —
  no issues in the changed file. `flutter analyze --no-fatal-infos
  --no-fatal-warnings` (CI's command) passes (pre-existing backlog only, none in
  this file). `flutter test` — 100 passed. Matches the CI "Flutter (analyze +
  test)" job; CI does not build iOS/Android.
- 2026-07-11T22:50-0700 `/review-fix-loop max` — 2 rounds, stopped clean. Fixed:
  sticky Ctrl reset on session swap; arrow-glyph `fontFamilyFallback`. Skipped
  (by-design): Ctrl staying armed across multi-char IME input.

## Next Steps

- Deploy the daemon `list_session_contexts` change (planned cold restart or
  handover-compat investigation), then verify `repo · worktree` titles on-device.
- Optional line-input bar (compose-then-send) for suggestions / cursor editing.
- Follow-ups: manual "refit" header button; selected-session-to-top on rail
  reopen; lazy-load sessions (the 50-concurrent-subscribe timeout).

## Commits

The mobile work is split so the client (verified on-device) can ship ahead of
the daemon protocol change (built + unit-tested, but its on-device end-to-end
handover failed, so it is held back — see Issues).

- HEAD — feat(triage_client): mobile usability + repo·worktree titles (rail
  overlay, accessory Enter, touch scroll, refit, `displayTitle` + client-side
  `list_session_contexts` seeding; widget tests gated to the desktop layout).
  PUSHED.
- (local, unpushed) — feat(session): `list_session_contexts` — daemon side of
  the titles (triage-core / triaged / triage-transport-ws + FB parity). Held
  local until verified end-to-end on-device.
- 0359d88 — feat(triaged): mobile soft keyboard + key accessory bar
