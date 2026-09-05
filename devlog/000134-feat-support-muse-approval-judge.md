# 000134: Support Meta Muse CLI in Triage Auto-Approval Judge

- **Agent:** Antigravity (gemini-3-8-flash) @ triage branch feat/support-muse-approval-judge
- **Intent:** Support Meta Muse CLI in Triage auto approval judge across tool classification, hook serialization, and daemon configuration.

## What Changed

- **2026-09-04T17:38-0700** Initialized worktree and authored plan file (`devlog/plans/000134-01-support-muse-approval-judge.md`).
- **2026-09-04T17:51-0700** `crates/triage-core/src/judge_rules.rs`: Added `read_skill`, `readskill`, and `search` to `READ_ONLY_TOOLS`. Added `muse` and `muse *` to `BUILTIN_ALLOW_COMMANDS`. Added `.config/muse/auth.json` and `muse/auth.json` to `CREDENTIAL_PATHS`. Added unit test `tests_muse_tool_and_command_recognition`.
- **2026-09-04T17:51-0700** `crates/triage-hook/src/main.rs`: Added `AgentFormat::Muse`. Updated `detect_format` to prioritize Antigravity markers (`conversationId`, `stepIdx`, `toolCall`), followed by Claude Code (`transcript_path`), Muse (`turn_id`, `turnId`, `model` containing `muse`), and generic `hook_event_name`. Updated `encode_response` to accept `raw_args` and emit `updatedInput` on allow decisions for Muse and `permissionDecisionReason` on deny decisions. Updated `decide` to propagate tool input arguments. Added unit tests for Muse format detection and response serialization.
- **2026-09-04T17:51-0700** `crates/triaged/src/judge.rs`: Added `resolve_muse_settings_path`. Updated `get_hook_status` and `configure_hook` to detect and manage PreToolUse hooks in Muse `settings.json` while preserving existing configuration keys. Added unit test `configure_and_query_muse_hook_status`.
- **2026-09-04T17:51-0700** `crates/triaged/src/service.rs`: Updated `install_global_agent_hooks` to configure `~/.config/muse/settings.json` when the configuration directory exists.
- **2026-09-04T17:51-0700** `scripts/install.sh`: Added hook provisioning for `~/.config/muse/settings.json`.
- **2026-09-04T17:51-0700** `docs/approval-judge.md`: Added documentation for Meta Muse CLI hook configuration and payload conventions.
- **2026-09-04T19:28-0700** `devlog/plans/000134-01-support-muse-approval-judge.md`: Sanitized machine-specific personal filesystem paths to home-relative tilde paths (`~/.cargo/bin/triage-hook`).
- **2026-09-04T19:28-0700** `scripts/install.sh`: Hardened inline Python configuration to defensively normalize non-dict `hooks` and non-list `PreToolUse` entries in Muse settings before appending hooks.
- **2026-09-04T19:28-0700** `crates/triaged/src/judge.rs`: Exported `pub fn resolve_muse_settings_path` for reuse across the crate, and added unit test `configure_hook_handles_malformed_muse_settings` verifying safe recovery and normalization from malformed settings files.
- **2026-09-04T19:28-0700** `crates/triaged/src/service.rs`: Replaced duplicated path resolution with `crate::judge::resolve_muse_settings_path(None)`, and added `muse_cli_available()` PATH and `~/.local/bin/muse` probing to ensure lifecycle hooks are provisioned upon daemon launch even before `~/.config/muse/` exists.

## Decisions

- **2026-09-04T17:38-0700 Muse PreToolUse response encoding**: Muse requires `updatedInput` on `allow` decisions (`PreToolUse permissionDecision: allow requires updatedInput; a bare allow is rejected`) and `permissionDecisionReason` on `deny` decisions. On `ask`, emitting an empty response lets Muse fall back to native terminal prompting without crashing or bypassing security.
- **2026-09-04T17:49-0700 Format detection order**: Antigravity payload markers (`conversationId`, `stepIdx`, `toolCall`) must be checked before `hook_event_name` to prevent Antigravity tool calls (which pass `hook_event_name: "PreToolUse"`) from being misclassified as Claude Code. Claude Code is identified by `transcript_path` (snake_case), while Muse is identified by `turn_id`/`turnId` and `muse` models.
- **2026-09-04T17:38-0700 Tool categorization for Muse**: Added `read_skill`, `readskill`, and `search` to `is_read_only_tool` so standard Muse skill reads and workspace searches auto-approve without manual prompt dialogs. Added `muse` and `muse *` to `BUILTIN_ALLOW_COMMANDS` and protected `.config/muse/auth.json` in `CREDENTIAL_PATHS`.
- **2026-09-04T17:38-0700 Non-destructive settings preservation**: Daemon and install scripts configure `"hooks"` in `~/.config/muse/settings.json` while preserving all existing configuration keys (`schema_version`, `provider`, `model`, `tui`).

## Commits

- c833c5b: feat(judge): support Meta Muse CLI in auto approval judge
- HEAD: fix(judge): address PR review comments for Meta Muse CLI support

## Progress

- [x] Worktree and plan initialized
- [x] Update `triage-core`: `is_read_only_tool`, `BUILTIN_ALLOW_COMMANDS`, `CREDENTIAL_PATHS`
- [x] Update `triage-hook`: `AgentFormat::Muse`, `detect_format`, `encode_response` with `updatedInput`
- [x] Update `triaged`: `resolve_muse_settings_path`, `get_hook_status`, `configure_hook`, `install_global_agent_hooks`
- [x] Update `scripts/install.sh` and `docs/approval-judge.md`
- [x] Unit tests in `triage-core`, `triage-hook`, and `triaged`
- [x] Workspace check, clippy, fmt, and test suite pass
- [x] Live verification with `muse`
- [x] Address PR review feedback: sanitize paths, defensive hook normalization, deduplicate settings resolver, add PATH probe, and add malformed config recovery unit test
