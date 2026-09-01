# 000132 — Fix Approval Judge Allowlist, Handover Preservation & Review Workflow

## Agent

Antigravity

## Intent

Expand the built-in deterministic approval judge allowlist for safe developer/testing tools (`rustfmt`, `rustc`, `mktemp`, `git init`, `git clone`, `git config`, task output inspection), preserve `judge_history` across zero-downtime daemon handover so dashboard analytics remain accurate across daemon upgrades, and configure the GitHub Actions Antigravity code review workflow like Cera (supporting `@antigravity` tags, PR review comments, dynamic effort levels, and the `needs antigravity review` label).

## What Changed

- `crates/triage-core/src/judge_rules.rs`:
  - Added background task inspection tools (`task_output`, `get_task_output`) to `is_read_only_tool`.
  - Added `rustfmt`, `rustc`, and `mktemp` to `BUILTIN_ALLOW_COMMANDS`.
  - Hardened `git init`, `git clone`, and `git config` allow rules against hook injection (`--template`, `--separate-git-dir`, short flag `-u`), configuration execution tampering (`core.sshCommand`, `core.pager`, `core.editor`, `core.fsmonitor`, `core.hooksPath`, `core.gitproxy`, `pager.*`, `filter.*`, non-empty `credential.*.helper`), and global/file-level mutations (`--global`, `--system`, `--file`, `-f`, `--blob`).
  - Refactored `sanitize_command_substitutions` to use UTF-8 slice boundaries and eliminate multi-byte character corruption.
  - Added comprehensive positive and negative test coverage for safe and dangerous developer commands.
- `crates/triaged/src/handover.rs` & `crates/triaged/src/session.rs`:
  - Added `judge_history` to `HandoverState` with `#[serde(default)]`.
  - Implemented `merge_inherited_judge_history` with bounded capacity ring buffer enforcement (`JUDGE_HISTORY_CAPACITY = 2000`) and chronological ordering preservation across predecessor and successor records.
  - Wired `judge_history` adoption in `queue_handover_adoptions`, `adopt_sessions`, and `compact_recovery_snapshot`.
  - Added unit test `handover_preserves_judge_history` validating adoption ordering, capacity management, and temporary log directory cleanup.
- `.github/workflows/code-review.yml` & `scripts/format_review_comment.py`:
  - Replaced legacy script-based review workflow with Cera-aligned Gemini CLI workflow using `google-github-actions/run-gemini-cli@v0.1.22`.
  - Added support for trigger types: PR opened/synchronize/labeled (`needs antigravity review`), issue/PR comments mentioning `@antigravity` (with optional effort specifier `low|medium|high|max`), and PR review comments.
  - Added `scripts/format_review_comment.py` to handle upserting/patching review comments, timezone-aware timestamping, UTF-16 surrogate handling (`errors='replace'`), and output sanitization.

- `crates/triage-hook/src/main.rs`:
  - Added `extract_agent_name` to parse calling agent and subagent names (`subagent`, `agent`, `role`, `sender`, `source`) from nested hook payloads.
  - Implemented `generate_tool_casing_variants` and `generate_agent_prefixes` to generate PascalCase, camelCase, snake_case, flat lowercase, and synonym tool names across bare, `self:`, `subagent:`, and `${agent}:` prefixes.
  - Updated `compute_permission_overrides` and `encode_response` to emit complete multi-casing and subagent-scoped permission override tokens (e.g. `ListDir(...)`, `research:ListDir(...)`, `subagent:ListDir(...)`).
  - Added unit test coverage for subagent tool execution with PascalCase tool calls.
- `.github/workflows/code-review.yml`:
  - Fixed action input key name from `model` to `gemini_model` for `google-github-actions/run-gemini-cli@v0.1.22`.

## Decisions

- Background task inspection tools (`task_output`, `get_task_output`) are read-only and safe to auto-approve.
- Verification and build tools (`rustfmt`, `rustc`, `mktemp`) are included in `BUILTIN_ALLOW_COMMANDS` so multi-command test chains evaluate deterministically in Layer 1.
- `git config`, `git clone`, and `git init` must strictly guard against hook and subprocess injection (`--template`, `--separate-git-dir`, `-u`, executable keys).
- `judge_history` is serialized into `HandoverState` and merged in chronological order respecting ring buffer limits, preserving the audit trail across zero-downtime reloads.
- Antigravity review workflow is unified with Cera's architecture, providing interactive `@antigravity` PR comment triggers and dynamic effort configuration.
- Agent hook permission overrides must cover all naming conventions (PascalCase, camelCase, snake_case) and subagent namespaces (`${agent}:${tool}`) to ensure seamless execution in agent permission evaluators.

## Commits

- 85134db — feat(judge): expand developer tool allowlist, preserve history across handover, and configure review workflow
- 7e76de9 — fix(judge): harden git subcommands, preserve handover history chronology, and sanitize review comments
- caa2243 — fix(ci): wire ANTIGRAVITY_API_KEY secret and model parameter for code review workflow
- 598d1d8 — refactor(session): optimize judge history ring buffer merge and clarify git rule invariants
- f654abb — fix(hook): emit subagent and multi-casing permission overrides in approval judge hook
- HEAD — fix(ci): update code review workflow model to gemini-3.7-flash

