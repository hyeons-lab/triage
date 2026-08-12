# Fix Unicode 11 Activation in xterm.js Web Client

- **Agent:** Antigravity
- **Intent:** Fix xterm.js `allowProposedApi` option requirement and `term.unicode.activeVersion` property assignment so `Unicode11Addon` successfully activates version 11 cell widths instead of remaining on Unicode version 6.

## What Changed

- 2026-08-11T23:49-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart` — Set `allowProposedApi: true` in `Terminal` options and updated active Unicode version setting to `js_util.setProperty(unicode, 'activeVersion', '11')` on `_term.unicode`.
- 2026-08-12T00:43-0700 `AGENTS.md` — Documented strict Zero-Downtime Daemon Handover Protocol (prohibiting `launchctl kickstart -k` / SIGKILL and enforcing direct `triaged --handover` with log verification).

## Commits

- c08626a — fix(triage_client): enable allowProposedApi and set unicode activeVersion 11 in xterm.js
- HEAD — docs(agents): add zero-downtime daemon handover protocol rules

## Progress

- Identified root cause of xterm.js Unicode 11 activation failure (`term.unicode` throws without `allowProposedApi: true`).
- Initialized worktree, plan, and devlog.
- Added explicit handover protocol rules to `AGENTS.md`.
