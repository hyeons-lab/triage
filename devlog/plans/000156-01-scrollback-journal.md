# 000156-01 scrollback journal

## Thinking

Problem: TUI-saturated sessions (session-245: 2.24 GB log, ~1976
scroll-region cycles/MiB, flooding 4.5 KiB/s) hold no scrollback in
any reachable byte window: the 1 MiB tail replays to 24 lines
(proven in 000155 with headless xterm.js). Byte windows cannot reach
the real scrolled content buried under the redraw desert. PR 193 made
paging correct within reach and honest at exhaustion; this plan
delivers the buried scrollback itself (follow-up option 2: ingest-time
index).

Key findings from the ingest path (all verified this run):

- Every PTY byte already flows through a full VT emulator at ingest:
  `OutputState::ingest` calls `tattoy_wezterm_term::Terminal::
  advance_bytes` (session.rs:6690/6734). Emulation costs nothing new.
- The emulator retains 3500 scrollback rows by default
  (`TerminalConfiguration::scrollback_size`, config.rs:146) and
  `TriageTerminalConfig` keeps the default. Region scrolls never enter
  it (wezterm-correct), so it holds exactly the scrolled lines,
  including session-245's pre-TUI output. The data is already in RAM.
- Production cell→styled-span conversion exists
  (`styled_visible_rows_for_range`, used by `snapshot_from_output`).
  Only the span→SGR-bytes inverse is new.
- History serving funnels through one function,
  `overlay_raw_output_history` (session.rs:7471): one injection point.
- TUI redraw cycles are absolute-anchor rich (8302 `n;nH` positions
  per MiB in session-245), so a mid-stream replay self-corrects,
  the property today's window cuts already rely on.

Options considered:

1. RAM-only: serve the emulator's 3500 rows, re-encoded, ahead of the
   raw tail. Smallest, but evaporates on every daemon restart/reload
   (replay rebuilds from the desert) and caps scrollback at 3500 rows.
   Rejected as the end state (acceptable as a milestone only if the
   journal slips, but the journal is not much more work).
2. Scrollback-as-lines over a new RPC, rendered as static rows above
   the live terminal. Big client surgery on both panes plus a scroll-
   sync problem on web (xterm.js cannot prepend above a replay).
   Rejected: scope.
3. Scrollback-prefixed byte windows + persisted journal (recommended).
   At ingest, detect newly scrolled emulator rows (O(1) count check
   per chunk; deserts append nothing) and journal them to disk as
   SGR-encoded bytes stamped with their log offset. At serve time,
   prefix the journal lines older than the raw window ahead of the raw
   tail through the existing `raw_output` path. The client replays one
   byte stream: the prefix scrolls in as scrollback, the raw desert
   re-anchors and repaints the viewport exactly. Zero client and zero
   protocol changes; PR 193's trim scaling, auto-skip, and pill
   compose (growing prefix per page; pill only when prefix and window
   both exhaust).

Why the journal is persisted, not RAM: daemon reloads are frequent
(every deploy) and would wipe RAM scrollback exactly when the feature
should work; the journal also lifts the 3500-row cap (emulator
eviction no longer loses history) and serves Historical (restored,
terminal-less) sessions from disk. Retention is bounded by decoupled
line-count rotation, independent of log segments.

Why SGR bytes, not spans, in the journal: the encoder runs once at
ingest (amortized) and the serve path concatenates bytes with no
re-encode; each record starts with a reset so rendition cannot bleed
across records. Disk cost tracks scrolled bytes (~1.5-2x), which for
desert sessions is near zero.

Seam semantics: serve journal records with `offset < rawStart`
(strict underlap; overlap would duplicate lines, underlap drops at
most one chunk at the seam). `raw_output_start` stays the raw tail's
start (the prefix is bonus older content); paging termination is
unchanged. Budget split: prefix up to half the window cap, raw tail
the rest (min 16 KiB raw so the viewport always repaints).

Deliberate semantic: wiped (3J) scrollback stays servable from the
journal: triage history is a record, not a mirror of terminal
scrollback. Alt-screen content is never journaled (ephemeral by
terminal design, consistent everywhere). Journal rows keep their
ingest width (rewrap differences on resize are cosmetic).

## Plan

### Goal

Sessions whose byte windows hold only TUI redraws serve their real
scrolled lines again: attach and page-up return emulator scrollback
(from a persisted journal) ahead of the raw tail, with no client or
protocol changes.

