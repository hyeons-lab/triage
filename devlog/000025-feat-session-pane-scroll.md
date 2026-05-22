# feat/session-pane-scroll

## Agent

- Codex

## Intent

- Keep the TUI sessions pane usable when the session list grows beyond the sidebar height.

## What Changed

- The TUI sidebar now derives a visible row window before rendering session rows.
- The sidebar window keeps the selected session's row group visible when the total session list is taller than the pane.
- Added regression coverage for selecting a session below the original sidebar viewport and for viewport-start edge cases.

## Decisions

- 2026-05-21T07:26-0700: Fix the existing sidebar rendering path by keeping the selected session visible in the rendered row window, rather than adding a separate scroll mode.

## Progress

- 2026-05-21T07:26-0700: Created `fix/session-pane-scroll` worktree and started the TUI sidebar investigation.
- 2026-05-21T07:30-0700: Implemented selected-session sidebar windowing and validated it with focused and full `argus-tui` tests plus format checking.
- 2026-05-21T07:31-0700: Ran `cargo clippy -p argus-tui --all-targets -- -D warnings`; no warnings.
- 2026-05-21T23:11-0700: Renamed the branch to `feat/session-pane-scroll`, rebased onto `origin/main`, and kept both the new sidebar context overflow tests and the session-list viewport tests after conflict resolution.

## Commits

- HEAD — feat(tui): keep selected sessions visible

## Next Steps

- Push `feat/session-pane-scroll`.
