# Devlog 000192: fix/tui-side-rail

**Agent:** Antigravity @ triage branch `fix/tui-side-rail`

## Intent

Replace noisy, repetitive entries in the Ratatui TUI side rail (`session-NN * running`, `interactive NxM`, `c system32`, and blank placeholder context lines) with useful per-session identity and activity information sourced from `custom_labels`, git `context`, `agent`, `snippet`, `pending_approval`, and `exited` status.

## Progress

- [x] Create branch worktree `fix/tui-side-rail` off `feat/swarm-coordination-skill`, devlog, and plan
- [x] Sync `custom_label` and background session `snippet` updates in `crates/triage/src/lib.rs`
- [x] Redesign TUI side rail card layout and filtering in `crates/triage/src/main.rs`
- [x] Update and expand TUI unit tests and verify fmt/clippy/doc/tests

## What Changed

- `2026-11-16T19:19-0800 crates/triage/src/lib.rs`: Added `custom_label: Option<String>` to `SessionView`, loaded initial `custom_labels` from `get_rail_layout()` in `attach_existing_sessions`, added `spawn_rail_labels_poller` + `LocalSessionApp::refresh_rail_labels()` for non-blocking live custom-label refreshes in IPC mode, preserved `snippet` and `snippet_detail` across actor push snapshots in `merge_push_snapshot`, and added unit tests covering both paths.
- `2026-11-16T19:19-0800 crates/triage/src/main.rs`: Replaced `session_sidebar_rows` and `session_context_rows` with shared `sidebar_card_fields` formatting:
  - Prioritizes human-readable titles (`custom_label` -> distinct git worktree -> non-default branch -> repo -> meaningful non-system cwd leaf -> agent -> `session_id`) instead of `session-NN`.
  - Removes `running`, `interactive`/`observer`, `cols x rows`, empty placeholder context rows, single-letter `r`/`w`/`b`/`c` path prefixes, and emoji judge badges (using ASCII `[auto]` / `[ask]` only when an agent is active or an explicit override is set, avoiding `*` glyph fallback on Windows).
  - Suppresses bare roots and Windows system directories (`System32`, `SysWOW64`) via cross-platform path parsing (`meaningful_cwd_leaf`).
  - Renders deduplicated ` · `-separated meta (agent, repo, branch) and surfaces `pending_approval_reason` or LLM `snippet` lines with marquee horizontal scrolling on selected cards.

## Decisions

- `2026-11-16T19:19-0800 Decision`: Lead non-worktree `main` / `master` git sessions with the repository name rather than the branch name when a repo is present, keeping multiple repos visually distinct in the TUI rail while still promoting feature branches above the repo name.

## Commits

- `HEAD`: fix(triage): replace noisy TUI side rail placeholders with session identity and activity
