# 000056 — fix/terminal-layout-collapse

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/terminal-layout-collapse

## Intent

The macOS Flutter client (Triage.app) renders Claude Code's TUI with **collapsed
spaces** — e.g. `Claude Code v2.1.162` → `ClaudeCodev2.1.162`,
`⏵⏵ auto mode on …` → `⏵⏵automodeon…`. Toggling the side rail **duplicates** the
text ("makes a copy"), and some wrapped rows lose their **first character**
(`Grep/Glob` → `rep/Glob`). Text is correct when copied/pasted.

## Research & Discoveries

Ruled out by reading the code (so we don't chase them again):

- **Host capture preserves spaces.** `styled_visible_rows_for_range`
  (crates/triaged/src/session.rs:2854-2891) emits a span per cell run, including
  blank cells (`cell.str()` → `" "`). The host is not dropping spaces.
- **xterm.dart wcwidth == 1** for every mode-line glyph (`· ← ⏵ ●`) — ran
  `unicodeV11.wcwidth` directly. Emoji `📦 🦀` (>U+FFFF) are width 2 on both the
  host (`unicode-width` crate) and xterm, so they align — which is why the
  starship status line looks fine but the mode line doesn't.
- **xterm.dart paints strictly per-cell** at `i * cellWidth`
  (xterm-4.0.0 painter.dart:154); font advance can't shift columns in the buffer.
- **Live output is raw PTY bytes**, not StyledRows: main.dart:177-204 UTF-8
  decodes host bytes and calls `terminal.write(data)`. StyledRow reconstruction
  (`styledRowToAnsi`/`clipRowToCols`) is only the replay/restore path, which the
  side-rail resize re-triggers (`_triggerFullReplayOrReset`).

Since `ClaudeCodev2.1.162` is pure ASCII + block glyphs (all width 1, universally
agreed) yet still collapses, the remaining hypotheses are **paint/layout layer**
only, and only reproduce in the real macOS font runtime:
1. measured cell width < rendered glyph advance → per-cell paint overlaps and
   visually eats spaces;
2. a duplicate render on relayout (matches "makes a copy" + first-char clipping).

## What Changed

2026-06-03T18:40-0700 `flutter/triage_client/lib/widgets/terminal_pane_stub.dart`
— **TEMPORARY debug instrumentation** (to be removed before merge):
`_logLayoutDiagnostics()` logs the real-runtime cell width (`mmmmmmmmmm`/10) vs.
individual glyph advances (m/i/a/space/⏵/·/←/●/📦) plus the `TextScaler` and
device pixel ratio; `[LAYOUTDBG]` traces in `_onTerminalResize`,
`_triggerFullReplayOrReset`, `_resetTerminalSafe`, `_writeInitialContent` to catch
duplicate replays on a single side-rail toggle.

## Decisions

2026-06-03T18:40-0700 Reproduce via instrumentation + a real macOS run (user's
choice) rather than a headless test — the bug is paint-layer and won't show in a
headless buffer dump (the cell buffer is correct, which is why paste is clean).

2026-06-03T18:40-0700 Held the push — local debug only, no CI needed until a real
fix exists.

## Commits

HEAD — debug(client): instrument terminal pane layout/metrics for the space-collapse bug

## Next Steps

- User runs `flutter run -d macos` from this worktree, reproduces (toggle side
  rail on a session showing Claude), and pastes the `[LAYOUTDBG]` lines.
- Interpret: if `cell` < ASCII advances (m/a/0) → paint overlap; if a single
  toggle logs multiple `writeInitialContent`/`resetTerminalSafe` → duplicate
  render. Then implement the fix and strip the instrumentation.
