<!-- Source: Claude Code plan-mode slug `idempotent-bouncing-truffle`. Copied verbatim per CLAUDE.md plan-first workflow. -->

# Plan: Unidirectional MVI Terminal Text Pipeline (raw-byte single source)

## Context

The macOS/web Triage clients render Claude Code's TUI with **collapsed spaces, duplicated lines, and dropped leading characters** ("for"→"or", "when"→"hen"). Through instrumented runs we proved this is **not** a font/width bug (measured cell width == glyph advance, no text scaling) and **not** the client storm alone (coalescing the resize-replay storm to one rebuild did not fix it). The root cause is **architectural**: terminal content reaches the screen through multiple racing code paths over a lossy double-emulation:

- **Live**: raw PTY bytes → `terminal.write()`
- **History/replay**: host `wezterm-term` grid → `StyledRow` (FlatBuffers) → client reconstructs ANSI (`normalizeReplayRow`/`clipRowToCols`/`styledRowToAnsi`) → re-parsed by a *second* emulator (xterm)
- **Reset/rebuild**: `_triggerFullReplayOrReset` → `resetTerminalSafe` + re-write, fired on every resize snapshot

Coordinated by ~10 booleans and ~8 timers spread across the widget `State`, `SessionVm`, and widget props. The dropped characters were confirmed present **in the host-captured `StyledRow`s themselves**, i.e. produced by the host's grid stringification, then faithfully rendered by the client.

**Goal:** replace this with a single-source, unidirectional, testable **MVI** pipeline. The **single source of truth is the raw PTY byte stream; xterm is the model.** The client re-emulates raw bytes at its own size, which **sidesteps the host's StyledRow off-by-one/char-drop entirely** (the client stops consuming StyledRows). Outcome: one ordered byte stream → one emulator → correct, race-free rendering, with a unit-testable reducer.

This supersedes the interim resize-replay coalescing commit on this branch (that path is deleted) and the temporary `[LAYOUTDBG]` instrumentation (stripped).

---

## Phase 0 — De-risking spike (gate the whole refactor)

