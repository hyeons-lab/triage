# fix/input-background-bleed

## Agent

Codex

## Intent

Stop styled terminal row backgrounds from bleeding into cells that should use the terminal default background, including the selected-row render path.

## What Changed

- Added regression coverage for selected styled rows with a trailing background style.
- Verified the selected-row render path keeps the line-wide background unset while preserving the explicit padded trailing span background.

## Decisions

- Kept the follow-up scoped to test coverage because the current production path already routes selected-row trailing cells through explicit spans.

## Commits

- b35997b — fix: stop trailing cell background bleeding across styled rows
- HEAD — test: cover selected row trailing background

## Progress

- 2026-05-16T14:20-0700: Addressed the live PR review thread requesting selected-row regression coverage.

## Research & Discoveries

- PR #23 had one unresolved non-outdated review thread on `crates/argus-tui/src/main.rs` asking for active-selection coverage of trailing background padding.

## Next Steps

- Push the branch update and let CI validate the review follow-up.
