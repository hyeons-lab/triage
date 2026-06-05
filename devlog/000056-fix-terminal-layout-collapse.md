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

2026-06-03T21:35-0700 **Part B, migration step 2: host streams a raw-output
history tail.** `crates/triage-core/schema/triage.fbs` — appended `raw_output:
[ubyte]` + `raw_output_start: uint64` to `SessionSnapshot` (append-only; old
hosts/clients interop). Regenerated Dart bindings (`flatc --dart
--gen-object-api` + `dart format`) in `flutter/triage_client/lib/generated/`.
`crates/triage-core/src/session.rs` — two new struct fields (`#[serde(default)]`).
`crates/triage-core/src/flatbuffers_proto.rs` — `build_session_snapshot`
serializes them (vector omitted when empty so old clients see an absent field);
+2 round-trip tests. `crates/triaged/src/session.rs` — `read_raw_output_tail`
(reads the last `RAW_OUTPUT_TAIL_CAP = 1 MiB` of the unbuffered log, returns
`(start, bytes)`), `SessionActor::snapshot_with_history` +
`HistoricalSession::snapshot_with_history` (overlay the tail), wired into the
attach/explicit-snapshot command handler, `resync_envelope`, and both Historical
attach/snapshot sites — **but not the resize broadcast** (`snapshot()` stays
history-free so resizes never carry 1 MiB). +1 boundary test. Filled the two new
fields (`Vec::new()`/`0`) in all 16 other `SessionSnapshot {}` literals (triage
TUI/lib, mcp, transport-ws lib + benches). `triage_websocket_client.dart`
`_parseSessionSnapshot` exposes `raw_output`/`raw_output_start`. All Rust tests
green (triage-core 18, triaged 81, transport-ws 16, triage 25, mcp 41); workspace
`--all-targets` builds clean.

2026-06-03T22:04-0700 **Wiring (migration steps 3-6): client renders through the
store; StyledRow replay deleted.** The `TerminalController` is already the shared
write seam (native: SessionVm's listener -> `xterm.dart` `Terminal`; web: the web
pane's listener -> xterm.js), so one `lib/terminal/terminal_controller_sink.dart`
serves both platforms (resize is a no-op — the views own auto-fit). `main.dart`
`SessionVm` now owns a `TerminalStore` over that sink and exposes `applyHistory`
/`applyLiveBytes`/`echoLocalBytes`/`markExited`; all the old output machinery
(`writeOutput`/`decodeOutputBytes`/`_writeTerminalOrBuffer`/
`markInitialContentWritten`/`flushPendingTerminalWritesAfterReplay`/`markReplaySnapshotOutputSeq`/
`setSnapshotRefreshPending`/`replayRevision`/`replayCoalesceTimer`/UTF-8 carry/
`_PendingTerminalWrite`) is removed. Event loop: `Output`->`applyLiveBytes`,
attach/resync/select/new-session/refresh->`Attach`+`HistoryBytes(raw_output, size,
output_seq)`, `Exited`->`markExited`, and the resize **Snapshot broadcast is
ignored** (raw clients re-render from the live stream). Resize-out just tells the
host the new size (no replay). Native pane (`terminal_pane_stub.dart`) rewritten
as a thin view (TerminalView + focus/scroll + input + debounced resize-out) — all
replay/reset/suppression/`[LAYOUTDBG]` gone. Web pane: `_writeInitialContent` now
re-emulates `historyRawOutput` bytes (UTF-8 + CRLF) instead of styled rows;
replay-revision/cursor/pending props removed. Deleted `terminal_replay.dart`,
`SessionVm.rows`-as-render-source (kept only as a plain mirror for the
FLUTTER_TEST fallback, fed by `_plainRowsFromSnapshot`), `_mergeVisibleAndStyledRows`,
and `cursor_position_test.dart`. Local/demo sessions seed + echo through the
store too (one pipeline). Regenerated Dart bindings already carry
`rawOutput`/`rawOutputStart` (Part B). `flutter analyze` clean (0 errors); 59
Flutter tests pass (incl. the 12-case reducer suite); 4 obsolete SessionVm-buffering
widget tests removed (re-homed to `terminal_store_test.dart`). Rust workspace builds.

## Decisions

2026-06-03T21:35-0700 `raw_output` carried only on attach/resync/explicit-snapshot
(not resize broadcasts) — reasoning: the in-actor `snapshot()` feeds the frequent
resize `SnapshotEvent`; loading a 1 MiB tail there would bloat every resize to
every subscriber. A dedicated `snapshot_with_history()` overlays the tail only on
the history-bearing paths.

2026-06-03T21:35-0700 `RAW_OUTPUT_TAIL_CAP = 1 MiB` (plan suggested 4 MiB) —
reasoning: the Phase 0 spike showed a 64 KiB tail of a real Claude log
reconstructs identically to the full 7.5 MB replay (Claude repaints a full frame
every render, so any tail with ≥1 frame self-heals). 1 MiB is ~16× headroom for
full-screen TUIs (vim/less) run inside a session while keeping attach payloads
small over remote links. Plain bounded tail (no anchor-trimming) — the spike
proved it sufficient for the real workload; anchor-snap noted as a future option.

2026-06-03T21:35-0700 History and live are byte-identical: live `Output{bytes}`
broadcasts the same RAW (untranslated) bytes as the log
(`session.rs:1820`), and `raw_output` is the raw log tail ending at
`bytes_logged` (== `output_seq` S). The client drops live `Output` with
`output_seq <= S` — exact, gapless de-dup. CRLF normalization happens once in the
client store for both streams.

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

## Issues

2026-06-04T00:00-0700 **e2e: blank on first show / select, content appears only
after a window resize.** Root cause: the wiring dispatched `HistoryBytes` at
attach time — *before* the `TerminalView` had laid out and auto-fitted — so the
history replayed at the default 80x24 into a viewport that didn't match the real
size, showing nothing until a resize refit surfaced it. The original (working)
code wrote initial content on the first fit for exactly this reason. Fix:
**defer the history replay to the view's first fit.** `applyHistory` now only
dispatches `Attach` (so live chunks buffer in the store in arrival order) and
stages the raw tail; the pane reports its fitted size via a new `onViewFit`
callback → `SessionVm.noteViewFit` → `HistoryBytes` replays at the real size and
the store flushes the buffered live. Both panes call `onViewFit` on fit; the web
pane's separate `historyRawOutput` mount-replay was removed (the store now drives
history through the controller for both platforms). This mirrors the old
first-fit timing while keeping the single store write path.