**Do this before writing any production code.** It validates the load-bearing assumption (raw-byte replay reconstructs Claude's alt-screen screen) and decides the attach contract from data, not assumption.

Real raw session logs already exist on disk: `~/.local/state/triage/sessions/session-N.log` (the host's `OutputState.log`, written at `crates/triaged/src/session.rs:356` = `config.log_dir/{session_id}.log`). Pick a session that was running Claude Code.

Spike (throwaway; a Dart program / `flutter test` using `package:xterm` `Terminal`, no app wiring):
1. **Full-log fidelity:** read the whole `session-N.log`, write it into a fresh `Terminal(maxLines:10000)` sized to e.g. 80×40, dump `terminal.buffer` rows to text, and eyeball/compare against the known screen (Claude welcome box, mode line). Confirms full replay reproduces the alt-screen correctly in **xterm.dart** specifically.
2. **Partial-tail breakage point:** repeat feeding only the last 1/2/4 MiB. Find where the alt-screen-enter falls outside the tail and the screen breaks. This quantifies whether a plain tail is ever safe.
3. **Coherent-anchor test:** scan the log for the last `\x1b[?1049h` / RIS (`\x1bc`) / `\x1b[2J`+home offset; replay from there; confirm it reconstructs the screen and how far back that offset typically sits (bounded vs near session-start).
4. **Performance:** time `Terminal.write(fullLog)` for the largest realistic log; decide whether chunking (64 KB) is needed and whether full-log payloads are acceptable.

**Decision output:** the `raw_output` contract for Part B — full log vs coherent-anchored tail vs (fallback) forced-repaint. Record results in `devlog/000056`. If xterm.dart fidelity is inadequate even for full replay, stop and reconsider (the whole approach rests on this).

## Architecture (MVI)

```
host raw PTY bytes ──(live Output{bytes,seq} + attach/resync raw_output tail)──▶
   TerminalStore (per session)
     dispatch(Intent) ──▶ reduce(State, Intent) ──▶ single TerminalSink.write/resize/clear ──▶ xterm
                                     │
                                     └─▶ new immutable TerminalState ─▶ thin View rebuild
   xterm.onOutput / onResize ──▶ dispatch(UserInput / Resize) ──▶ host writeInput / resizeSession
```

One reducer owns all mutations and applies intents **in arrival order** through **one** write path. The host is already actor/unidirectional; this brings the client to parity.

---

## Part A — Client (Flutter): MVI store

New package `lib/terminal/`:
- `terminal_intent.dart` — sealed `TerminalIntent`: `LiveBytes(bytes, outputSeq?)`, `HistoryBytes(bytes, cols, rows, throughOutputSeq?)`, `Resize(cols,rows)`, `UserInput(data)`, `Attach`, `Detach`, `Exited`, `Clear`.
- `terminal_state.dart` — immutable `TerminalState` (control state only; xterm owns the grid): `cols,rows,sized,phase(AttachPhase.detached|awaitingHistory|live),exited,scrollbackReady,lastSentCols/Rows,historyHighWaterSeq`, value equality + `copyWith`.
- `terminal_sink.dart` — `abstract TerminalSink { write(String); resize(c,r); clear(); get viewport; set onOutput; set onResize; }` — the only seam touching a real emulator.
- `terminal_store.dart` — `TerminalStore extends ChangeNotifier`: `dispatch(Intent)` → `_reduce` (performs sink effects in order) → emit `TerminalState`. Owns the **one** `_pendingBytes` buffer and the **one** `_utf8Carry` (partial-UTF-8) + CRLF translation in `_writeBytes`.
- `xterm_native_sink.dart` / `xterm_web_sink.dart` — concrete sinks over `package:xterm` `Terminal` and xterm.js (`js_util`).
- `test/terminal/terminal_store_test.dart` — reducer unit tests with a `FakeTerminalSink` (ordered op-log), no Flutter binding.

**Reducer rules (single ordered path):**
- `Resize`: ignore below min; `sink.resize` (native reflow) → flush `_pendingBytes` once if now sized → `onResizeOut(c,r)` once per distinct size. **No replay, no reset.**
- `HistoryBytes`: `sink.resize` + `sink.clear` → write history → `phase=live, scrollbackReady, historyHighWaterSeq=throughOutputSeq` → flush queued post-history live.
- `LiveBytes`: drop if `outputSeq <= historyHighWaterSeq`; buffer if not `sized` or `awaitingHistory`; else write.
- `UserInput`: forward to host only (no local echo); suppressed when `exited`.
- `Clear/Exited/Attach/Detach`: state/sink transitions.

**Wiring (`lib/main.dart`):** `SessionVm` holds a `TerminalStore` instead of `terminal`/`terminalController`/`rows`/`replayRevision`/`initialContentWritten`/`inFlight*`/UTF-8 buffers. Websocket handler maps events→intents: `Output`→`LiveBytes`, attach/`ResyncRequired`→`Attach`+`HistoryBytes(rawLog,...)`, `Exited`→`Exited`, resize-driven `Snapshot`→**deleted**. The local-mock input branch that mutates `session.rows` (`main.dart:663`) is removed.

**Thin Views:** `terminal_pane_stub.dart` (native) and `terminal_pane_web.dart` (web) keep only: host the xterm view, focus/clipboard/Tab handling, and **debounced** fit detection that lets the emulator's `onResize` fire into the store. Both share the store; only the sink differs.

**Delete:** `lib/widgets/terminal_replay.dart` (whole file); native+web `_writeInitialContent`/`_triggerFullReplayOrReset`/`_resetTerminalSafe`/`_finishInitialContent`/`_flushPendingLiveWrites`/`_suppressInput`+replay timers; `TerminalController` write/clear/resize/fit listener lists; `SessionVm.rows`/`_mergeVisibleAndStyledRows`/`decodeOutputBytes`/`replayCoalesceTimer`/`replayRevision`; the `[LAYOUTDBG]` instrumentation; client-side parsing of `styled_rows` for rendering. Keep `terminal_models.dart` only if still referenced; otherwise delete.

---

## Part B — Host (Rust): stream raw output history

Append to `SessionSnapshot` (`crates/triage-core/src/session.rs:~100`) two FlatBuffers-append-only fields: `raw_output: Vec<u8>` (RAW output bytes for history reconstruction) and `raw_output_start: u64` (byte offset of its first byte). **The exact window (full log vs coherent-anchored tail) is decided by the Phase 0 spike** — `reflow_from_log` (session.rs:2225) proves full replay is correct, and the host can cheaply track the last screen-coherent offset during `ingest` if the spike shows a plain tail is unsafe. Because attach/`ResyncRequired`/resize-`Snapshot` all embed `SessionSnapshot`, one struct + one schema edit covers every history path.

- **Send RAW (untranslated) bytes** — identical to the live `Output{bytes}` stream (`session.rs:~1805`), so history and live are byte-identical. The log already stores raw bytes (`ingest`, `session.rs:~2194`).
- **Alignment via `output_seq`** (per-chunk counter; `bytes_logged` is the true byte offset). Snapshot is taken in the single-threaded actor, so `(output_seq=S, bytes_logged=B)` is consistent. Client feeds `raw_output` (log `[start..B]`), then **drops live `Output` with `output_seq <= S`**. No gap, no overlap.
- **Scrollback cap** `const RAW_OUTPUT_TAIL_CAP: u64 = 4*1024*1024;`. New `OutputState::raw_output_tail(log_path, cap) -> (start, bytes)`: flush, open a fresh read handle, `seek(End(-min(cap,bytes_logged)))`, read to end. Historical/restoring snapshots take the tail from their already-loaded replay log.
- **Schema/serde:** add the two fields in `crates/triage-core/schema/triage.fbs` (after `exited`), regenerate bindings, update `build_session_snapshot` + its decoder in `crates/triage-core/src/flatbuffers_proto.rs`, and fill the new fields (`Vec::new()`, `0`) in every literal `SessionSnapshot {...}` constructor (tests + `crates/triage/src/main.rs`). Append-only → old/new client/host interop preserved (new client keeps a StyledRow fallback when `raw_output` is empty).
- **Keep StyledRows** (`styled_visible_rows_for_range`, `snapshot_from_output`) and the resize `Snapshot` broadcast intact for the **local Rust TUI** (`crates/triage/src/main.rs`). Resize still calls `master.resize(pty_size)` so the child wraps correctly. Raw clients simply ignore `Snapshot` events. (Phase 2, optional follow-up: make host reflow lazy when no StyledRow consumer is attached.)
- **Off-by-one:** confirmed `pty_size`/`terminal_size` pass cols/rows unmodified; the 1-col-wide artifact lives only in grid stringification and is **irrelevant** to raw clients. Out of scope; not a blocker.

---

## Open items from critical review (resolve during implementation)
- **Local (non-remote) sessions** (`main.dart:663-690`) are a local echo *mock* that mutates `session.rows` directly with no PTY byte stream. Deleting the StyledRow path breaks them. Decide: drop these mock sessions, or back them with a local in-memory byte sink (a fake PTY echo producing bytes into the store). Investigate what creates them before deleting.
- **Test/fallback coupling:** the `FLUTTER_TEST` branch (`terminal_pane_stub.dart:484`) and widget tests assert on `fallbackRows`. Re-home those assertions onto `TerminalStore` + `FakeTerminalSink` (the new, better seam) as the StyledRow fallback is removed.
- **Lockstep release:** host+client ship together (monorepo), so **delete** the client StyledRow path outright — do **not** keep an old-host `raw_output`-empty fallback. State this so step 6 is unambiguous.

## Migration (each step independently shippable; app stays working)

0. **Phase 0 spike** (above) — gate the approach and fix the `raw_output` contract. No production code until this passes.
1. Land the client seam (`terminal/` files + `terminal_store_test.dart`); not yet wired. App unchanged.
2. Host: add `raw_output`/`raw_output_start` to `SessionSnapshot` + serde + tail reader; populate on attach/resync. (StyledRows still sent.)
3. Native: route `Output`→`LiveBytes` through a `TerminalStore` over a native sink wrapping the existing `xt.Terminal`; switch attach/resync to `Attach`+`HistoryBytes`. Delete native replay machinery.
4. Web: implement web sink; point web pane at the store; delete web replay machinery.
5. Delete resize→snapshot replay (`coalesceReplay`/`replayRevision`/`_applySnapshotToSession` history branch + `Snapshot`-on-resize handling).
6. Delete `terminal_replay.dart`, `SessionVm.rows`/merge, `TerminalController` mutation lists, client `styled_rows` render parsing; update the `TerminalPane` construction site; strip `[LAYOUTDBG]`.

## Key risks (with mitigations)
- **(Headline, gated by Phase 0) Alt-screen reconstruction:** Claude enters the alternate screen once near session start; a blind byte *tail* that excludes that point renders garbage. The spike decides the safe window (full log / coherent-anchored tail). Do not proceed past Phase 0 without a passing fidelity result.
- **Whole approach rests on xterm.dart emulation fidelity** (no StyledRow ground-truth fallback after the refactor). The live path already relies on it and our metrics run showed live rendering correct — accepted bet, but the spike re-confirms it for full replay before committing.
- **Large-log parse cost** on `HistoryBytes` (single `Terminal.write`): chunk writes (64 KB) in the sink; bound the `raw_output` window per the spike.
- **Web/native parity** (`convertEol`, reflow, escape coverage): do CRLF translation once in the store, disable xterm.js `convertEol`; add a both-sinks parity smoke test.
- **Spurious input from history** (DSR/cursor-report sequences echoing via `onOutput`): gate `UserInput` forwarding while `awaitingHistory`/until first real keystroke; test it.
- **Late-live vs history window**: queue live chunks tagged with `outputSeq`; on `HistoryBytes`, drop only those `<= throughOutputSeq`, replay the rest (don't blanket-clear).
- **Partial-tail mid-escape** when `raw_output_start>0`: accept minor top-of-scrollback artifact initially; `raw_output_start` enables a future paged `FetchOutputLog{from_byte}`.

## Verification
- **Unit:** `flutter test test/terminal/terminal_store_test.dart` — buffering-before-size, history-before-live, `outputSeq` de-dupe, resize emits no extra writes, split-UTF-8, UserInput forwards/suppressed.
- **Host:** `cargo test` — `raw_output_tail` boundaries, snapshot `(raw_output,output_seq)` boundary equals full untranslated log fed to a reference emulator, FlatBuffers round-trip incl. empty (old-host) case, local-TUI StyledRow tests still pass.
- **End-to-end (the original repro):** `flutter run -d macos` from the worktree, attach to a session showing Claude's welcome box + mode line, **toggle the side rail repeatedly** and resize the window. Expect: no duplicated lines, no dropped leading characters, spaces intact, one clean reflow. Compare against the pre-fix screenshots captured in `devlog/000056`.
- `flutter analyze` and `cargo build` clean; `JAVA_HOME=…/21.0.9-zulu` not needed (Flutter desktop), but Rust builds via normal `cargo`.

## Critical files
- Client: `flutter/triage_client/lib/main.dart`, `lib/widgets/terminal_pane_stub.dart`, `lib/widgets/terminal_pane_web.dart`, `lib/widgets/terminal_pane.dart`, `lib/widgets/terminal_replay.dart` (delete), new `lib/terminal/*`.
- Host: `crates/triaged/src/session.rs`, `crates/triage-core/src/session.rs`, `crates/triage-core/src/flatbuffers_proto.rs`, `crates/triage-core/schema/triage.fbs`, `crates/triage/src/main.rs`.

## Devlog
Continue `devlog/000056-fix-terminal-layout-collapse.md` (committed on this branch); copy this plan to `devlog/plans/000056-02-mvi-terminal-pipeline.md` per project convention. Likely split into 2 PRs (host raw-output, client MVI) given size.
