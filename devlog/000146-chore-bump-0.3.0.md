# 000146 chore/bump-0.3.0

**Agent:** Antigravity (Gemini 3.7 Flash) @ triage branch chore/bump-0.3.0
**Agent (2026-09-11T14:22-0400):** Antigravity (Gemini 3.8 Flash) @ triage branch chore/bump-0.3.0

## Intent

Prepare 0.3.0 release documentation, update changelog, refresh all crate READMEs
with new features (Approval Judge, `triage-hook`, comprehensive configuration,
zero-downtime SIGTERM rescue handover, terminal emulation enhancements), and
rebase PR 146 onto `origin/main`.
Plan: [plans/000146-01-bump-0.3.0.md](plans/000146-01-bump-0.3.0.md).

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

2026-09-11T14:20-0400 Rebased `chore/bump-0.3.0` onto `origin/main` (commit `3113e92`).
Resolved merge conflicts in `crates/triage-core/src/judge_rules.rs` (preserving case-insensitive
matching, command action checks, and test coverage) and `crates/triage-hook/src/main.rs`
(preserving HEAD 5-argument response encoding and updated test assertions).

2026-09-11T14:22-0400 Renumbered devlog and plan to 000146 to resolve sequence collision
with 000127 on main. Removed em dashes across READMEs and devlog.

2026-09-11T14:25-0400 Addressed PR 146 review comments: corrected TUI keybinding references
in `docs/configuration.md`, `CHANGELOG.md`, and plan from `a` to `F5` overlay; optimized tool
classification in `crates/triage-core/src/judge_rules.rs` to eliminate heap allocations in
matching loops; and added unit tests for Windows-style tilde paths and stringified escaped
JSON arguments in `crates/triage-hook/src/main.rs`.

2026-09-11T14:53-0400 Corrected Windows config.toml path in `docs/configuration.md` to remove
inaccurate `%APPDATA%` alternative and match `Config::default_path()`.

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

2026-09-11T14:20-0400 Merged conflict resolutions from `origin/main` #168 into the 0.3.0
release branch to keep judge rules and hook signatures aligned.

2026-09-11T14:22-0400 Renumbered devlog from 000127 to 000146 following repository conventions
after rebasing onto main.

2026-09-11T14:25-0400 Addressed review feedback on PR 146: aligned configuration and release
documentation with actual TUI F5 overlay keybindings, and replaced heap-allocating string
replacements in tool classifiers with stack-allocated byte iterator comparisons.

2026-09-11T14:53-0400 Dropped inaccurate `%APPDATA%\triage\config.toml` path alternative from
Windows configuration documentation to match `Config::default_path()`.

## Verification

- `scripts/bump-version.sh --check`: all files match VERSION 0.3.0.
- `cargo fmt --all -- --check`: clean.
- `cargo clippy --all-targets --all-features -- -D warnings`: clean.
- `cargo test --workspace`: 328 passed, 0 failed, 1 ignored.

## Next Steps

- Merge PR 146.
- Tag `v0.3.0` and trigger publish workflow.

## Commits

- HEAD: docs(release): update changelog, documentation, and READMEs for 0.3.0
