# 000153-01 mobile terminal paste

## Thinking

2026-09-20T13:30-0700. Report: paste does not work in the triage
terminal on mobile (Android, long-press). Code read confirms there is
no soft-keyboard paste path to break: the xterm fork never shows the
system edit menu (`showToolbar` no-op), triage consumes long-press for
selection with a Copy-only button, and the accessory bar has no paste
key. Only a hardware chord or an IME clipboard-chip commit can paste,
neither of which a long-press produces.

Fix shape: a `paste` key on the shared `TerminalAccessoryBar` calling a
new required `onPaste`. Native pane reuses `_pasteFromClipboard`
(clipboard read, `_handlePaste` formatting and multi-line dialog, with
its `_isPasting` guard). Web pane gets the same helper so the bar
stays uniform; its existing browser-textarea paste is untouched and
remains as a second path. Key placed after `enter`, inside the
action cluster.

Validation: extend `terminal_accessory_bar_test.dart` (paste reports
through `onPaste`, never through `onSend`), run it plus `flutter
analyze` and the client suite with the local SDK.

## Plan

1. Add `onPaste` + `paste` key to `TerminalAccessoryBar`.
2. Wire native stub pane (`onPaste` → `_pasteFromClipboard`).
3. Add web pane `_pasteFromClipboard` and wire it.
4. Extend accessory-bar widget tests; run focused tests, analyze, full
   client suite.
5. Update devlog, commit, push with explicit refspec, open PR.
