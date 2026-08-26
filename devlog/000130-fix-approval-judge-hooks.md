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
- **2026-08-26T01:31-0700** Added `self:<cmd>` and `subagent:<cmd>` colon prefixes directly to `add_command_override` in `crates/triage-hook/src/main.rs`, enabling subagent-initiated commands in Antigravity to match subagent permission grants without modal prompting.
- **2026-08-26T01:39-0700** Added `./` path prefix stripping and program base override emission (`./gradlew ktfmtFormat` -> `gradlew ktfmtFormat`, `./gradlew`, `gradlew`) in `crates/triage-hook/src/main.rs`, ensuring relative executable scripts match permission overrides regardless of whether the agent matches against the full relative path or the base binary.
- **2026-08-26T01:43-0700** Fixed agent format detection in `crates/triage-hook/src/main.rs` to default to strict `Antigravity` format (emitting top-level `decision` and `permissionOverrides` without unknown `hookSpecificOutput` fields) unless explicitly in a Claude Code environment (`CLAUDE_CODE_VERSION` / `CLAUDE_PROJECT_DIR` / `--format=claude`).

## Decisions

- **Multi-prefix command permission overrides**: `triage-hook` emits overrides with `Bash(...)`, `run_command(...)`, `command(...)`, `self:Bash(...)`, `subagent:Bash(...)`, and `{req.tool_name}(...)` so agent runners (Claude Code, Antigravity, subagents, custom runners) match against their expected tool names without manual approval modals.
- **Gradle in builtin allowlist**: Added `./gradlew`, `gradlew`, and `gradle` to `BUILTIN_ALLOW_COMMANDS` to fast-path standard builds, test suites, and formatting checks without requiring custom config overrides.
- **Canonical Session ID Routing in Web Client**: Switched web terminal input and resize handlers to use `session.remoteSessionId` instead of splitting `session.title` by `" / "` so sessions with custom or single-word titles reliably deliver keystrokes over WebSockets.
- **Unified Permission Override Serialization**: Computed and emitted `permissionOverrides` on all hook responses regardless of detected agent format so lifecycle hooks delivering `hook_event_name` never drop permission grants for Antigravity or nested agents.
- **Positional CLI Subcommand Matching**: Replaced naive array index matching with `extract_positional_tokens` so global flags (e.g. `--locked`, `--offline`, `-C <dir>`, `--repo <repo>`, `-d <device>`, `--silent`) inserted between CLI executables and their subcommands match their intended allow rules without fragility.
- **Relative Path Prefix Stripping**: Handled `./` path stripping in `add_command_override` to emit both `./script.sh` and `script.sh` permission tokens, allowing runners to match against either form seamlessly.
- **Strict Antigravity Response Schema**: Preserved clean `AntigravityResponse` schema (`decision` + `permissionOverrides`) to prevent protojson deserialization failures from extraneous fields.

## Commits

- ae806fd — fix(judge,hook): expand read-only tools, add gradlew allowlist, and emit tool-specific permission overrides
- 26af621 — fix(hook): add subagent permission override prefixes for self and nested runners
- 06e167c — refactor(hook,judge): add plural tool aliases, use static prefix slices, and deduplicate overrides
- 4fde2f2 — fix(client): route web client terminal input using canonical remote session ID
- 94face4 — fix(hook): emit permission overrides across all detected agent formats
- fef8c37 — fix(hook): emit bare command strings and global flag git prefixes in permission overrides
- 668073d — fix(judge): robust positional CLI flag parsing and token normalization across all CLI tools
- 7928ae4 — fix(hook): emit self and subagent colon prefixes for allowed command tokens
- 4c7a994 — fix(hook): emit path-stripped and program base overrides for relative executable paths
- HEAD — fix(hook): preserve strict Antigravity response schema and prevent misclassification
