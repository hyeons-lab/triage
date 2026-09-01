# 000132-01 — Approval Judge Allowlist Expansion & Handover Preservation

## Thinking

1. When running AI agents with PreToolUse hooks, certain routine and safe operations were falling back to `decision: "ask"`:
   - `task_stop`, `task_cancel`, `cancel_task`, `kill_task`: `manage_task(Action="kill"|"stop")` gets normalized to `task_stop`, but `task_stop` was not in `is_read_only_tool` or `is_command_tool`, causing a fallback `ask`.
   - `rustfmt`: `cargo fmt` is in `BUILTIN_ALLOW_COMMANDS`, but raw `rustfmt` (e.g. `rustfmt --edition 2024 --check ...`) was missing. In a chain with `&&`, any unlisted command forces the entire chain to model evaluation or fallback `ask`.
   - `rustc`: `rustc --version` was allowed, but running `rustc` on a file in scratch/test was unlisted.
   - `mktemp`: `mktemp -d` / `mktemp` in subshell substitutions `$(mktemp -d)` was unlisted, causing subshell evaluation to fail allow rules.
   - `git init`, `git clone`, `git config`: Safe git setup commands were missing from `matching_git_allow_rule` and `BUILTIN_ALLOW_COMMANDS`.
2. Judge history was not preserved across zero-downtime daemon handover (`triaged reload`), causing the settings dashboard and list to lose prior decisions and display 100% auto-approved based only on post-reload traffic.
3. Solution:
   - In `crates/triage-core/src/judge_rules.rs`:
     - Add `task_stop`, `task_cancel`, `cancel_task`, `kill_task`, `task_kill`, `task_output`, `get_task_output` to `is_read_only_tool`.
     - Add `rustfmt`, `rustc`, `mktemp` to `BUILTIN_ALLOW_COMMANDS`.
     - Add `git init`, `git clone`, `git config` to `BUILTIN_ALLOW_COMMANDS` and `matching_git_allow_rule`.
   - In `crates/triaged/src/session.rs` and `crates/triaged/src/ipc.rs`:
     - Serialize and transfer `judge_history` during zero-downtime handover so daemon reloads preserve the audit trail and accurate dashboard analytics.
   - Add unit tests verifying `task_stop`, `mktemp`, `rustfmt`, `git init`, `git clone`, and `judge_history` handover serialization.

## Plan

1. Update `crates/triage-core/src/judge_rules.rs`:
   - Expand `is_read_only_tool` with task lifecycle tools (`task_stop`, `task_cancel`, `cancel_task`, etc.).
   - Expand `BUILTIN_ALLOW_COMMANDS` with `rustfmt`, `rustc`, `mktemp`, `git init`, `git clone`, `git config`.
   - Expand `matching_git_allow_rule` to support `git init`, `git clone`, `git config` (read-only and safe local config).
2. Update `crates/triaged/src/session.rs` and `crates/triaged/src/ipc.rs`:
   - Include `judge_history` in `HandoverState` / handover serialization.
3. Validate:
   - Run `cargo fmt --all -- --check`
   - Run `cargo clippy --all-targets --all-features -- -D warnings`
   - Run `cargo test --workspace`
4. Update devlog, commit locally, build, install, and reload daemon.
