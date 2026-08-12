# Fix Unicode 11 Activation in xterm.js Web Client

- **Agent:** Antigravity
- **Intent:** Fix xterm.js `allowProposedApi` option requirement and `term.unicode.activeVersion` property assignment so `Unicode11Addon` successfully activates version 11 cell widths instead of remaining on Unicode version 6.

## What Changed

- 2026-08-11T23:49-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart` — Set `allowProposedApi: true` in `Terminal` options and updated active Unicode version setting to `js_util.setProperty(unicode, 'activeVersion', '11')` on `_term.unicode`.

## Commits

- HEAD — fix(triage_client): set allowProposedApi and activate unicode version 11 on xterm.js

## Progress

- Identified root cause of xterm.js Unicode 11 activation failure (`term.unicode` throws without `allowProposedApi: true`).
- Initialized worktree, plan, and devlog.
