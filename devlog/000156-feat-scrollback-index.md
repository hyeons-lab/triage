# 000156 feat/scrollback-index

## Agent

Muse Code (muse-spark) — 2026-10-06T10:02-0700.

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

## Decisions

- See `devlog/plans/000156-01-scrollback-journal.md` for the full
  decision record. Headline: a per-session on-disk journal of
  SGR-encoded scrolled lines (offset-stamped, decoupled rotation),
  served as a synthetic prefix ahead of the raw tail through the
  existing `raw_output` path.

## Issues

(none yet)

## Commits

- HEAD — feat(triaged): journal scrolled lines at ingest (PR A)

## Progress

- 2026-10-06T10:02-0700: worktree created from
  `origin/fix/scrollback-paging` (49e347a); ingest path researched;
  plan written, awaiting `go`.
- 2026-10-06T17:07-0700: PR A implemented and gated (13
  scrollback + 5 ingest tests green; fmt/clippy/workspace clean;
  8 pairing failures verified pre-existing on the clean base).
  Committed, pushed, stacked PR opened on `fix/scrollback-paging`.

## Research & Discoveries

- Ingest already runs a full emulator: every PTY byte flows through
  `tattoy_wezterm_term::Terminal::advance_bytes` (session.rs:6690).
- The emulator retains 3500 scrollback rows by default and
  `TriageTerminalConfig` keeps the default — region updates never
  pollute it. The scrolled lines the user wants are already in RAM.
- Production cell→span conversion exists
  (`styled_visible_rows_for_range`); only the span→SGR-bytes inverse
  is new.
- History serving funnels through `overlay_raw_output_history`
  (session.rs:7471): one injection point for the synthetic prefix.

## Lessons Learned

- wezterm `Screen::scrollback_rows()` returns `lines.len()` (total
  rows), not the scrollback count — the doc comment lies. The real
  boundary is `phys_row(0)`. Cost one debugging round-trip (test
  showed 4 lines journaled for 1 scroll).
- Anchor-then-advance: any baseline-diff hook must sample *before*
  the mutation it measures, or the first batch is silently lost.
  Here that meant a separate pre-advance init, because the natural
  single-hook placement runs post-advance.

## Next Steps

- PR B: serve path in `overlay_raw_output_history` (live +
  Historical), fixture integration, live verify on session-245,
  then gates + stacked PR.
