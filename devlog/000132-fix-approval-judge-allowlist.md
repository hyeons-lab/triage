# 000132 — Fix Approval Judge Allowlist, Handover Preservation & Review Workflow

## Agent

Antigravity

## Intent

Expand the built-in deterministic approval judge allowlist for safe developer/testing tools (`rustfmt`, `rustc`, `mktemp`, `git init`, `git clone`, `git config`, task output inspection), preserve `judge_history` across zero-downtime daemon handover so dashboard analytics remain accurate across daemon upgrades, and configure the GitHub Actions Antigravity code review workflow like Cera (supporting `@antigravity` tags, PR review comments, dynamic effort levels, and the `needs antigravity review` label).

## What Changed

- `crates/triage-core/src/judge_rules.rs`:
  - Added background task inspection tools (`task_output`, `get_task_output`) to `is_read_only_tool`.
  - Added `rustfmt`, `rustc`, and `mktemp` (`mktemp`, `mktemp -d`, `mktemp -u`, `mktemp -t`) to `BUILTIN_ALLOW_COMMANDS`.
  - Added `git init`, `git clone`, and `git config` to `BUILTIN_ALLOW_COMMANDS` and `matching_git_allow_rule`.
  - Added comprehensive test coverage for developer tools and task tools allow evaluation.
- `crates/triaged/src/handover.rs` & `crates/triaged/src/session.rs`:
  - Added `judge_history` to `HandoverState` with `#[serde(default)]`.
  - Transferred and adopted `judge_history` across zero-downtime handover so that `triaged reload` retains the decision history ring buffer and traffic metrics.
  - Added unit test `handover_preserves_judge_history`.
- `.github/workflows/code-review.yml` & `scripts/format_review_comment.py`:
  - Replaced legacy script-based review workflow with Cera-aligned Gemini CLI workflow using `google-github-actions/run-gemini-cli@v0.1.22`.
  - Added support for trigger types: PR opened/synchronize/labeled (`needs antigravity review`), issue/PR comments mentioning `@antigravity` (with optional effort specifier `low|medium|high|max`), and PR review comments.
  - Added `scripts/format_review_comment.py` to handle upserting/patching review comments, timezone-aware timestamping, and output sanitization.

## Decisions

- Background task inspection tools (`task_output`, `get_task_output`) are read-only and safe to auto-approve.
- Verification and build tools (`rustfmt`, `rustc`, `mktemp`) are included in `BUILTIN_ALLOW_COMMANDS` so multi-command test chains evaluate deterministically in Layer 1.
- `judge_history` is serialized into `HandoverState` and adopted by the new daemon instance, preserving the audit trail across zero-downtime reloads.
- Antigravity review workflow is unified with Cera's architecture, providing interactive `@antigravity` PR comment triggers and dynamic effort configuration.

## Commits

- HEAD — feat(judge): expand developer tool allowlist, preserve history across handover, and configure review workflow