2026-06-04T00:30-0700 First defer attempt still blank — and surfaced the true
cause via a thrown assertion: *"A RenderTerminal was mutated in its own
performLayout."* The native `TerminalView` auto-fits by calling `terminal.resize`
**inside** `RenderTerminal.performLayout`, which fires `onResize` → `onViewFit` →
`HistoryBytes` → `terminal.write` → `markNeedsLayout` while the render object is
still laying out (illegal; the write is dropped, hence blank until a later
out-of-layout resize). Fix: the native pane defers the `onViewFit` call to a
`scheduleMicrotask` so the history/live write lands after layout completes (the
terminal is already at the fitted size by then) — the same microtask trick the
pre-refactor `_finishInitialContent` used. Web is unaffected (xterm.js is not a
Flutter render object). `flutter analyze` clean; 59 tests pass.

2026-06-04T20:10-0700 **e2e (live session): text/spacing correct (paste clean —
buffer is fixed), but horizontal lines/box-borders render wrong everywhere.**
Diagnosed headlessly by replaying the live session log
(`~/.local/state/triage/sessions/session-14.log`) into a bare `package:xterm`
`Terminal` and dumping per-cell attributes: **every cell had the underline flag
set** (`getAttributes(i) & 1<<3`), including untouched/erased cells — so the pen
underline was stuck on and bled into every write and `\x1b[K` erase. The log
contains **no SGR 4** at all. Bisecting the byte stream, underline first appears
at the sequence `\x1b[>4;2m` — `CSI > 4 ; 2 m` = **XTMODKEYS / modifyOtherKeys**
(a keyboard-protocol negotiation Claude emits once at startup). xterm.dart
**ignores the `>` private marker and parses it as plain SGR `4;2` → underline +
faint**, permanently. Verified: stripping `\x1b[>…m` drops underlined cells from
97/row to 0. Fix: `TerminalStore._stripUnsupportedPrivateCsi` removes
`CSI > … m` private sequences in the single write path before they reach the
emulator (it doesn't support modifyOtherKeys anyway), with a bounded carry so a
sequence split across live chunks is still caught. +2 reducer tests; 61 pass.
(Separately confirmed the painter preserves cursor-positioned gaps — the banner's
`\x1b[12G…\x1b[19G…` absolute-column layout renders with correct spacing.)

2026-06-04T20:15-0700 `flutter/triage_client/fonts/JetBrainsMono-*.ttf` (+
`OFL.txt`), `pubspec.yaml`, `terminal_pane_stub.dart`, `terminal_pane_web.dart`,
`web/index.html` — **bundle JetBrains Mono** as the terminal font so rendering is
consistent across macOS/Windows/Linux/web instead of relying on system fonts
(native was Menlo, web/test were Consolas which fall through to generic monospace
off-Windows). Native `_textStyle` and the FLUTTER_TEST fallback use
`'JetBrains Mono'` (Menlo/Monaco/Noto kept as fallbacks). For web, xterm.js uses
the browser font system, so added `@font-face` rules in `index.html` pointing at
the Flutter-served `assets/fonts/JetBrainsMono-*.ttf` (no duplicate files) and set
the xterm.js `fontFamily` to `'JetBrains Mono', Consolas, …`. `flutter analyze`
clean; 61 tests pass.

2026-06-04T21:10-0700 **e2e: cannot type in any session.** On Flutter 3.44.1 it
surfaced as a thrown `HardwareKeyboard` assertion — *"A KeyDownEvent is
dispatched, but the state shows that the physical key is already pressed"* (on
Enter) — which aborts key dispatch before it reaches `terminal.onOutput`, so
keystrokes are dropped. Root cause: xterm.dart's `TerminalView` defaults to
`hardwareKeyboardOnly: false`, opening a hidden IME `TextInput` connection
(`CustomTextEdit`); on macOS desktop that IME-vs-hardware-keyboard interaction
desyncs Flutter's keyboard state. Fix: pass `hardwareKeyboardOnly: true` on the
native `TerminalView` (uses xterm's `CustomKeyboardListener` Focus/onKeyEvent
path — the standard desktop terminal fix). Input now works; the only tradeoff is
no IME composition (CJK/dead-keys) in the terminal, fine for ASCII/dev use. Done
while upgrading the SDK (below).

