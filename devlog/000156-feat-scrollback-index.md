# 000156 feat/scrollback-index

## Agent

2026-10-06T10:02-0700.

## Intent

Ingest-time scrollback index (option 2 of the buried-scrollback
follow-up): sessions whose reachable byte windows hold only TUI
redraws (session-245 class) get their real scrolled lines back.
Journal scrolled lines at ingest, serve them as a prefix to the raw
history window. Zero client or protocol changes.

## What Changed

- 2026-10-06T17:07-0700 (PR A): ingest-time scrollback journal.
  New `crates/triaged/src/scrollback.rs`: `encode_line` (emulator
  line to reset-prefixed SGR bytes + CRLF), `ScrollbackJournal`
  (`scrollback-{:06}.slog` active + `.zst` sealed, 10k lines/file,
  20 retained, offset-stamped records, strict-seam
  `read_prefix_older_than`, trim `rebase`). `OutputState` gains
  `scrollback` + `scroll_seq_baseline`, wired at 4 production
  construction sites; `ingest` anchors the baseline before the
  advance and journals new scrolls after; legacy trim rebases the
  journal. 13 journal/encoder + 3 ingest tests.
- 2026-10-09T11:35-0700: render terminal_style references in
  scrollback.rs doc comments as code spans instead of intra-doc
  links, resolving rustdoc broken-intra-doc-links CI failure.
- 2026-10-06T17:33-0700 (PR B): serve path.
  `overlay_raw_output_history` takes the session journal and
  prefixes journaled lines older than the raw window (cap split
  half/half, raw floor 16 KiB, total clamped; `raw_output_start`
  still addresses the raw tail). Wired into the live and Historical
  `snapshot_with_history` paths. Reads are `&self` (serve paths
  hold no exclusive access); `ingest` flushes the journal after
  every chunk so small journals are serve-visible (the
  all-buffer-serves-nothing bug caught live on session-303). 2
  overlay fixture tests; live-verified end to end (304 live +
  reload, 305 restored) with WS probes.
- 2026-10-09T09:44-0700 (PR B test fix): gate live tmp assertion on unix
  in journal_open test. On non-unix platforms pid_is_alive returns
  false, so live tmp debris is swept on open. Gated the assertion to
  unix and asserted absence on non-unix to pass Windows CI.

## Decisions

- See `devlog/plans/000156-01-scrollback-journal.md` for the full
  decision record. Headline: a per-session on-disk journal of
  SGR-encoded scrolled lines (offset-stamped, decoupled rotation),
  served as a synthetic prefix ahead of the raw tail through the
  existing `raw_output` path.

## Issues

(none yet)

## Commits

- a6592d9: feat(triaged): journal scrolled lines at ingest (PR A)
- bd57f71: docs(triaged): fix broken intra-doc links in scrollback docs
- 199d075: fix(scrollback): review findings from scrollback-index audit
- 4bbc9d2: feat(triaged): serve journaled scrollback prefix (PR B)
- 30c57c2: docs(triaged): fix broken intra-doc links in scrollback docs
- b39ba89: fix(triaged): review findings from scrollback-serve audit loop
- 7355d48: test(triaged): gate live tmp assertion on unix in journal_open test
- HEAD: fix(triaged): address review findings from scrollback-serve audit loop

## Progress

- 2026-10-06T10:02-0700: worktree created from
  `origin/fix/scrollback-paging` (49e347a); ingest path researched;
  plan written, awaiting `go`.
- 2026-10-06T17:07-0700: PR A implemented and gated (13
  scrollback + 5 ingest tests green; fmt/clippy/workspace clean;
  8 pairing failures verified pre-existing on the clean base).
  Committed, pushed, stacked PR opened on `fix/scrollback-paging`.
- 2026-10-06T17:33-0700: PR B implemented, gated, and live-verified
  (synthetic desert sessions over WS: prefix served live, across
  reload, and on the restored path; byte-identical). Committed,
  pushed as `feat/scrollback-serve`, stacked PR opened on
  `feat/scrollback-index`.
- 2026-10-09T09:44-0700: Fixed Windows CI test failure in
  `journal_open_recovers_debris_and_pairs` by gating unix-only live tmp
  assertion. All workspace tests passing.
- 2026-10-09T11:35-0700: Fixed broken intra-doc links in scrollback.rs
  doc comments. Format, clippy, doc, and unit tests passing.
- 2026-10-10T07:24-0700: Rebased onto fix/scrollback-paging (98c6d01).
  Completed 8-pillar code review audit across two rounds. Resolved findings
  including index collation ordering across segment generations, sealed read
  error propagation and stream contiguity, lazy journal file allocation,
  record count allocation optimization, overflow guards, and scroll baseline
  invalidation on emulator reflow. Verified clean across all 8 pillars with
  full test suite and cross-target clippy.
- 2026-10-10T07:54-0700: Completed 8-pillar code review audit for
  scrollback-serve. Fixed partial-record framing synchronization on torn
  payloads, sealed read recovery on unreadable files, header-only empty peek
  handling, staging rename ordering before index unlinks in rebase, and PID
  overflow guards in pid_is_alive. Synchronized barren page continuation and
  exhaustion timer cleanup across Flutter terminal panes. Full workspace tests,
  cross-target clippy, and Flutter test suite passing cleanly.

## Research & Discoveries

- Ingest already runs a full emulator: every PTY byte flows through
  `tattoy_wezterm_term::Terminal::advance_bytes` (session.rs:6690).
- The emulator retains 3500 scrollback rows by default and
  `TriageTerminalConfig` keeps the default: region updates never
  pollute it. The scrolled lines the user wants are already in RAM.
- Production cell→span conversion exists
  (`styled_visible_rows_for_range`); only the span→SGR-bytes inverse
  is new.
- History serving funnels through `overlay_raw_output_history`
  (session.rs:7471): one injection point for the synthetic prefix.

## Lessons Learned

- wezterm `Screen::scrollback_rows()` returns `lines.len()` (total
  rows), not the scrollback count: the doc comment lies. The real
  boundary is `phys_row(0)`. Cost one debugging round-trip (test
  showed 4 lines journaled for 1 scroll).
- Anchor-then-advance: any baseline-diff hook must sample *before*
  the mutation it measures, or the first batch is silently lost.
  single-hook placement runs post-advance.
- Buffered writers + shared-ref readers need a flush contract:
  tests that flush explicitly pass while production serves nothing.
  Pin the production path (read via shared ref, no manual flush) or
  the test proves nothing. Also: the exiting old daemon does not
  drop `OutputState`, so handover does not flush — durability must
  come from the steady-state path, not shutdown.

## Next Steps

- Review order: 193 (paging) → 194 (journal) → serve PR; retarget
  bases as each merges. Then re-verify mobile web on the fresh
  bundle (hard refresh past the 192 service worker) and chase the
  input bug if it persists there.
