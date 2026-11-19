# Plan: Fix PreToolUse hook across Antigravity, Windows, and cross-OS configs

## Thinking

Investigating the `PreToolUse` hook path across `triage-hook`, `triage-core`, `triaged`, and the local Windows Antigravity CLI logs surfaced five concrete defects:

1. **Cross-OS stale absolute paths in `.agents/hooks.json` and hook provisioning**:
   - Antigravity CLI failed with `JSON hook "jsonhook__triage-approval-judge_PreToolUse_0_0" failed: command failed: exit status 1, stderr: The system cannot find the path specified.` because a workspace `.agents/hooks.json` carried `/Users/<user>/.cargo/bin/triage-hook` from macOS, which `cmd /c` on Windows rejects.
   - `triaged::judge::configure_hook` only inserts `PreToolUse` when `"PreToolUse"` is absent, so re-configuring never repairs an existing stale/foreign path. Similarly, `triaged::service::install_global_agent_hooks` skips updating Claude/Muse `PreToolUse` entries whenever any command contains `"triage-hook"`, even if the path is invalid on the current OS. Both also leave paths with whitespace unquoted for `cmd /c` / `sh -c`.
   - `triaged::judge::get_hook_status` reports `enabled: true` even when the configured `triage-hook` command path does not exist on disk.

2. **Empty stdout on `Ask` for Antigravity and Generic formats**:
   - `encode_response` in `crates/triage-hook/src/main.rs` returns `String::new()` for `JudgeDecision::Ask`, so `main()` exits `0` with no stdout.
   - Antigravity's `PreToolUse` contract requires a JSON object on stdout with `decision` (`"allow" | "deny" | "ask" | "force_ask"`), and `triage-hook`'s own invariants state it always prints one decision object and falls back to `ask`. Emitting `{"decision":"ask", ...}` for `AgentFormat::Antigravity` and `AgentFormat::Generic` satisfies the contract while keeping silent passthrough for `ClaudeCode` and `Muse`.

3. **Missing Windows named-pipe IPC in `triage-hook`**:
   - `send_ipc_judge_request` in `crates/triage-hook/src/main.rs` stubs out `#[cfg(not(unix))]` with an unconditional error, so on Windows `triage-hook` never queries `triaged`'s named pipe (`\\.\pipe\triage-<user>`), bypassing daemon overrides, model evaluation, and audit history.
   - Using `std::fs::OpenOptions` (with `ERROR_PIPE_BUSY` retry within the remaining timeout budget) against the normalized Windows pipe endpoint lets `triage-hook` talk to `triaged` over named pipes with zero new crate dependencies and clean offline fallback when the daemon is not running.

4. **Windows path backslash stripping and PowerShell command rules in `triage-core::judge_rules`**:
   - `tokenize_words` delegates to `shlex::split`, which treats `\` as an escape character and strips backslashes from Windows paths (`C:\Users\...`, `.\scripts\...`, `\\server\...`), breaking both `program_name` path extraction (including security checks on `C:\...\rm.exe`) and `scripts\*` wildcard allow rules.
   - Read-only PowerShell cmdlets (`Get-ChildItem`, `Get-Content`, `Select-String`, `Select-Object`, etc.) and Windows read-only utilities (`dir`, `where`, `findstr`) are missing from `BUILTIN_ALLOW_COMMANDS`, causing routine read-only Windows shell inspections to fall back to `Ask`.

5. **Claude Code / Muse `updatedInput` and `permissionDecisionReason` edge cases**:
   - When a hook payload has no explicit tool-input key, `extract_tool_info` clones the outer hook payload as `args`, causing `encode_response` to emit the hook metadata (`session_id`, `transcript_path`, etc.) inside `updatedInput`.
   - When `verdict.reason` is empty, `ClaudeCode` and `Muse` serialize `"permissionDecisionReason": null` instead of omitting the optional key.

## Plan

1. **`crates/triage-core/src/ipc.rs`**:
   - Add cross-platform `windows_pipe_endpoint(path: &Path) -> std::io::Result<String>` helper to normalize `\\.\pipe\...`, `\\?\pipe\...`, or bare pipe tokens for `triage-hook` and `triaged`.
2. **`crates/triage-core/src/judge_rules.rs`**:
   - Preserve Windows path backslashes (`[A-Za-z]:\`, `.\`, `..\`, `\\`, and non-escape Windows separators under `cfg!(windows)`) in `tokenize_words` without weakening POSIX `\` security checks (`r\m`, `\$`, `\"`).
   - Make `.exe` suffix stripping in `program_name` case-insensitive.
   - Add read-only PowerShell cmdlets and Windows inspection commands (`dir`, `where`, `findstr`, `Get-ChildItem`, `Get-Content`, `Get-Item`, `Get-ItemProperty`, `Get-Location`, `Get-Date`, `Get-Command`, `Get-Process`, `Get-Service`, `Get-Acl`, `Test-Path`, `Select-String`, `Select-Object`, `Where-Object`, `Format-List`, `Format-Table`, `Measure-Object`, `Sort-Object`, `Group-Object`, `Out-String`, `Write-Output`, `Resolve-Path`, `Split-Path`, `Join-Path`, `Push-Location`, `Pop-Location`, `Set-Location`) with case-insensitive PowerShell cmdlet matching while preserving credential path and destructive-command guards.
   - Add unit tests for Windows paths, `.EXE` stripping, and PowerShell allow/credential-deny behavior.
3. **`crates/triage-hook/src/main.rs` & `docs/approval-judge.md`**:
   - Emit `HookJsonResponse { decision: "ask", ... }` for `AgentFormat::Antigravity` and `AgentFormat::Generic` on `JudgeDecision::Ask`.
   - Implement Windows named-pipe IPC in `send_ipc_judge_request` sharing wire round-trip logic with Unix, and update `docs/approval-judge.md`.
   - Track explicit tool arguments separately from outer-envelope fallback so `ClaudeCode`/`Muse` `updatedInput` never leaks hook envelope fields, and omit `permissionDecisionReason` when empty.
   - Update and expand `triage-hook` unit tests (including Windows named-pipe IPC round-trip and error/timeout tests).
4. **`crates/triaged/src/judge.rs` & `crates/triaged/src/service.rs`**:
   - Extract shared hook-command resolution/quoting (for paths with whitespace under `cmd /c` / `sh -c`) and PreToolUse JSON repair helpers.
   - Repair stale or missing `triage-hook` command paths in `configure_hook` and `install_global_agent_hooks` instead of skipping whenever `"PreToolUse"` or `"triage-hook"` is present.
   - Verify explicit command paths exist on disk in `get_hook_status`, and add unit tests for stale cross-OS hook repair and quoting.
5. **Validate**:
   - Run `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test --workspace` (excluding or handling any unrelated environment issues cleanly).
   - Rebuild and test `triage-hook.exe` against sample Antigravity, Windows PowerShell, Claude Code, and Muse payloads.
