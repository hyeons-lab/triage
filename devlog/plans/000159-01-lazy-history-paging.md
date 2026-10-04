# 000159-01 — Lazy history paging

## Thinking

Every attach ships up to 1 MiB of raw PTY history (`RAW_OUTPUT_TAIL_CAP`)
plus the full scrollback as JSON `visible_rows`, and the client replays
all of it through its emulator before trimming to the paint budget. The
wire bytes are already gzip+base64 (`compressed_bytes`), so the load cost
is daemon disk-read+gzip, client gunzip, and — dominant on slow sessions —
client re-emulation (native parses synchronously on the UI thread).

Paging design, from the seams found in discovery:

1. Attach gains a `history_bytes` cap (`None` = legacy 1 MiB, so old
   clients are unaffected). The client passes a small first page (64 KiB
   ≈ 1000+ lines — viewport plus instant scrollback).
2. New `fetch_history(session_id, before, max_bytes)` RPC reads
   `[before - max_bytes, before)` from the log — segmented (zstd-aware)
   or legacy — and reports the actual start. The client stitches only
   when the page abuts its current start; a trim gap or `start == 0`
   ends paging.
3. The client cannot re-dispatch `HistoryBytes` for a backward
   extension: `_reduceHistory`'s same-end branch no-ops it. A new store
   intent clears the sink and re-emits the concatenated pages (oldest
   first), so emulation always starts at a real stream position — no seam
   artifacts — and fires `onHistoryReplayed` for scroll restore.
4. Both panes already detect scroll position (xterm.js `onScroll`, native
   `ScrollController`) and restore scroll on replay; the prepend flow
   bumps the saved anchor by the added row count.
5. Compressed old segments decompress whole (≤8 MiB) per touched
   segment; recent history lives in the uncompressed active segment
   (seek + slice). Page fetches are user-gated, so the worst case is a
   rare explicit scroll.

## Plan

1. triage-core: `AttachSessionRequest.history_bytes: Option<u64>`
   (serde default), `FetchHistoryRequest/Response` (bytes via
   `compressed_bytes`), `SessionApi::fetch_history` with a default bail
   impl.
2. triaged storage: `read_log_range` for absolute `[start, end)` reads
   across segmented (compressed-aware) and legacy logs.
3. triaged session: thread the cap attach → actor
   `SnapshotWithHistory` → `overlay_raw_output_history`; implement
   `fetch_history` on the manager (live + historical); clamp page size.
4. WS dispatch: wire the `fetch_history` method.
5. Daemon tests: capped attach tail, page stitching offsets, trim-gap
   reporting, segmented range reads.
6. Flutter: `attachSession(historyBytes: 64 KiB)`, retain concatenated
   pages per session, near-top triggers in both panes, new prepend
   intent + anchor-adjusted scroll restore, generation-guarded fetch.
7. Dart tests for page stitching/stop conditions.
8. `cargo fmt`, `cargo clippy -p triaged --all-targets -- -D warnings`,
   `cargo test -p triaged --lib`, `flutter analyze`, `flutter test`.
9. Deploy, re-probe attach for the after number, devlog, commit, push
   with explicit refspec, stacked PR on 186.

## Revision (2026-10-03T22:02-0700)

Steps 2-4 and 6 changed: the `fetch_history` RPC + store prepend-intent
design is replaced by geometric re-attach paging. Attaching with a
doubling `history_bytes` window (64 KiB → platform replay budget)
reuses the hardened attach/replay lifecycle — a backward extension via
re-dispatched `HistoryBytes` would no-op in the store's same-end
branch, and a true prepend needs byte-offset skip-flush machinery for
live chunks applied mid-fetch, fragile for a ~2x byte saving on a rare
path. Re-attach re-anchors trims and live output by construction.
Dropped: `FetchHistory` types/trait/RPC, storage range reads, Dart
fetch (all reverted). Kept: the attach cap end-to-end (core → actor →
overlay → WS JSON + FlatBuffers incl. schema + regen bindings), plus
client window growth, near-top triggers, and anchor-adjusted scroll
restore in both panes.
