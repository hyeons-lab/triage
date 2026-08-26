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
- **2026-08-26T00:35-0700** Addressed PR review refinements: added plural/inverted aliases (`manage_tasks`, `managetasks`, `stop_task`, `stoptask`) to `is_read_only_tool()`, switched `tool_prefixes` to a static slice to eliminate per-call heap allocations, and used `HashSet::retain` for fast order-preserving deduplication of permission overrides.
- **2026-08-26T01:08-0700** Fixed remote session ID resolution in `flutter/triage_client/lib/main.dart` to use `session.remoteSessionId` across `writeInput`, `resizeSession`, and `_sessionIdFor` rather than string splitting `session.title`, preventing dropped keystrokes on sessions without slash delimiters.
- **2026-08-26T01:14-0700** Unified `permissionOverrides` generation in `crates/triage-hook/src/main.rs` across all detected agent formats (`Antigravity`, `ClaudeCode`, `Generic`), ensuring hooks carrying `hook_event_name` (e.g. from lifecycle configs) always receive full permission overrides alongside `hookSpecificOutput`.
- **2026-08-26T01:19-0700** Added bare command string overrides and global-flag git prefix extraction (`git --no-pager diff`) in `crates/triage-hook/src/main.rs`, ensuring commands like `git --no-pager diff --stat` match against all permutation tokens without manual prompting.

## Decisions

- **Multi-prefix command permission overrides**: `triage-hook` emits overrides with `Bash(...)`, `run_command(...)`, `command(...)`, `self:Bash(...)`, `subagent:Bash(...)`, and `{req.tool_name}(...)` so agent runners (Claude Code, Antigravity, subagents, custom runners) match against their expected tool names without manual approval modals.
- **Gradle in builtin allowlist**: Added `./gradlew`, `gradlew`, and `gradle` to `BUILTIN_ALLOW_COMMANDS` to fast-path standard builds, test suites, and formatting checks without requiring custom config overrides.
- **Canonical Session ID Routing in Web Client**: Switched web terminal input and resize handlers to use `session.remoteSessionId` instead of splitting `session.title` by `" / "` so sessions with custom or single-word titles reliably deliver keystrokes over WebSockets.
- **Unified Permission Override Serialization**: Computed and emitted `permissionOverrides` on all hook responses regardless of detected agent format so lifecycle hooks delivering `hook_event_name` never drop permission grants for Antigravity or nested agents.

## Commits

- ae806fd — fix(judge,hook): expand read-only tools, add gradlew allowlist, and emit tool-specific permission overrides
- 26af621 — fix(hook): add subagent permission override prefixes for self and nested runners
- 06e167c — refactor(hook,judge): add plural tool aliases, use static prefix slices, and deduplicate overrides
- 4fde2f2 — fix(client): route web client terminal input using canonical remote session ID
- 94face4 — fix(hook): emit permission overrides across all detected agent formats
- HEAD — fix(hook): emit bare command strings and global flag git prefixes in permission overrides
