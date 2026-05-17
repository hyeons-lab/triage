# fix/tui-shift-tab-input

## Agent
- Codex

## Intent
- Forward `Shift+Tab` from the outer TUI to child terminal applications so reverse-tab shortcuts work inside Codex and other terminal programs.

## What Changed
- Mapped crossterm reverse-tab key events to the standard `ESC [ Z` terminal input sequence.
- Kept plain `Tab` forwarding as a literal tab byte.
- Added focused regression coverage for both `BackTab` and shifted `Tab` event forms.

## Decisions
- Covered both event shapes because crossterm exposes `BackTab`, while some terminal stacks can preserve `Tab` with a shift modifier.

## Commits
- HEAD — fix: forward shift-tab to child terminals

## Progress
- 2026-05-16T09:30-0700 — Created `fix/tui-shift-tab-input` worktree from local `main` to keep the narrow TUI input fix isolated from unrelated main-checkout files.
- 2026-05-16T09:30-0700 — Found that `key_to_input` forwarded plain `Tab` but had no reverse-tab mapping for crossterm `BackTab`.
- 2026-05-16T09:31-0700 — Validation passed: `cargo fmt --all -- --check` and `cargo test -p argus-tui shift_tab_is_forwarded_as_reverse_tab`.
- 2026-05-16T09:32-0700 — Full package validation passed: `cargo test -p argus-tui`.

## Next Steps
- Commit and push if this should go to review.
