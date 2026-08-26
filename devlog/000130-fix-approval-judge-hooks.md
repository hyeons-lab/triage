# 000130 — Fix approval judge tool recognition and hook permission overrides

- **Agent:** Antigravity
- **Intent:** Eliminate false approval prompts for safe agent operations by expanding read-only tool classification, registering Gradle build commands in the builtin allowlist, and emitting tool-specific permission overrides (`Bash(...)`, `run_command(...)`, `command(...)`) in `triage-hook`.

## What Changed

- **2026-08-26T00:05-0700** Branch created and plan initialized (`devlog/plans/000130-01-approval-judge-hooks.md`).
- **2026-08-26T00:10-0700** Expanded `is_read_only_tool()` in `crates/triage-core/src/judge_rules.rs` to include `schedule`, `manage_task`, `managetask`, `task_stop`, `taskstop`, `websearch`, `web_fetch`, `webfetch`, `read_url`, `tool_search`, `toolsearch`, `skill`, `artifact`, `ask_user_question`, and `askuserquestion`.
- **2026-08-26T00:10-0700** Added `./gradlew`, `gradlew`, and `gradle` to `BUILTIN_ALLOW_COMMANDS` in `crates/triage-core/src/judge_rules.rs`.
- **2026-08-26T00:10-0700** Updated `encode_response()` in `crates/triage-hook/src/main.rs` to generate multi-prefix permission overrides for commands across `Bash(...)`, `run_command(...)`, `command(...)`, and `{req.tool_name}(...)`.
- **2026-08-26T00:11-0700** Added unit tests in `triage-core` and `triage-hook` validating tool recognition, Gradle execution with environment variables, and multi-prefix permission override serialization.
- **2026-08-26T00:13-0700** Rebuilt and installed release binaries via `scripts/install.sh`, successfully reloaded live daemon with zero downtime preserving 31 active sessions.
- **2026-08-26T00:22-0700** Added subagent-scoped permission override prefixes (`self:Bash`, `self:run_command`, `subagent:Bash`, `self`, etc.) in `crates/triage-hook/src/main.rs` so subagents invoked via `invoke_subagent(TypeName="self")` match permission overrides without prompting.

## Decisions

- **Multi-prefix command permission overrides**: `triage-hook` emits overrides with `Bash(...)`, `run_command(...)`, `command(...)`, `self:Bash(...)`, `subagent:Bash(...)`, and `{req.tool_name}(...)` so agent runners (Claude Code, Antigravity, subagents, custom runners) match against their expected tool names without manual approval modals.
- **Gradle in builtin allowlist**: Added `./gradlew`, `gradlew`, and `gradle` to `BUILTIN_ALLOW_COMMANDS` to fast-path standard builds, test suites, and formatting checks without requiring custom config overrides.

## Commits

- ae806fd — fix(judge,hook): expand read-only tools, add gradlew allowlist, and emit tool-specific permission overrides
- HEAD — fix(hook): add subagent permission override prefixes for self and nested runners
