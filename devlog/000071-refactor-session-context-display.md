# refactor/session-context-display

**Agent:** Claude Code (claude-opus-4-8) @ triage branch refactor/session-context-display
(worktree: worktrees/session-context-display)

## Intent

Remove the cross-crate duplication a `/code-review` of PR #78 surfaced: the
daemon's detail-summary header (`context_header`/`leaf_name` in
`crates/triaged/src/summarizer.rs`) re-implemented repo/branch/worktree display
rules that the CLI TUI (`crates/triage/src/main.rs`) already had. Both operate on
`SessionContext` (defined in `triage-core`), so two copies of the leaf-name
extraction and the "worktree distinct from repo root" suppression rule would
drift on the next UI change. Make `triage-core` the single source of truth.

## What Changed

- 2026-06-16T22:18-0700 `crates/triage-core/src/session.rs` — added the shared
  API on `SessionContext`: `repository_name`, `distinct_worktree_root` (the
  repo==worktree suppression, encoded once), `worktree_name`, `branch_name`
  (empty string → absent), and `localization_label` (the one-line
  `repo · branch · worktree` join, moved verbatim from the summarizer's
  `context_header`). Added a free `path_leaf_name(&Path) -> Option<String>`
  primitive. Imported `std::path::Path`. Added unit tests for the primitive, the
  distinct-worktree rule, the empty-branch rule, and the label (the cases moved
  out of the summarizer plus the worktree==branch suppression case).
- 2026-06-16T22:18-0700 `crates/triaged/src/summarizer.rs` — deleted
  `context_header` and `leaf_name`; `generate_detail` now calls
  `SessionContext::localization_label`. Dropped the now-unused `Path` import and
  the `context_header_mirrors_the_side_rail_meta_line` test (its cases live in
  triage-core now). The e2e test still asserts the detail leads with the header.
- 2026-06-16T22:18-0700 `crates/triage/src/main.rs` —
  `context_path_display_name` delegates to `path_leaf_name`;
  `session_context_rows` and `session_context_overflows` use
  `distinct_worktree_root` instead of an inline `repository_root != worktree_root`
  filter. Behavior unchanged.

## Decisions

- 2026-06-16T22:18-0700 Put the logic on `SessionContext` (and a free
  `path_leaf_name`) in triage-core rather than in a UI crate — it's domain
  display logic over a triage-core type, consumed by both the daemon summarizer
  and the CLI TUI. The Flutter client renders its own meta line in Dart and can't
  share Rust code, so it's out of scope; this PR collapses the two *Rust* copies.
- 2026-06-16T22:18-0700 Left the TUI's branch-row rendering as-is (it doesn't
  filter empty branches) to keep the refactor strictly behavior-preserving;
  `branch_name`'s empty-string filtering is used by `localization_label` only.
- 2026-06-16T22:18-0700 Kept `context_path_display_name` as a thin local wrapper
  (it adds the full-path fallback the TUI wants for a rootless path) over the
  shared `path_leaf_name`, rather than inlining — many callers, and the fallback
  is TUI-specific.

## Issues

- 2026-06-16T22:18-0700 Built and tested off the merged `main` (PR #78 landed as
  `3dff89b`), so this is a plain PR off main, not stacked. `cargo build` +
  `cargo test` (triage-core 22 passed incl. 5 new; triaged summarizer 7 passed,
  e2e ignored) + `cargo clippy --all-targets --all-features --locked -D warnings`
  + `cargo fmt --all --check` all clean across triage-core/triaged/triage.

## Commits

- HEAD — refactor: hoist SessionContext display logic into triage-core
