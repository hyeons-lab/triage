# 000135: Fix Muse hook format detection and payload compliance

- **Agent:** Antigravity (Gemini 3.8 Flash) @ triage branch fix/muse-hook-format-detection
- **Intent:** Fix `PreToolUse permissionDecision: allow requires updatedInput; a bare allow is rejected` hook failure in Meta Muse CLI by detecting Muse payloads with `tool_use_id` and ensuring `updatedInput` is properly supplied.

## What Changed

- **2026-09-04T21:20-0700** Created branch and worktree `worktrees/fix-muse-hook-format-detection` and plan `devlog/plans/000135-01-fix-muse-hook-format-detection.md`.
- **2026-09-04T21:24-0700** `crates/triage-hook/src/main.rs`: Updated `detect_format()` to recognize Muse's `tool_use_id` / `toolUseId` and `MUSE_TOOL_USE_ID` environment variable prior to generic Claude Code / transcript checks, preventing Muse payloads from being misclassified as Claude Code.
- **2026-09-04T21:24-0700** `crates/triage-hook/src/main.rs`: Added `updatedInput: raw_args` to `encode_response` under `AgentFormat::ClaudeCode` when arguments are present as defense in depth.
- **2026-09-04T21:24-0700** `crates/triage-hook/src/main.rs`: Added unit tests for Muse `tool_use_id` and `toolUseId` payload detection and Claude Code `updatedInput` serialization.
- **2026-09-04T21:24-0700** Rebuilt and installed release `triage-hook` binary to `~/.cargo/bin/triage-hook` with Apple Silicon code signing.
- **2026-09-04T21:33-0700** `docs/approval-judge.md`: Documented `MUSE_TOOL_USE_ID` environment variable override and CLI/env override options alongside `tool_use_id` detection.
- **2026-09-04T21:33-0700** `crates/triage-hook/src/main.rs`: Added comment clarifying `let_chains` nightly feature pinned via `rust-toolchain.toml`.

## Decisions

- **2026-09-04T21:20-0700** Detect Muse via `tool_use_id`: Muse's runtime constructs PreToolUse payloads containing `hook_event_name`, `tool_name`, `tool_input`, and `tool_use_id`, without `turn_id` or `model`. Checking `tool_use_id` and `toolUseId` prior to generic `hook_event_name` accurately classifies Muse calls as `AgentFormat::Muse` and emits the required `updatedInput` block.
- **2026-09-04T21:24-0700** Emit `updatedInput` in Claude Code response when arguments exist: Claude Code's PreToolUse schema supports `updatedInput`. Emitting it when tool arguments are available ensures hybrid or downstream consumers requiring `updatedInput` on allow decisions succeed even under Claude Code format matching.
- **2026-09-04T21:33-0700** Dismiss Copilot em dash comment: Copilot suggested replacing colon with em dash in the devlog Commits section. Rejected per user global rule strictly forbidding em dashes in any repository or workflow file.

## Progress

- [x] Create worktree and initialize devlog and plan
- [x] Update `detect_format` in `crates/triage-hook/src/main.rs`
- [x] Add unit tests covering Muse PreToolUse payload signatures
- [x] Format and test workspace
- [x] Install release binary and test with Muse payload
- [x] Address review feedback and document Muse env vars

## Commits

- df94658: fix(hook): detect Muse payloads by tool_use_id and emit updatedInput
- HEAD: docs(judge): document Muse env var override and let_chains usage
