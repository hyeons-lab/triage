# 000153 fix/mobile-terminal-paste

## Agent

Muse Code, 2026-09-20T13:30-0700.

## Intent

Pasting into the terminal is impossible on a mobile soft keyboard: the
system long-press menu never appears and triage offers no paste
affordance of its own. Add a `paste` key to the shared mobile accessory
bar, wired to the clipboard-paste path in both terminal panes.

## What Changed

- `TerminalAccessoryBar` gains a required `onPaste` callback and a
  `paste` key (after `enter`).
- Native pane passes its existing `_pasteFromClipboard` (clipboard read
  plus bracketed-paste formatting and the multi-line dialog).
- Web pane gains the same `_pasteFromClipboard` helper and wiring, so
  the touch bar stays identical on both clients.
- Accessory-bar widget tests cover the new key.

## Decisions

- Accessory-bar key instead of a long-press menu: the bar is always
  visible while typing, needs no new gesture or overlay timing, and one
  widget serves native and mobile web. The xterm fork's `showToolbar`
  no-op (which suppresses the system edit menu) is left alone.
- Required `onPaste` on both panes rather than a nullable key: the bar
  exists precisely so the two clients cannot drift, and on mobile web
  the key is additive (browser textarea paste keeps working if the
  clipboard read fails).
- Devlog number 000153: main's highest is 000151, but 000152 is already
  taken by two in-flight branches (`feat/agent-session-restore`,
  `fix/judge-var-indirection`).

## Issues

- Copilot review on PR #178: the web `_pasteFromClipboard` comment said a
  denied clipboard read "just no-ops" while the catch block logs via
  `debugPrint`. Fixed by rewording the comment to say the read only logs
  in debug builds; the log stays, matching the native pane and the
  Antigravity review's read of the same code.
- Antigravity suggestion (declined): remove the outer `clearSelection()`
  in the native `_pasteFromClipboard` as redundant. Declined because the
  line predates the PR and is not purely redundant: `_handlePaste` clears
  only on paths that send text, so the outer call is the sole clear when
  the multi-line dialog is cancelled or already showing. Removing it
  would change cancel-path behavior.

## Commits

- aaf6aee — fix(terminal): add paste key to the mobile accessory bar
- HEAD — fix(terminal): align web paste comment with debug logging

## Progress

- [x] Worktree and branch created from origin/main
- [x] Branch devlog and plan file created
- [x] Accessory-bar paste key + pane wiring
- [x] Widget tests, analyze, full client test suite (529 green),
  `flutter build web --release` green
- [x] Commit, push, PR (#178)
- [x] PR review responses: Copilot comment/log mismatch fixed,
  Antigravity redundancy suggestion declined with rationale

## Research & Discoveries

- Mobile paste paths today: hardware keyboard chord
  (`_isPasteChord` → `_pasteFromClipboard`) and Android IME
  clipboard-chip commits (multi-char `onOutput` chunks). iOS soft
  keyboard has neither: no chips, no edit menu, no key.
- `CustomTextEdit.showToolbar` in the xterm fork is a no-op, so the OS
  never shows Cut/Copy/Paste for the hidden input connection; triage's
  own long-press drives selection plus a Copy-only floating button.

## Lessons Learned

## Next Steps

Implement, validate with the Flutter SDK, commit, push, open PR.
