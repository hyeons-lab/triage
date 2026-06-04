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

2026-06-03T21:05-0700 `flutter/triage_client/lib/terminal/{terminal_intent,
terminal_state,terminal_sink,terminal_store}.dart` + `test/terminal/
terminal_store_test.dart` — **Part A, migration step 1: the MVI seam** (unwired;
app unchanged). `TerminalIntent` (sealed: LiveBytes/HistoryBytes/Resize/
UserInput/Attach/Detach/Exited/Clear), immutable `TerminalState` (control state
only; xterm owns the grid), the tiny `TerminalSink` emulator interface, and
`TerminalStore extends ChangeNotifier` — the single reducer that applies intents
in arrival order through one write path, owning the only UTF-8 carry, the only
CRLF-normalization (bare LF→CRLF with a trailing-CR carry so split CRLF isn't
doubled), the only pre-size/await-history live buffer, and `output_seq`
de-duplication. 12 reducer tests via a `FakeTerminalSink` (ordered op-log, no
Flutter binding) cover buffering-before-size, history-before-live, outputSeq
de-dupe (live + queued), resize-emits-no-replay/clear + distinct-size forwarding,
sub-min ignore, split-UTF-8, CRLF normalization + split, input forward/suppress,
sink echo routing, detached-ignore. `flutter analyze` clean.

## Decisions

2026-06-03T18:40-0700 Reproduce via instrumentation + a real macOS run (user's
choice) rather than a headless test — the bug is paint-layer and won't show in a
headless buffer dump (the cell buffer is correct, which is why paste is clean).

2026-06-03T18:40-0700 Held the push — local debug only, no CI needed until a real
fix exists.

## Root Cause (CONFIRMED via instrumented macOS run)

The `[LAYOUTDBG]` metrics refuted the paint/width theory: `scaler=(no scaling)
dpr=2.0 cell=9.031` and every ASCII glyph advance == 9.031 == cell. No overlap,
no scaling — **not a font/width bug.**

The real bug: the terminal is **fully torn down and rebuilt from a host history
snapshot on every size change.** A single sidebar toggle emits a *storm* of size
changes (logged: `cols 60→63→…→77→…→43`). For each, the host pushes a `Snapshot`;
the client sees `sizeChanged` and applies it with history (main.dart Snapshot
handler + the resize path at ~715), which bumps `replayRevision` →
`_triggerFullReplayOrReset` → `resetTerminalSafe` + `writeInitialContent`,
re-inserting the entire growing scrollback (`fallbackRows 119→125→188`) at each
intermediate wrap width. These rebuilds race the live stream and each other,
producing duplicated lines ("copies get inserted") and shredded fragments that
read as collapsed spaces. The logs also showed `writeInitialContent` running
twice while `initWritten=false` (a re-entrancy race) at startup.

## Fix (parent-level coalescing — user's chosen approach)

`_applySnapshotToSession` gains a `coalesceReplay` flag. Resize-driven snapshots
(`Snapshot` with `sizeChanged`, both call sites) still update `session.rows`
immediately but **debounce** the `replayRevision` bump behind a per-session
150 ms `replayCoalesceTimer` — so a resize storm collapses into ONE rebuild at
the final settled size. Attach / resync / session-select keep the immediate bump
and cancel any pending coalesced replay so we never rebuild twice. Timer is
cancelled on session removal and in the State `dispose`.

## Phase 0 — De-risking spike (MVI refactor gate) — PASSED, 2026-06-03T20:52-0700

Threw away four `flutter test` spikes that replay real session logs
(`~/.local/state/triage/sessions/session-N.log`) into a fresh `package:xterm`
`Terminal` (no app wiring). Results gate and over-deliver on the refactor.

**Root cause PINPOINTED (reproduced in isolation).** The raw bytes for Claude's
banner are `…╭───\x1b[6GClaude\x1b[13GCode…` — Claude positions text with
**absolute column moves** (`\x1b[NG`, CHA), so the space between "Claude" and
"Code" is **a cursor jump over column 12, not a literal `0x20` byte**. Probing
the xterm.dart buffer after writing exactly `\x1b[6GClaude\x1b[13GCode`:
`getCodePoint(11) == 0` (empty), **not** `0x20` (space). Two consequences:
- `BufferLine.getText()` **drops codepoint-0 cells** → `getText()` returns
  `ClaudeCode` (collapsed) and also eats the leading indent. Any grid→text
  stringification that works this way collapses every cursor-positioned gap.
