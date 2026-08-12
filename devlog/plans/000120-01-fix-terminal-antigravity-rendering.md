## Thinking

### Problem Statement
The user reported that the terminal in Triage does not render properly when using `antigravity` (`agy` CLI).
From the screenshot provided (`Screenshot 2026-08-11 at 9.47.49 PM.png`), when typing input at the `agy` prompt in the web client (`localhost:7777`), text becomes mangled, scrambled, and overwritten (e.g., `the terminal...` renders as `hetterminal...` and `@~/Desktop/Screenshot...` renders as `@ e ~kt s op/`).

### Root Cause Analysis
1. `agy` and modern CLI tools (using `unicode-width` crate in Rust, Node, or Go) calculate character display widths based on **Unicode 11+ / Unicode 15** rules. Emojis, regional indicators, block art, symbols, package/crab symbols (`📦`, `🦀`, `🅶`, `🅺`, `❯`) take 2 columns (or 1 column according to Unicode 11+ tables).
2. The native Flutter client (`terminal_pane_stub.dart`) uses `xterm.dart`, which uses `unicodeV11.wcwidth()`.
3. The daemon (`triaged`) uses `wezterm-term`, which uses Unicode 14/15 width tables.
4. The TUI client (`triage`) uses `unicode-width` crate (Unicode 15).
5. **HOWEVER**, the Flutter Web client (`terminal_pane_web.dart`) uses `xterm.js`. `xterm.js` defaults to `UnicodeV6` (Unicode 6 from 2010) unless `@xterm/addon-unicode11` is loaded and `unicodeVersion = '11'` is activated on the terminal instance.
6. Under `UnicodeV6`, `xterm.js` calculates many modern emojis, symbols, and block characters as width 1 instead of width 2 (or vice versa). When `agy` moves the cursor left or right via ANSI escape sequences (e.g. `\x1b[ND`) to redraw the line/prompt, the cursor lands at the wrong column index in `xterm.js`. Subsequent character writes overwrite preceding characters at offset positions, causing severe text scrambling.

### Solution Plan
1. Bundle `@xterm/addon-unicode11` (`xterm-addon-unicode11.js`) into `flutter/triage_client/web/` and `crates/triaged/dist/` (and ensure `pubspec.yaml` assets/dist scripts package it).
2. Update `flutter/triage_client/web/index.html` to load `<script src="xterm-addon-unicode11.js"></script>`.
3. Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to:
   - Register and load `Unicode11Addon` on the `xterm.js` terminal instance.
   - Set `unicodeVersion = '11'` on the terminal options and `term.unicode.activeVersion = '11'`.
4. Validate that building web/flutter client works, and test terminal rendering behaviour.

## Plan

1. Copy `@xterm/addon-unicode11` (v0.9.0 UMD bundle) to `flutter/triage_client/web/xterm-addon-unicode11.js`.
2. Update `flutter/triage_client/web/index.html` to include `<script src="xterm-addon-unicode11.js"></script>`.
3. Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart` to instantiate `Unicode11Addon`, load it via `_term.loadAddon(...)`, and set `unicodeVersion` / `activeVersion` to `'11'`.
4. Run Flutter build / checks / tests to ensure clean compilation and test execution.
5. Create branch devlog (`devlog/000120-fix-terminal-antigravity-rendering.md`), commit changes following Conventional Commits, and update PR status.
