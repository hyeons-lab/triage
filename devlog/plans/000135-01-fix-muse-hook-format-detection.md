# 000135-01 Fix Muse Hook Format Detection

## Thinking

Meta Muse CLI (`muse`) invokes `PreToolUse` lifecycle hooks with this payload shape:
```json
{
  "hook_event_name": "PreToolUse",
  "tool_name": "bash",
  "tool_input": { ... },
  "tool_use_id": "call_..."
}
```

In `crates/triage-hook/src/main.rs`, `detect_format()` attempted to detect Muse using `turn_id`, `turnId`, or `model`. However, Muse's actual `PreToolUse` payload does not contain `turn_id` or `model`. Instead, it contains `tool_use_id`, `hook_event_name`, `tool_name`, and `tool_input`.

Because `tool_use_id` was not checked, and `hook_event_name` was checked afterwards under Claude Code detection, Muse payloads were misclassified as `AgentFormat::ClaudeCode`.

Under `AgentFormat::ClaudeCode`, `encode_response` emits:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "..."
  }
}
```
without `updatedInput`.

Muse validates the hook response strictly. In Muse's binary:
- `PreToolUse 'permissionDecision: allow' requires 'updatedInput'; a bare allow is rejected`
- `PreToolUse 'permissionDecision: deny' requires a non-empty 'permissionDecisionReason'`

Because `updatedInput` was omitted in Claude Code's response format, Muse rejected the hook response with:
`Hook failed · PreToolUse · PreToolUse permissionDecision: allow requires updatedInput; a bare allow is rejected`

Under `AgentFormat::Muse`, `encode_response` was already implemented to emit `updatedInput: tool_args`. But because `detect_format` misclassified Muse as Claude Code, `AgentFormat::Muse` was never reached.

In addition:
1. `detect_format` should recognize `tool_use_id` and `toolUseId` as Muse signatures before generic Claude Code / transcript checks.
2. In `encode_response` for `AgentFormat::ClaudeCode`, if `raw_args` is present, also emit `updatedInput: raw_args` as defense in depth so any Claude Code or hybrid runner expecting `updatedInput` will succeed.
3. In `triaged` hook provisioning (`service.rs`, `judge.rs`) and `scripts/install.sh`, ensure Muse hook configuration explicitly passes `--format=muse` or continues to support standard `triage-hook` invocation.

## Plan

1. **Update `detect_format` in `crates/triage-hook/src/main.rs`**:
   - Check `val.get("tool_use_id").is_some() || val.get("toolUseId").is_some()` alongside `turn_id`, `turnId`, and `is_muse_model`.
   - Check Muse signatures before generic `hook_event_name` and `transcript_path` checks.
   - Support `std::env::var("MUSE_TOOL_USE_ID").is_ok()`.

2. **Update `encode_response` in `crates/triage-hook/src/main.rs`**:
   - Ensure `AgentFormat::ClaudeCode` also includes `updatedInput: raw_args` when `raw_args` is available, while preserving `AgentFormat::Muse`'s strict schema with `updatedInput`.

3. **Add Tests in `crates/triage-hook/src/main.rs`**:
   - Add unit test verifying that real Muse PreToolUse payloads carrying `tool_use_id`, `hook_event_name`, `tool_name`, and `tool_input` are detected as `AgentFormat::Muse`.
   - Add unit test verifying that `encode_response` for `AgentFormat::Muse` includes `updatedInput` matching the incoming tool arguments.

4. **Verify Hook Provisioning in `triaged` and `scripts/install.sh`**:
   - Check `crates/triaged/src/service.rs`, `crates/triaged/src/judge.rs`, and `scripts/install.sh` to ensure compatibility.

5. **Validation and Build**:
   - Run `cargo fmt --all -- --check`.
   - Run `cargo clippy --all-targets --all-features -- -D warnings`.
   - Run `cargo test --workspace`.
   - Install binary to `~/.cargo/bin/triage-hook` and re-sign on macOS ARM64.
   - Verify with live test payload.
