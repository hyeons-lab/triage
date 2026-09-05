# 000134-01: Support Meta Muse CLI in Triage Auto-Approval Judge

## Thinking

Meta Muse CLI (`muse`) is an interactive terminal coding agent. When run inside a Triage session, its routine tool calls should be auto-approved by Triage's local approval judge, with risky actions prompting the user, matching the supervision model established for Antigravity and Claude Code.

Reverse-engineering and live experimentation with the installed `muse` binary (`muse-bin-1.0.3-R2198.1`) revealed several key architectural facts:

1. **PreToolUse Hook Contract in Muse**:
   - Muse loads lifecycle hooks from `hooks` defined in `~/.config/muse/settings.json` (or `$XDG_CONFIG_HOME/muse/settings.json`), formatted identically to the Claude Code / Antigravity hook schema:
     ```json
     {
       "hooks": {
         "PreToolUse": [
           {
             "matcher": ".*",
             "hooks": [
               {
                 "type": "command",
                 "command": "/Users/dberrios/.cargo/bin/triage-hook",
                 "timeout": 15
               }
             ]
           }
         ]
       }
     }
     ```
   - Muse sends a PreToolUse payload on stdin containing `hook_event_name: "PreToolUse"`, `tool_name` (e.g. `bash`, `read_file`, `write_file`, `search`, `read_skill`), `tool_input` (e.g. `{"command": "..."}` for bash or `{"path": "..."}` for read_file), `tool_use_id`, `session_id`, `turn_id`, `model` (e.g. `muse-spark-1.3-contributor`), and `permission_mode`.
   - **Crucial Hook Output Constraint**:
     When approving a tool call (`permissionDecision: "allow"`), Muse requires `updatedInput` containing the tool input object. A bare allow is explicitly rejected with `PreToolUse permissionDecision: allow requires updatedInput; a bare allow is rejected`.
     When denying a tool call (`permissionDecision: "deny"`), Muse requires `permissionDecisionReason` with a non-empty explanation.
     When asking (`permissionDecision: "ask"` or empty stdout), Muse stops and prompts the user for manual approval.
   - Claude Code payloads do not have `turn_id` and do not enforce `updatedInput`. If Muse payloads are routed through Claude Code response encoding, Muse rejects the bare allow and fails the tool call.

2. **Tool Classification in `triage-core`**:
   - Muse uses:
     - `bash`: execution tool (already in `is_command_tool`)
     - `read_file`: inspection tool (already in `is_read_only_tool`)
     - `write_file`, `edit_file`: edit tools (already in `is_edit_tool`)
     - `read_skill`, `readskill`: reads a skill body, currently missing from `is_read_only_tool`
     - `search`: workspace symbol/content search, currently missing from `is_read_only_tool`
   - Muse CLI commands:
     - Add `muse` and `muse *` to `BUILTIN_ALLOW_COMMANDS`.
   - Sensitive credential paths:
     - Add `muse/auth.json` and `.config/muse/auth.json` to `CREDENTIAL_PATHS` so stored Meta credentials cannot be inspected by agents.

3. **Daemon Hook Provisioning in `triaged`**:
   - `get_hook_status`: inspect `~/.config/muse/settings.json` (or workspace settings) in addition to `.agents/hooks.json` and `.claude/settings.json`.
   - `configure_hook`: when enabling or disabling the approval judge, update `~/.config/muse/settings.json` (preserving all existing fields such as `schema_version`, `provider`, `model`, `tui`).
   - `install_global_agent_hooks()`: in `crates/triaged/src/service.rs` and `scripts/install.sh`, provision or update the hook in `~/.config/muse/settings.json` if `~/.config/muse` exists or `muse` is found on `PATH`.

4. **Documentation and Tests**:
   - Update `docs/approval-judge.md` with Muse configuration instructions.
   - Add comprehensive unit tests in `triage-core` and `triage-hook` covering:
     - Format detection for Muse.
     - Response serialization for Muse allow, deny, and ask verdicts including `updatedInput` preservation.
     - Tool classification for `read_skill` and `search`.
     - Credential path guard for `auth.json`.

## Plan

1. **Update `triage-core`**:
   - Add `"read_skill"`, `"readskill"`, and `"search"` to `is_read_only_tool` in `crates/triage-core/src/judge_rules.rs`.
   - Add `"muse"` and `"muse *"` to `BUILTIN_ALLOW_COMMANDS` in `crates/triage-core/src/judge_rules.rs`.
   - Add `".config/muse/auth.json"` and `"muse/auth.json"` to `CREDENTIAL_PATHS` in `crates/triage-core/src/judge_rules.rs`.
   - Add unit tests verifying these additions.

2. **Update `triage-hook`**:
   - Add `AgentFormat::Muse` to `AgentFormat` enum in `crates/triage-hook/src/main.rs`.
   - Update `detect_format` to recognize Muse via `--format=muse`, `TRIAGE_HOOK_FORMAT=muse`, presence of `turn_id`, presence of `permission_mode`, or model containing `muse`. Ensure this runs before the generic `hook_event_name` check.
   - Preserve raw `tool_input` (args) throughout `decide()` and pass it to `encode_response`.
   - In `encode_response`, add `AgentFormat::Muse` handling:
     - `Allow`: serialize `hookSpecificOutput` with `hookEventName: "PreToolUse"`, `permissionDecision: "allow"`, `permissionDecisionReason: reason`, and `updatedInput: tool_args`.
     - `Deny`: serialize `hookSpecificOutput` with `hookEventName: "PreToolUse"`, `permissionDecision: "deny"`, and `permissionDecisionReason: reason`.
     - `Ask`: return empty string `String::new()` so Muse falls back to native prompting.
   - Add unit tests for Muse format detection and response serialization.

3. **Update `triaged` Daemon and Service**:
   - In `crates/triaged/src/judge.rs`:
     - Add `resolve_muse_settings_path(workspace_path: Option<&str>) -> PathBuf`.
     - Update `get_hook_status` to check `muse_path`.
     - Update `configure_hook` to update `muse_path` if the config directory or binary exists, preserving existing settings.
   - In `crates/triaged/src/service.rs`:
     - In `install_global_agent_hooks()`, update or configure `~/.config/muse/settings.json` if `~/.config/muse` exists or `muse` is installed in `PATH`.

4. **Update `scripts/install.sh`**:
   - Add hook configuration logic for `~/.config/muse/settings.json` when `~/.config/muse` exists or `muse` is in `PATH`.

5. **Update Documentation**:
   - Update `docs/approval-judge.md` to document Meta Muse CLI hook integration.

6. **Validation**:
   - Run `cargo fmt --all -- --check`.
   - Run `cargo clippy --all-targets --all-features -- -D warnings`.
   - Run `cargo test --workspace`.
   - Live test with `triage-hook` and `muse exec`.
