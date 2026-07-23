# 000109 — feat/web-mobile-accessory-bar

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/web-mobile-accessory-bar

## Intent

The on-screen terminal accessory-key row (esc, sticky ctrl, tab, ⇧tab, enter,
arrows, ^C, shell symbols) renders on native iOS/Android but not on the web
client, so a phone/tablet browser can't send those important shortcuts at all.
Show the same row on the web client, on touch/small screens only (a mobile-OS
browser); desktop browsers keep the full-height terminal.

## What Changed

- 2026-07-22T23:08-0700 `lib/terminal/control_bytes.dart` (new) — moved
  `controlByteForChar` out of `terminal_pane_stub.dart` so both terminal panes
  (native + web, mutually exclusive conditional-import variants) can share it.
- 2026-07-22T23:08-0700 `lib/widgets/terminal_accessory_bar.dart` (new) — shared
  `TerminalAccessoryBar` widget (`onSend`, `onToggleCtrl`, `ctrlArmed`) rendering
  the one canonical key row, so native and web show *the same* bar.
- 2026-07-22T23:08-0700 `lib/widgets/terminal_pane_stub.dart` — import the shared
  `controlByteForChar`; render `TerminalAccessoryBar` in place of the inline
  `_buildAccessoryBar`/`_accessoryKey`. Behavior-preserving.
- 2026-07-22T23:08-0700 `lib/widgets/terminal_pane_web.dart` — sticky-ctrl folded
  into the next typed char at the xterm `onData` choke point, with the armed flag
  keyed by *session* (`_sessionCtrlArmed`) plus a rebuild hook
  (`_sessionCtrlRebuild`) because that callback is statically cached and reused
  across State instances; the shared bar renders at the bottom of `build()` when
  the browser is a mobile OS, padded by the keyboard inset.
- 2026-07-22T23:08-0700 `test/terminal_accessory_bar_test.dart` (new) — pumps the
  shared bar in isolation: each key emits its bytes through `onSend`, `ctrl`
  reports through `onToggleCtrl` (not `onSend`), and the `ctrl` key highlights
  only while armed.
- 2026-07-22T23:08-0700 `test/terminal_control_byte_test.dart` — repointed its
  import from the stub to the shared `control_bytes.dart` (the existing coverage
  of `controlByteForChar` moves with the function; no new duplicate file).

## Decisions

- 2026-07-22T23:08-0700 Touch/small-screens-only on web (user's choice) — gate on
  `defaultTargetPlatform == iOS || android` (the `isMobilePlatform()` signal), so
  desktop browsers are untouched and no viewport-width heuristic can misfire on a
  narrow desktop window.
- 2026-07-22T23:08-0700 Share the bar rather than fork it — the web and native
  panes are separate widgets, but the row is one `TerminalAccessoryBar`, so the
  two clients can never drift.
- 2026-07-22T23:08-0700 Tests live on the shared pieces — the web pane can't
  compile under the VM test runner (`dart:js_util`), so the fold logic
  (`controlByteForChar`) and the bar widget are tested in isolation; the web-pane
  glue is verified by a web build + manual check.

## Verification

`flutter analyze` clean for all changed files; `flutter test` — 193 pass;
`dart format` clean (the one pre-existing `_forceFinalizeTimer` reflow the
formatter wants is left out to keep the diff focused; CI does not gate format).
`flutter build web` confirms the web pane (the only piece the VM test runner can't
compile) builds. The web-pane glue — the `onData` sticky-Ctrl fold, the
`_isMobile` gate, keyboard-inset padding — is verified by the build plus manual
check on a mobile browser.

`/review-fix-loop max` ran two rounds. Round 1 (2 reviewers) surfaced one real
bug: the web pane caches the xterm `onData` callback statically and reuses it
across State instances, so folding sticky-Ctrl through an instance field would go
stale — fixed by keying the armed flag by session (`_sessionCtrlArmed`) with a
rebuild hook (`_sessionCtrlRebuild`) so the cached fold un-highlights the mounted
bar; both cleared in `_discardCachedSession`. Also deduped the web send/focus
helpers and widened the widget test to all keys. Round 2 (focused, 1 reviewer) on
the fix: NO FINDINGS.

## Commits

- HEAD — feat(triage_client): show the terminal accessory row on the mobile web client
