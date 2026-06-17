# 000071-01 — Hoist SessionContext display logic into triage-core

## Thinking

PR #78 added `context_header` + `leaf_name` to `crates/triaged/src/summarizer.rs`
to render a `repo · branch · worktree` localization label for the detail
summary. A `/code-review` pass flagged that this duplicates logic already in the
CLI TUI (`crates/triage/src/main.rs`):

- `leaf_name(path)` ≈ `context_path_display_name(path)` — both take a path's
  last component.
- the "worktree distinct from repo root" suppression rule lives in three places:
  `context_header`, `session_context_rows`, and `session_context_overflows`.

All of it operates on `SessionContext`, which is defined in `triage-core`. Two
crates with their own copies of the same rules will drift. The fix is to make
`triage-core` the single source of truth.

## Plan

1. `triage-core::session`:
   - Add a free `path_leaf_name(&Path) -> Option<String>` primitive.
   - Add `SessionContext` methods: `repository_name`, `distinct_worktree_root`
     (encodes the repo==worktree suppression once), `worktree_name`,
     `branch_name` (empty → absent), and `localization_label` (the full
     `repo · branch · worktree` join, moved verbatim from `context_header`).
   - Unit-test all of it (the label cases moved from the summarizer, plus
     leaf/distinct-worktree/branch primitives).
2. `triaged::summarizer`: delete `context_header` + `leaf_name`; call
   `SessionContext::localization_label`. Drop the now-unused `Path` import and
   the moved test.
3. `triage` (TUI): `context_path_display_name` delegates to `path_leaf_name`;
   `session_context_rows` and `session_context_overflows` use
   `distinct_worktree_root`. Behavior preserved exactly.
4. Validate: build, tests, `clippy -D warnings`, `fmt --check` across the three
   crates.
