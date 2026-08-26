# Plan: Fix Approval Judge Tool Recognition and Hook Permission Overrides

## Thinking

Recent real-world testing of the approval judge revealed three sources of false prompts on safe operations:

1. **Tool-Specific Permission Overrides in `triage-hook`**:
   `triage-hook` generates `permissionOverrides` for Antigravity and agent runners upon an `allow` verdict. However, it previously emitted command overrides with a hardcoded `command(...)` format (e.g. `command(git show --stat bd9f3cb)`), while Antigravity and Claude Code tool runners match permissions against the specific tool name invoked (e.g. `Bash(git show --stat bd9f3cb)` or `run_command(...)`). Consequently, despite the daemon returning `decision: "allow"`, the agent's permission matcher failed to find a matching override and fell back to prompting the user.

2. **Unregistered Read-Only Tools in `is_read_only_tool()`**:
   Antigravity and Claude Code agent tools such as `schedule` (timers/cron), `manage_task` (background tasks), `websearch`/`webfetch`, `toolsearch`, `skill`, `artifact`, and `askuserquestion` were not present in `is_read_only_tool()`. Unrecognized tools fall through to `"tool <name> is not judged"` with `JudgeDecision::Ask`.

3. **Builtin Allowlist Expansion for Build Tools**:
   Common build/test scripts like `./gradlew`, `gradlew`, and `gradle` (e.g. `./gradlew test`, `./gradlew build`, `./gradlew ktfmtCheck`) were missing from `BUILTIN_ALLOW_COMMANDS`. Furthermore, leading environment variables like `ANDROID_HOME=...` are stripped by `effective_tokens()`, which caused configured custom rules containing `ANDROID_HOME=... ./gradlew` not to match the stripped effective command.

## Plan

1. **Update `is_read_only_tool()` in `crates/triage-core/src/judge_rules.rs`**:
   - Add `schedule`, `manage_task`, `managetask`, `task_stop`, `taskstop`, `websearch`, `web_fetch`, `webfetch`, `read_url`, `toolsearch`, `tool_search`, `skill`, `artifact`, `ask_user_question`, `askuserquestion`.

2. **Update `BUILTIN_ALLOW_COMMANDS` in `crates/triage-core/src/judge_rules.rs`**:
   - Add `./gradlew`, `gradlew`, `gradle`.

3. **Enhance `permission_overrides` generation in `crates/triage-hook/src/main.rs`**:
   - For command tools, emit overrides with prefixes:
     - `${req.tool_name}(...)`
     - `Bash(...)`
     - `run_command(...)`
     - `command(...)`
   - Include subcommands (`git {subcommand}`) and 2-word prefixes for each tool name variant.

4. **Update and add unit tests**:
   - Test tool recognition in `crates/triage-core/src/judge_rules.rs`.
   - Test `./gradlew` execution with and without leading environment variables.
   - Test `permission_overrides` in `crates/triage-hook/src/main.rs` confirming `Bash(...)`, `run_command(...)`, and `command(...)` are present.

5. **Update user config `~/.config/triage/config.toml`**:
   - Clean up `allow_commands` with normalized entries.

6. **Validate, Build, Install, and Reload**:
   - Run `cargo fmt --all -- --check`, `cargo clippy`, `cargo test`.
   - Install binaries via `scripts/install.sh`.
   - Reload daemon via `triaged reload`.
   - Update branch devlog and commit following Conventional Commits.
