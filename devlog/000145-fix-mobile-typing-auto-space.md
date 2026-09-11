# 000145: fix/mobile-typing-auto-space

**Agent:** Antigravity (Gemini 3.8 Flash) @ triage branch fix/mobile-typing-auto-space

## Intent

Auto-insert spaces between words during mobile typing, eliminate terminal resize layout clipping, character misplacement, and cursor drift in xterm.dart and client panes, prevent sessions from snapping to top on resize or re-entry, and upgrade cera to 0.5.6.

## What Changed

- `2026-09-10T21:51-0400 devlog/plans/000145-01-mobile-typing-auto-space.md`: Authored implementation plan covering mobile auto-spacing, buffer resize preservation, stick-to-bottom layout race fix, and cera upgrade.
- `2026-09-10T21:55-0400 flutter/triage_client/lib/terminal/mobile_auto_space.dart`: Implemented MobileAutoSpaceTracker to manage word boundaries and auto-insert spaces between mobile word chunks.
- `2026-09-10T21:57-0400 flutter/triage_client/test/terminal/mobile_auto_space_test.dart`: Added comprehensive unit tests for mobile auto-space tracking.
- `2026-09-10T22:00-0400 flutter/triage_client/lib/widgets/terminal_pane_web.dart`: Integrated MobileAutoSpaceTracker into mobile web input pipeline and wired reset triggers.
- `2026-09-10T22:02-0400 flutter/triage_client/lib/widgets/terminal_pane_stub.dart`: Integrated MobileAutoSpaceTracker into native mobile input, ensured stick-to-bottom on terminal resize, and suppressed anchor capture during programmatic scroll-to-cursor.
- `2026-09-10T22:05-0400 flutter/triage_client/lib/terminal/terminal_scroll_anchor.dart`: Cleared scroll anchor when viewport is within release grace margin of the bottom to prevent accidental bottom pinning.
- `2026-09-10T22:08-0400 flutter/triage_client/pubspec.yaml`: Updated xterm dependency override to commit f43cd66be3d6070be08a95c693502e53d4a4eee7 containing Buffer.resize and RenderTerminal fixes.
- `2026-09-10T22:12-0400 Cargo.toml, Cargo.lock`: Upgraded cera dependency to 0.5.6.
- `2026-09-10T22:14-0400 crates/triaged/src/summarizer.rs`: Configured gpu_depthformer: false for cera EngineConfig.
- `2026-09-11T00:05-0400 flutter/triage_client/pubspec.yaml, pubspec.lock`: Updated xterm dependency override to commit 7cb984f87ffa583d878858217717d48326b7c3d8 containing DEC Mode 2026 synchronized output and OS IME caret rect suppression.
- `2026-09-11T00:05-0400 flutter/triage_client/lib/widgets/terminal_pane_stub.dart`: Preserved session scroll position and relative distance from bottom across session switches, preventing abrupt jumps or snapping to the top.

## Decisions

- 2026-09-10T21:51-0400 Create dedicated MobileAutoSpaceTracker in lib/terminal/mobile_auto_space.dart: Encapsulates state machine for mobile text chunks, tracking word boundaries and auto-inserting spaces between consecutive word chunks without affecting desktop hardware keyboards.
- 2026-09-10T21:51-0400 Reset tracker on terminal host write, user pointer interaction, and control codes: Ensures shell prompts and command completions start fresh without unwanted leading spaces.
- 2026-09-10T22:04-0400 Eliminate lines.pop() on content lines in Buffer.resize (xterm.dart): Preserves prompt composers and screen rows below cursor during height reduction, only trimming trailing blank lines.
- 2026-09-10T22:06-0400 Anchor cursor during width reflow in Buffer.resize (xterm.dart): Attaches a CellAnchor to cursor before reflow so cursor moves to the exact reflowed character position.
- 2026-09-10T22:07-0400 Guard RenderTerminal layout in render.dart (xterm.dart): Sets _isPerformingLayout flag during performLayout so applyContentDimensions does not prematurely drop _stickToBottom before correctBy adjusts scroll offset.
- 2026-09-11T00:05-0400 Implement DEC Mode 2026 (Synchronized Output) in xterm.dart: Buffers terminal listener notifications during synchronized batches emitted by CLI tools like Antigravity, and suppresses erratic cursor rect notifications to OS IME while the pen is moving or hidden.
- 2026-09-11T00:05-0400 Retain distance from bottom and capture anchor on session save: Guarantees that returning to a session accurately restores the visible text or relative position from bottom rather than jumping to line 0 or raw stale offsets.

## Issues

- 2026-09-10T22:15-0400 Disk space exhausted during Cargo workspace build: The build failed with errno=28 (No space left on device) due to accumulated debug artifacts in an unused worktree target directory. Resolved by removing the stale target directory, reclaiming 7.1GB.
- 2026-09-10T22:17-0400 triaged build script failed finding flutter on PATH: `crates/triaged/build.rs` requires Flutter to compile the embedded web bundle. Resolved by explicitly including the Flutter SDK in PATH during Cargo builds.

## Commits

- a0c3217: fix(client): auto-space words on mobile, fix terminal resize clipping and cursor drift, update cera to 0.5.6
- HEAD: fix(client): support Mode 2026 synchronized output and persist session scroll position
