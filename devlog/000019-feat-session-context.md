# feat/session-context

## Agent
- Codex

## Intent
- Add daemon-owned session context metadata so local clients can show where each session belongs before the attention-routing work lands.
- Keep the first slice focused on cwd, git repository root, branch, and worktree without adding classification or notification behavior.

## Decisions
- Store context on `SessionSnapshot` so all transports inherit the same metadata surface.
- Derive git context from the daemon-observed current working directory instead of making the TUI run its own repository discovery.
- Keep sidebar rows fixed-height per session: non-selected long values are compacted, while the selected session scrolls overflowing repo/branch text horizontally inside the same row.

## What Changed
- Added shared `SessionContext` metadata to session snapshots.
- Resolved git repository/worktree/branch context in the daemon from the current working directory observed through OSC 7.
- Rendered cwd/repo and branch context in the TUI sidebar without enabling paragraph wrapping.
- Added selected-session horizontal scrolling for overflowing sidebar context text.
- Boxed large wire/actor enum variants after snapshot metadata increased enum size.
- Added daemon and TUI regression coverage for git context discovery, non-git sessions, sidebar context rows, and selected-row scrolling.

## Commits
- HEAD — feat: add session context metadata

## Progress
- 2026-05-16T18:45-0700 — Created `feat/session-context` worktree from `origin/main`, unset branch upstream, and inspected the core session API, daemon session actor, and TUI sidebar surfaces.
- 2026-05-16T19:04-0700 — Implemented daemon-owned git context metadata and TUI sidebar rendering. Adjusted the UI to keep fixed-height session rows, compact non-selected long names, and horizontally scroll overflowing repo/branch text only on the selected session.
- 2026-05-16T19:04-0700 — Validation passed: `cargo fmt --all -- --check`, `cargo check --workspace`, `cargo clippy --all-targets --all-features -- -D warnings`, and `/home/dberrios/.cargo/bin/cargo test --workspace`.

## Next Steps
- Push the branch and open a PR.