2026-06-04T21:10-0700 `flutter` toolchain upgraded **3.41.2 → 3.44.1** (stable;
the user's global install) so the SDK-pinned dev deps move up
(`matcher` 0.12.18→0.12.19, `meta` 1.17→1.18, `test_api` 0.7.9→0.7.11);
`vector_math`/`url_launcher_android`/`flutter_secure_storage_darwin` remain pinned
by their parent plugins. `pubspec.lock` updated; `flutter clean` was needed once
to regenerate the Material `ink_sparkle.frag` shader manifest after the bump. 61
tests pass on 3.44.1; `flutter analyze` clean.

## Decision

2026-06-03T20:52-0700 Phase 0 PASSED → proceed with the MVI raw-byte refactor.
`raw_output` = coherent-anchored bounded tail (~256 KiB–1 MiB) aligned by
`output_seq`; client re-emulates raw bytes at the host-reported width and deletes
the StyledRow render/replay path. Spike files were throwaway and removed.

## Commits

Note: hashes below reconciled after rebasing the branch onto origin/main
(c389d0d, PR #62).

HEAD — fix(client): use hardware-keyboard input path so typing works on desktop
7444c39 — feat(client): bundle JetBrains Mono as the terminal font
5a39973 — fix(client): strip CSI > ... m so xterm stops poisoning the screen with underline
e6befbc — fix(client): defer native first-fit history replay out of performLayout
fc77f82 — fix(client): defer terminal history replay to the view's first fit
29e80fd — refactor(client): render terminal through the MVI store from raw bytes
f294c33 — feat(host): stream a raw-output history tail in SessionSnapshot
fda35dd — feat(client): add unidirectional MVI terminal seam (intent/state/sink/store)
ae85f5e — fix(client): coalesce resize-driven terminal replays to stop duplicated/fragmented text
269e26d — debug(client): instrument terminal pane layout/metrics for the space-collapse bug

## Next Steps

- Copy the approved plan to `devlog/plans/000056-02-mvi-terminal-pipeline.md`.
- Part A migration step 1: land the client `lib/terminal/*` MVI seam
  (`TerminalIntent`/`TerminalState`/`TerminalSink`/`TerminalStore` +
  `FakeTerminalSink` reducer tests), not yet wired.
- Part B: add `raw_output`/`raw_output_start` (coherent-anchored tail) to
  `SessionSnapshot` + serde + tail reader; populate on attach/resync.
- Strip `[LAYOUTDBG]` instrumentation as the StyledRow path is removed.
