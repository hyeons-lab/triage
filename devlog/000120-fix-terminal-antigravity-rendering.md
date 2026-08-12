# 000120 — fix/terminal-antigravity-rendering

**Agent:** Antigravity (Gemini 3.6 Flash) @ triage branch fix/terminal-antigravity-rendering

## Intent

Fix terminal rendering corruption when using `antigravity` (`agy` CLI) in the Triage web client, where prompt redrawing, emojis, block art, and wide characters cause text overwriting and scrambled prompt output.

## Research & Discoveries

- 2026-08-11T21:54-0700 — Inspected screenshot and traced terminal emulator character width calculations:
  - `agy` and modern CLI interactive tools rely on Unicode 11+ / Unicode 15 width tables for emojis, block characters, and symbols (`📦`, `🦀`, `🅶`, `🅺`, `❯`).
  - Native Flutter client (`terminal_pane_stub.dart`) uses `xterm.dart`, which uses `unicodeV11.wcwidth()`.
  - Daemon (`triaged`) uses `wezterm-term` with Unicode 14/15 width tables.
  - TUI client (`triage`) uses `unicode-width` crate (Unicode 15).
  - Web client (`terminal_pane_web.dart`) uses `xterm.js`. `xterm.js` defaults to `UnicodeV6` (Unicode 6 from 2010), causing cell width mismatches between the CLI and `xterm.js`.
  - When `agy` issues ANSI cursor back (`\x1b[ND`) or line redraws, the cursor position in `xterm.js` is offset due to Unicode 6 cell widths, leading to severe text scrambling.

## Decisions

- 2026-08-11T21:54-0700 — Bundle `@xterm/addon-unicode11` (`xterm-addon-unicode11.js`) in `flutter/triage_client/web/`, include it in `index.html`, and activate `Unicode11Addon` on `xterm.js` in `terminal_pane_web.dart` with `unicodeVersion = '11'`.

## What Changed

- 2026-08-11T21:54-0700 `flutter/triage_client/web/xterm-addon-unicode11.js` — Added bundled `@xterm/addon-unicode11` (v0.9.0 UMD bundle).
- 2026-08-11T21:54-0700 `flutter/triage_client/web/index.html` — Loaded `<script src="xterm-addon-unicode11.js"></script>`.
- 2026-08-11T22:13-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart` — Fixed premature `unicodeVersion: '11'` setting in initial `options` bag (which threw on `Terminal` construction before `Unicode11Addon` registration) and set it cleanly after `loadAddon`.

## Commits

- 7903bac — fix(triage_client): activate unicode11 addon for xterm.js to fix agy terminal rendering
- HEAD — fix(triage_client): fix unicodeVersion initialization timing in xterm.js

## Progress

- Initialized worktree, plan file, and devlog.
- Resolved high-effort review finding on `unicodeVersion` initialization sequence.
