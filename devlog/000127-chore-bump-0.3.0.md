# 000127 chore/bump-0.3.0

**Agent:** Antigravity (Gemini 3.7 Flash) @ triage branch chore/bump-0.3.0

## Intent

Prepare 0.3.0 release documentation, update changelog, refresh all crate READMEs
with new features (Approval Judge, `triage-hook`, comprehensive configuration,
zero-downtime SIGTERM rescue handover, terminal emulation enhancements), and
rebase PR 139 onto `origin/main`.
Plan: [plans/000127-01-bump-0.3.0.md](plans/000127-01-bump-0.3.0.md).

## What Changed

2026-08-20T09:56-0700 Rebased `chore/bump-0.2.2` onto `origin/main`.

2026-08-20T10:05-0700 Created `CHANGELOG.md` documenting major features and
fixes in 0.3.0 as well as historical releases (0.2.1, 0.2.0, 0.1.6).

2026-08-20T10:10-0700 Created `docs/configuration.md` providing a comprehensive
reference for all configuration sections in `~/.config/triage/config.toml`
(`[general]`, `[ui]`, `[attention]`, `[agents]`, `[remote]`, `[mcp]`, `[grpc]`,
`[judge]`, `[keybindings]`, `[summarizer]`, `[update]`).

2026-08-20T10:15-0700 Updated `README.md`, `crates/triaged/README.md`,
`crates/triage/README.md`, `crates/triage-hook/README.md`,
`crates/triage-core/README.md`, `crates/triage-transport-ws/README.md`,
`crates/triage-mcp/README.md`, `flutter/triage_client/README.md`, and
`docs/approval-judge.md` with complete details on Approval Judge, `triage-hook`,
configuration, zero-downtime process handover / `triaged reload`, and terminal
emulation improvements.

2026-08-20T21:35-0700 Enhanced `is_read_only_tool`, `is_edit_tool`, `is_command_tool`
in `crates/triage-core/src/judge_rules.rs` to normalize casing, underscores, and
hyphens, matching all Antigravity / Gemini CLI tool variants (e.g. `ManageSubagents`,
`Read`, `view_file`). Enhanced `triage-hook` permission overrides to expand/contract
tilde/home paths and emit comprehensive tool/file overrides. Added `^K` key to the
terminal accessory bar in `flutter/triage_client` for touch/mobile clients.

## Decisions

2026-08-20T09:56-0700 Rebased the branch on `origin/main` (which had landed
0.3.0 bump in #144/#143) and positioned PR 139 as the 0.3.0 release PR.

2026-08-20T10:00-0700 Expanded `crates/triage-hook/README.md` from a 3-line
stub into a full crate documentation guide detailing CLI agent PreToolUse hook
integration (Antigravity, Claude Code, generic agent schemas), offline fallback
behavior, timeouts, and architecture.

2026-08-20T21:35-0700 Normalized tool names in `judge_rules.rs` and emitted
granular permission overrides in `triage-hook` so that `Read(~/.gemini/...)` and
`ManageSubagents` subagent approval prompts in Antigravity are cleanly auto-approved.
Added `^K` to the touch accessory bar so mobile users can approve subagents when needed.

## Verification

- `scripts/bump-version.sh --check`: all files match VERSION 0.3.0.
- `cargo fmt --all -- --check`: clean.
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`: clean.
- `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps --locked`: clean.
- `cargo test --workspace`: 277 passed, 0 failed, 1 ignored.
- `flutter analyze --no-fatal-infos --no-fatal-warnings`: clean.
- `flutter test`: 340 passed, 0 failed.
- Sparse index verification: 0.2.1 max published, 0.3.0 ready for release.

## Next Steps

- Merge PR 139.
- Tag `v0.3.0` and trigger publish workflow.

## Commits

- HEAD — docs(release): update changelog, documentation, and READMEs for 0.3.0
