# 000194 fix/pretooluse-hook

- **Agent:** Antigravity
- **Intent:** Fix `PreToolUse` hook execution failures and cross-platform defects across `triage-hook`, `triage-core`, and `triaged`, including stale cross-OS hook command paths (`The system cannot find the path specified.`), Antigravity `Ask` JSON output, Windows named-pipe IPC, Windows backslash/PowerShell rule evaluation, and Claude/Muse response edge cases.

## What Changed

- 2026-11-19T08:11-0800 `devlog/plans/000194-01-fix-pretooluse-hook.md` — initialized plan for PreToolUse hook fixes in worktree `worktrees/fix-pretooluse-hook` branched from `origin/main`.
- 2026-11-19T08:54-0800 `crates/triage-core/src/ipc.rs` — added `MAX_WINDOWS_PIPE_TOKEN_LEN`, `windows_pipe_token_raw`, `windows_pipe_endpoint`, and pipe endpoint normalization unit test.
- 2026-11-19T08:54-0800 `crates/triage-core/src/judge_rules.rs` — preserved Windows backslashes in `tokenize_words`, made `.exe` stripping case-insensitive, added read-only Windows/PowerShell commands (`dir`, `where`, `findstr`, `Get-ChildItem`, `Get-Content`, `Select-String`, etc.) with `Env:` provider protection and Windows/PowerShell unit tests.
- 2026-11-19T08:54-0800 `crates/triage-hook/src/main.rs` & `docs/approval-judge.md` — emitted explicit `{"decision":"ask",...}` JSON for Antigravity/Generic `Ask` verdicts while keeping silent passthrough for Claude Code/Muse, added Windows named-pipe IPC (`OpenOptions` with `ERROR_PIPE_BUSY` retry), prevented outer hook envelope fields from leaking into `updatedInput`, omitted empty `permissionDecisionReason`, and documented Windows named-pipe IPC.
- 2026-11-19T08:54-0800 `crates/triaged/src/judge.rs`, `crates/triaged/src/service.rs`, `crates/triaged/src/ipc.rs` — added hook command quoting (`format_hook_command`), disk validation (`is_triage_hook_command_valid`) and stale-path repair in `configure_hook` and `install_global_agent_hooks` (plus `configure_hook_repairs_stale_foreign_hook_paths` test), and shared `windows_pipe_token_raw` with `triage-core`.
- 2026-11-19T10:39-0800 Rebased onto `fix/alt-screen-wheel-arrows` (`#216`), resolved the `judge_rules.rs` test-module merge cleanly alongside `#213` d1 config persistence tests, gated `CLIENT_WRITE_TIMEOUT` in `crates/triaged/src/ipc.rs` with `#[cfg(unix)]` (and fixed Windows-only clippy warnings on `child_req` in `crates/triaged/src/ipc.rs` and `tcp_listener` in `crates/triaged/src/main.rs`), and renumbered devlog/plan from `000181` to `000194` to avoid colliding with `#212`.
- 2026-11-19T12:20-0800 Addressed PR `#228` Antigravity Code Review findings across `triage-core`, `triage-hook`, and `triaged`: replaced byte-index `&str` slicing in `has_powershell_env_provider` and `program_name` with byte-safe checks, bounded `tokenize_words_preserving_windows_paths` lookahead to the current token and stripped backslash escapes on flags/`=` key-values/`\-` prefixes plus disqualifier checks, extended PowerShell checks (`-Path:Env:`, `Variable:`, `Cert:`, `HKCU:`, `HKLM:`, `Test-Path`, `Resolve-Path`, `Get-Acl`, `Get-Content -Wait`), routed `triage-hook` stdin parse/limit/timeout fallbacks through `detect_format(&serde_json::Value::Null)`, centralized `windows_pipe_token` (with case-insensitive `\\.\PIPE\` / `\\?\PIPE\` prefix stripping and deterministic FNV-1a capping) in `triage_core::ipc`, preserved `"enabled": false` and gated `agy_hook` symlink removal to `#[cfg(unix)]` in `install_global_agent_hooks`, updated `.gemini/config/hooks.json` in `configure_hook`, added argv[0] tokenization in `is_triage_hook_command_valid`, quoted shell metacharacters (`&`, `(`, `)`, `'`, `;`) in `format_hook_command`, and added regression tests for each case.

## Decisions

- 2026-11-19T08:11-0800 Preserve silent passthrough (`""`) on `JudgeDecision::Ask` for `ClaudeCode` and `Muse` while restoring explicit JSON `{"decision":"ask",...}` output for `Antigravity` and `Generic` to comply with Antigravity's `PreToolUse` stdout contract.
- 2026-11-19T08:11-0800 Implement Windows named-pipe IPC in `triage-hook` using `std::fs::OpenOptions` with `ERROR_PIPE_BUSY` retry so `triage-hook` stays free of heavy runtime dependencies while matching `triaged`'s Windows IPC protocol.
- 2026-11-19T12:20-0800 Hash overlong Windows pipe tokens in `triage_core::ipc::windows_pipe_token` using deterministic 64-bit FNV-1a and have `triaged::ipc::transport::windows_pipe_token` delegate to it so `triaged` and `triage-hook` derive identical pipe tokens without adding hashing crates to `triage-hook`.

## Issues

- 2026-11-19T08:11-0800 Antigravity CLI on Windows logged `JSON hook "jsonhook__triage-approval-judge_PreToolUse_0_0" failed: command failed: exit status 1, stderr: The system cannot find the path specified.` when a workspace `.agents/hooks.json` carried a macOS `/Users/<user>/.cargo/bin/triage-hook` path that `configure_hook` refused to overwrite because `PreToolUse` already existed.
- 2026-11-19T08:54-0800 Workspace verification findings on Windows: `cargo clippy --all-targets --all-features` cannot run offline because optional dependency `piper v0.2.5` is not cached locally, and `triaged` hits a pre-existing Windows `dead_code` warning on `CLIENT_WRITE_TIMEOUT` (`crates/triaged/src/ipc.rs:108`). In full `cargo test --workspace`, `triage-core`, `triage-hook`, `triage-mcp`, `triage-transport-ws`, `triage-term`, `triage-test-support`, and `triage` passed all tests; `triaged` passed all 56 filtered `judge::`, `service::`, and `ipc::tests::windows_` tests, while 8 pre-existing `triaged` tests failed in the Windows sandbox (3 missing `sh`, 3 MSYS2 `git` `0xC0000022`, and 2 `ipc::tests` Windows `spawn_server` probe timing races).

## Commits

- 66ebf85 — fix(hook,judge): repair PreToolUse output, Windows pipe IPC, and stale hook paths
- HEAD — fix(hook,judge): address PR #228 review findings

## Progress

- [x] Create `worktrees/fix-pretooluse-hook` off `origin/main` and write devlog/plan
- [x] Implement fixes in `triage-core`, `triage-hook`, and `triaged`
- [x] Format, lint modified crates, smoke-test `triage-hook.exe`, and run tests
- [x] Update devlog and prepare commit
- [x] Address PR #228 review blocking issues, warnings, and test cases