- The **painter** (`painter.dart:150` `paintLine`) renders each cell at a fixed
  `i * cellWidth` and only skips drawing a glyph for codepoint 0
  (`paintCellForeground`: `if (charCode == 0) return;`). The empty cell **keeps
  its column**, so the *live raw-byte path displays `Claude Code` correctly* —
  the gap is preserved on screen.

So the on-screen collapse is **not** the live path. It is the **StyledRow
replay/reconstruction path** (host grid stringify → `styledRowToAnsi` →
re-parse), which loses the empty-vs-space distinction exactly like `getText()`,
then overwrites the (correct) live banner on attach and on every resize/sidebar
toggle. The static banner scrolls into history and is never live-repainted, so
the collapse persists. **This is precisely the path the MVI refactor deletes** —
making raw bytes the single source removes the corrupting stringification.

**Two independent phenomena, both fixed by raw-byte single source:**
1. *Collapsed inter-word spaces* — StyledRow stringify dropping codepoint-0 gap
   cells (above). Width-independent.
2. *Fragmentation / wrapped rows / "copies"* — replaying history at the **wrong
   column width**. At 80 cols a 97-col-captured frame wraps every full-width
   line; at width ≥97 the wrapping is clean. Fix: replay history at the
   host-reported width, then resize → live repaint self-heals.

**`raw_output` contract decided (Part B):** a **bounded raw tail**, not the full
log. Claude Code (a) **never enters the alternate screen** (`?1049h` count = 0 in
the real Claude log session-10; the lone `?1049h` in session-8 was a ~2 KB pager
episode) and (b) emits a **complete frame every render** (`\x1b[?2026h`/`l`
synchronized-output pairs, ~1.4 KB/frame), so any tail containing ≥1 full frame
self-heals the entire viewport. Empirically a **64 KiB tail matched full replay
exactly**; 16 KiB was a hair short. Decision: send a coherent-anchored tail
(snap start to the last `?1049h`/`\x1b[2J`/RIS when present, else a raw tail)
capped at ~256 KiB–1 MiB, aligned to live via `output_seq`. This kills the
"alt-screen enter falls outside the tail" headline risk — it does not apply to
Claude. (`reflow_from_log` already proves full replay is correct server-side; the
spike confirms xterm.dart full + tail fidelity client-side.)

**Performance:** full 7.5 MB log → single `Terminal.write` ≈ 236 ms; the 34 KB
coherent-anchored tail ≈ 1.8 ms. Bounded tails are ~100× cheaper and identical.

**Chunking is safe:** 64 KiB and even 1 KiB chunked writes (streaming UTF-8
decode across boundaries) produce byte-identical buffers to a single write —
validates the sink's planned 64 KiB chunking. Caveat: replaying the pathological
7.5 MB session-8 tripped an xterm.dart internal
`circular_buffer.dart:312 'attached'` assertion during a massive scroll; bounded
tails avoid it, but file an upstream note.

**New open item surfaced (copy/paste):** because selection/copy uses
`getText()`, which drops codepoint-0 gap cells, removing the space-filled
StyledRow source could regress copy to `ClaudeCode`. Verify on the macOS e2e run;
if it regresses, fill cursor-skipped cells with `0x20` in the sink or treat
interior empty cells as spaces on copy. (Today's clean paste likely reads
space-filled StyledRows.)

## Decision

2026-06-03T20:52-0700 Phase 0 PASSED → proceed with the MVI raw-byte refactor.
`raw_output` = coherent-anchored bounded tail (~256 KiB–1 MiB) aligned by
`output_seq`; client re-emulates raw bytes at the host-reported width and deletes
the StyledRow render/replay path. Spike files were throwaway and removed.

## Commits

HEAD — feat(client): add unidirectional MVI terminal seam (intent/state/sink/store)
b80318a — fix(client): coalesce resize-driven terminal replays to stop duplicated/fragmented text
b16aa05 — debug(client): instrument terminal pane layout/metrics for the space-collapse bug

## Next Steps

- Copy the approved plan to `devlog/plans/000056-02-mvi-terminal-pipeline.md`.
- Part A migration step 1: land the client `lib/terminal/*` MVI seam
  (`TerminalIntent`/`TerminalState`/`TerminalSink`/`TerminalStore` +
  `FakeTerminalSink` reducer tests), not yet wired.
- Part B: add `raw_output`/`raw_output_start` (coherent-anchored tail) to
  `SessionSnapshot` + serde + tail reader; populate on attach/resync.
- Strip `[LAYOUTDBG]` instrumentation as the StyledRow path is removed.