### Success Criteria

- Attaching session-245 (or a desert fixture) shows pre-desert
  scrolled lines above the live TUI screen on first paint.
- Paging deeper grows scrollback (prefix + window both scale); at full
  exhaustion the existing pill still reports honestly.
- Daemon restart, reload/handover, and Historical sessions keep
  serving journaled scrollback (disk-persisted, terminal-independent).
- Ingest overhead is unmeasurable on desert floods (O(1) count check
  per chunk when nothing scrolls) and bounded disk growth (rotation
  cap; desert sessions journal near zero).
- Full workspace gates green; no client changes in either PR.

### Approach

Two stacked daemon-only PRs on `fix/scrollback-paging`:

- PR A (journal): SGR encoder (cells→bytes) + per-session journal
  (`scrollback-NNNNNN.slog`, zstd-sealed like `.tlog.zst`, decoupled
  10k-line rotation, retention cap) + ingest hook (detect added rows
  per chunk, append records) + legacy-trim rebase + unit tests.
- PR B (serving): seam query (records older than the raw window) +
  budget split (prefix ≤ cap/2, raw ≥ 16 KiB) wired into
  `overlay_raw_output_history` for live and Historical paths +
  integration tests with a desert fixture + live verification.

Encoder reuses `styled_visible_rows_for_range`'s cell walk and adds
the span→SGR serializer (~150 lines): fg/bg (RGB + palette), bold,
italic, underline, inverse; reset at each record start; `\r\n` line
ends (no autowrap dependence).

### Steps

1. SGR encoder (`crates/triaged/src/scrollback.rs`, new): cells of one
   emulator `Line` → SGR bytes. Golden-byte unit tests (plain, RGB,
   palette, attrs, wide chars, empty line).
2. Journal writer: per-session dir, `scrollback-{:06}.slog` active
   file, record = `[offset:u64][len:u32][bytes]`; rotate every 10k
   lines; seal rotated files with zstd (same crate as segments);
   retain last 20 files. Unit tests (append/read/seam query/rotate).
3. Ingest hook in `OutputState::ingest` (after `advance_bytes`):
   compare `screen().scrollback_rows()` count before/after; on growth,
   read the added phys rows and append. Handle shrink (3J wipe:
   keep journal, reset baseline), alt-screen (no growth, no-op),
   resize (reflow may renumber rows: reset baseline, note the cosmetic
   width seam). Unit tests with desert bytes (no appends) and
   scrolling bytes (appends with ascending offsets).
4. Legacy-trim rebase: when `trim_session_log` rebases `bytes_logged`,
   drop journal records from the cut head and shift survivors (rare
   path; unit test). Segmented sessions never rebase (absolute
   offsets).
5. Serve path: extend `overlay_raw_output_history` (or a wrapper at
   its two call sites: live actor path session.rs:3284 and
   Historical path session.rs:3296) to prepend seam-queried journal
   bytes within the budget split. `raw_output_start` unchanged.
6. Desert-fixture integration test: feed region-update cycles plus
   older scrolled lines through ingest, attach with a small window,
   assert the served bytes replay to the scrolled lines followed by
   the live screen (assert on emulator state, hermetic, no client).
7. Live verification on session-245: attach shows pre-TUI scrollback;
   reload preserves it; Historical session serves it.

### Validation Plan

- `cargo test -p triaged --lib scrollback` (encoder goldens, journal,
  seam, rebase), `cargo test -p triaged` (full crate incl. fixture
  integration), `cargo fmt --all -- --check`,
  `cargo clippy --all-targets --all-features -- -D warnings`,
  `cargo check --workspace`.
- `flutter test` (no client changes; guards the contract), `flutter
  analyze`.
- Live: JSON attach probe on session-245 (scrolled lines present in
  served bytes); headless-xterm replay line count before/after;
  reload + re-attach (journal survives); Historical attach (journal
  serves without a terminal).
- Perf: desert-flood ingest microbench (assert per-chunk work stays
  O(1): chunk counter test with 1 MB of region updates appends zero
  records); journal disk usage after the flood ≈ 0.

### Risks / Open Questions

