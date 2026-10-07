# 000156 feat/scrollback-index

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
  `scrollback` + `scroll_seq_baseline`, wired at production
  construction sites; `ingest` anchors the baseline before the
  advance and journals new scrolls after; legacy trim rebases the
  journal.
- 2026-10-18T20:06-0700 `crates/triaged/src/scrollback.rs`, `crates/triaged/src/session.rs`:
  Fixed `sealed_and_active_newest_first` so `active_index` is placed at
  index 0 (newest) rather than appended after the oldest sealed index;
  truncated torn tail bytes in `open_active` (`repair_and_count_records`)
  before opening in append mode; scoped `.tmp.` cleanup to
  `scrollback-*.slog.zst.tmp.*` and unlinked stale `.slog` files at or
  below `highest_sealed`; restricted `open_journal_for_log` and
  `LogInitialization::Truncate` segment/journal purges to segmented log
  paths (`resolve_segment_session_dir`), and kept `output_state_for_log`
  read-only (`scrollback: None`); flushed `BufWriter` at the end of
  `append_inner` so records are never left buffered in user-space across
  zero-downtime handover (`process::exit`) or split at 8 KiB auto-flush
  boundaries; reset `scroll_seq_baseline` in `reflow_from_log` and
  flushed pending translated bytes with journaling on live timeouts,
  `OutputClosed`, `shutdown`, `PtySession::drain_until_exit`, and
  `ActorState::extract_handover_state`; made `rebase_inner` write to
  fresh indices before unlinking old files; added buffered bytes to
  `journaled_bytes` and short-circuited disabled journals and
  `raw_start == 0` / `cut == 0`; added rotation, recovery, purge, reflow,
  and pending-escape-flush unit tests.

## Decisions

- See `devlog/plans/000156-01-scrollback-journal.md` for the full
  decision record. Headline: a per-session on-disk journal of
  SGR-encoded scrolled lines (offset-stamped, decoupled rotation),
  served as a synthetic prefix ahead of the raw tail through the
  existing `raw_output` path.

## Issues

- 2026-10-18T20:06-0700: `sealed_and_active_newest_first` pushed
  `self.active_index` onto the end of a descending list, inverting active
  and sealed file order after rotation; `open_active` did not truncate
  torn tail bytes before opening with `append(true)` and swept all
  `.tmp.` files in the session directory; `open_journal_for_log` and
  `LogInitialization::Truncate` operated on shared parent directories for
  flat `.log` paths; `append_inner` left appended records buffered in
  `BufWriter` across zero-downtime handover (`process::exit`); and
  `reflow_from_log` left a stale `scroll_seq_baseline` across terminal
  replacement. Fixed and covered by unit tests.

## Commits

- HEAD: feat(triaged): journal scrolled lines at ingest (PR A)

## Progress

- 2026-10-06T10:02-0700: worktree created from
  `origin/fix/scrollback-paging` (49e347a); ingest path researched;
  plan written, awaiting `go`.
- 2026-10-06T17:07-0700: PR A implemented and gated (13
  scrollback + 5 ingest tests green; fmt/clippy/workspace clean;
  8 pairing failures verified pre-existing on the clean base).
  Committed, pushed, stacked PR opened on `fix/scrollback-paging`.
- 2026-10-18T20:06-0700: Addressed Round 1 and Round 2 review findings
  and expanded scrollback and ingest test coverage.

## Research & Discoveries

- Ingest already runs a full emulator: every PTY byte flows through
  `tattoy_wezterm_term::Terminal::advance_bytes` (session.rs:6690).
- The emulator retains 3500 scrollback rows by default and
  `TriageTerminalConfig` keeps the default; region updates never
  pollute it. The scrolled lines the user wants are already in RAM.
- Production cell-to-span conversion exists
  (`styled_visible_rows_for_range`); only the span-to-SGR-bytes inverse
  is new.
- History serving funnels through `overlay_raw_output_history`
  (session.rs:7471): one injection point for the synthetic prefix.

## Lessons Learned

- wezterm `Screen::scrollback_rows()` returns `lines.len()` (total
  rows), not the scrollback count; the doc comment is inaccurate. The real
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
