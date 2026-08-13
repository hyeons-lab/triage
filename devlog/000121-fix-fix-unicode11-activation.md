# 000121 — fix/fix-unicode11-activation

**Agent:** Antigravity @ triage branch fix/fix-unicode11-activation

## Intent

Fix xterm.js `allowProposedApi` option requirement and `term.unicode.activeVersion` property assignment so `Unicode11Addon` successfully activates version 11 cell widths instead of remaining on Unicode version 6.

## What Changed

- 2026-08-11T23:49-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart` — Set `allowProposedApi: true` in `Terminal` options and updated active Unicode version setting to `js_util.setProperty(unicode, 'activeVersion', '11')` on `_term.unicode`.
- 2026-08-12T00:43-0700 `AGENTS.md` — Documented strict Zero-Downtime Daemon Handover Protocol (prohibiting `launchctl kickstart -k` / SIGKILL and enforcing direct `triaged --handover` with log verification).
- 2026-08-12T00:52-0700 `devlog/000121-fix-fix-unicode11-activation.md` & `devlog/plans/000121-01-fix-fix-unicode11-activation.md` — Renamed devlog and plan files to sequence `000121` matching branch name and avoiding sequence gap.
- 2026-08-12T00:54-0700 `devlog/000121-fix-fix-unicode11-activation.md` & `devlog/plans/000121-01-fix-fix-unicode11-activation.md` — Formatted plan and devlog sections to match standard AGENTS.md devlog conventions.

## Commits

- c08626a — fix(triage_client): enable allowProposedApi and set unicode activeVersion 11 in xterm.js
- 1dabf2c — docs(agents): add zero-downtime daemon handover protocol rules
- 025b462 — style(devlog): rename devlog and plan files to match sequence 000121
- HEAD — style(devlog): format devlog and plan headers per AGENTS.md conventions

## Progress

- Identified root cause of xterm.js Unicode 11 activation failure (`term.unicode` throws without `allowProposedApi: true`).
- Initialized worktree, plan, and devlog.
- Added explicit handover protocol rules to `AGENTS.md`.
- Corrected devlog and plan sequence numbers to `000121`.
- Addressed PR review comments on devlog and plan header sectioning.