- Risk: wezterm resize reflow renumbers phys rows, breaking the
  before/after baseline. Mitigation: reset the baseline on any
  resize (loses at most the in-flight chunk's rows); covered by a
  unit test. No data loss beyond one chunk.
- Risk: SGR fidelity gaps (obscure attrs, kitty graphics, hyperlinks
  in scrollback). Mitigation: encoder covers the attrs
  `terminal_style` already maps; anything else degrades to plain
  text. Scrollback stays readable; the live screen is unaffected
  (raw tail intact).
- Risk: journal disk growth on scroll-spam sessions (`yes`, tight
  log loops). Mitigation: 20-file retention cap (~20-40 MB worst
  case); same order as log retention. Monitored in live verify.
- Open: exact budget split numbers (prefix ≤ cap/2, raw ≥ 16 KiB)
  are defaults; live verification on 245 may tune them. No protocol
  impact either way.
- Non-goals: client changes, protocol changes, alt-screen history,
  backfilling scrollback for logs written before this ships (journal
  starts at deploy; old deserts stay deserts until new scrolls
  arrive; acceptable and documented).

## Build Notes (appended during implementation)

- 2026-10-06T17:07-0700: PR A implemented (encoder, journal,
  ingest hook, trim rebase). Two deviations from the plan, both
  simplifications:
  - Detection uses baseline-diff on `visible_row_to_stable_row(0)`
    rather than `get_changed_stable_rows` + damage seqnos. The
    first-visible stable index only moves on scroll, and scrollback
    rows are immutable, so rows between baseline and boundary are
    exactly the new scrolls. No `SequenceNo` plumbing needed.
  - The baseline anchors *before* the first advance
    (`init_scroll_baseline` in `ingest`), not after. Anchoring
    after skips the first chunk's scrolls (caught by the offset
    test: cold start must journal chunk 1). Restore/reflow replay
    never calls it, so rebuilt terminals anchor onto the rebuilt
    window instead of double-journaling persisted lines.
- wezterm API trap: `Screen::scrollback_rows()` returns the *total*
  row count (`lines.len()`) despite its doc comment. The
  scrollback/viewport boundary is `phys_row(0)`. Using the former
  journaled the viewport on every scroll (caught by test: 4 lines
  journaled where 1 scrolled).
- `Terminal` is `tattoy_wezterm_term`, not alacritty (no alacritty
  dependency in the workspace at all). `StableRowIndex` is wezterm's
  `isize` alias, already imported in session.rs.
- Test hermeticity: `test_output_state` defaults `scrollback: None`
  because `unique_log_path` tests share the temp dir and journals
  there would interleave. Journal tests open their own journal in a
  `unique_log_dir`.
- Gates: `cargo test -p triaged --lib scrollback::` 13 pass;
  `ingest_` 5 pass (3 new); full `-p triaged` 359 pass + 8
  pre-existing pairing-test failures that also fail on the clean
  base (device-code pairing disabled in this environment;
  unrelated). fmt clean, clippy `-D warnings` clean, `cargo check
  --workspace` clean. Flutter untouched, suite not re-run.

- 2026-10-06T17:33-0700: PR B implemented (serve path). Notes:
  - Both serve paths (`ActorState` live, `HistoricalSession`) hold
    only `&self`, so `read_prefix_older_than` takes `&self` and reads
    flushed bytes only. `append` flushes every 128 records; `ingest`
    flushes after every chunk (empty buffer = one branch, dirty =
    one write), so the journal is current through the last chunk.
    Without the per-chunk flush, journals under the threshold are
    all buffer and serve nothing — caught live (session-303: 77
    records buffered, 0-byte file, no prefix) after unit tests
    passed by flushing explicitly. Regression pinned by reading via
    a shared ref with no manual flush in the offset test.
  - Unflushed records die with the process: the exiting old daemon
    does not drop `OutputState` (303's 77 records never landed even
    after handover). Per-chunk flush bounds loss to a killed chunk.
  - Cap split: prefix budget = cap/2, raw floor 16 KiB, total
    clamped to the cap; `raw_output_start` still addresses the raw
    tail. Gated on journal presence, not non-emptiness: big-raw +
    empty-journal is only possible for pure desert, whose tail is
    useless anyway.
  - Live verify (release daemon + handovers, all clean): synthetic
    session-304 (100 markers + 680 KB desert) served 77 journaled
    markers as a reset-led prefix ahead of 512 KiB raw
    (served=527423, byte-identical across reload); exited 305
    served the identical prefix after a reload (restored path).
    Adopted 245/256 journals appending live. Probe sessions shut
    down afterwards.
  - Explicit shutdown deletes the session dir (no Historical);
    exited-by-itself sessions restore as Historical. Verified via
    the latter (305).
