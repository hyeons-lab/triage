# Devlog 000186: feat/mcp-worker-lifecycle

**Agent:** Codex @ triage branch `feat/mcp-worker-lifecycle`

## Intent

Add structured multi-agent worker lifecycle orchestration and automated input safety guards to Triage (`triage-core`, `triaged`, `triage-transport-ws`, `triage-mcp`):

1. Parent-child session links (`parent_session_id`, `outlive_parent`) on `StartSessionRequest` and `SessionSnapshot`, automatic cascade cleanup of non-outlive children on parent exit/shutdown, and automatic inbox alerts to parent sessions when a child exits unexpectedly or hits a judge/confirmation approval block.
2. Blocking `wait_for_sessions` (`any` / `all`, `idle_ms`, `output_contains`, exited, blocked, or coordinator inbox interrupt) across `SessionApi`, IPC, and `triage-mcp`.
3. Blocked-prompt and unsubmitted human draft guards for `wake` (`try_wake_session_for_inbox` / `wake_for_inbox`) and automated `WriteInputRequest` writes, plus `pending_approval` and `pending_approval_reason` surfaced in `SessionSnapshot` and FlatBuffers.

## Progress

- [x] Create stacked worktree `feat/mcp-worker-lifecycle` on top of `fix/mobile-keyboard-swipe` (`938f55f`)
- [x] Write branch devlog and plan (`devlog/plans/000186-01-mcp-worker-lifecycle-and-guards.md`)
- [x] Extend `triage-core` (`StartSessionRequest`, `SessionSnapshot`, `WaitForSessions*`, `SessionApi`, `triage.fbs`, `flatbuffers_proto.rs`) and regenerate Dart FlatBuffers
- [x] Implement lifecycle tracking, parent alerts, cascade cleanup, `wait_for_sessions`, pending-approval detection, and wake/automated-write guards in `triaged`
- [x] Wire `WaitForSessions` and new snapshot/start fields through IPC and `triage-transport-ws`
- [x] Update `triage-mcp` (`start_session`, `wait_for_sessions`, `snapshot_session`) and add tests
- [x] Verify formatting, clippy, and full workspace tests

## What Changed

- `2026-11-15T15:14-0800 crates/triage-core/schema/triage.fbs`, `crates/triage-core/src/flatbuffers_proto.rs`, `flutter/triage_client/lib/generated/`: Added `parent_session_id`, `outlive_parent`, `pending_approval`, and `pending_approval_reason` to `SessionSnapshot` and `StartSessionRequestTable`, and regenerated Dart FlatBuffer bindings.
- `2026-11-15T15:14-0800 crates/triage-core/src/session.rs`: Added `parent_session_id` and `outlive_parent` to `StartSessionRequest` and `SessionSnapshot`, plus `WaitForSessionsMode`, `SessionWaitOutcome`, `WaitForSessionsRequest`, `WaitedSessionStatus`, `WaitForSessionsResponse`, and `SessionApi::wait_for_sessions`.
- `2026-11-15T15:14-0800 crates/triaged/src/session.rs`, `crates/triaged/src/ipc.rs`, `crates/triaged/src/handover.rs`, `crates/triaged/src/main.rs`:
  - Added lifecycle monitor thread, parent inbox exit/approval alerts, and non-outlive child cascade cleanup on parent shutdown or exit.
  - Implemented `SessionApi::wait_for_sessions` using `ActorCommand::WaitProbe` + `SessionStateSignal` (`Condvar`) across `Any` / `All`, `idle_ms`, `output_contains`, `Exited`, `Blocked`, and `for_inbox_session_id` inbox interruption.
  - Added `ActorLifecycleShared` (tracking `draft_updated_ms` from `WriteHumanInput` and `judge_pending_approval`), screen confirmation prompt detection, and guards blocking `wake_for_inbox` and `InputControllerKind::Agent` `write_input` during active human drafts or pending approvals.
- `2026-11-15T15:14-0800 crates/triage-transport-ws/`, `crates/triage/`, `crates/triage-mcp/src/main.rs`: Wired `parent_session_id`, `outlive_parent`, `pending_approval`, `pending_approval_reason`, and the `wait_for_sessions` MCP tool (`start_session` + `wait_for_sessions` + tests).

## Decisions

- `2026-11-15T15:14-0800 Decision`: Store `parent_session_id` and `outlive_parent` on `PersistedSessionLaunch`, `PersistedSession`, and `HandoverSession` so parent-child links survive daemon reloads and handovers without extra session-map wrappers.
- `2026-11-15T15:14-0800 Decision`: Share `ActorLifecycleShared` atomics between `SessionActor` and `ActorState` and split `ActorCommand::WriteHumanInput` from `WriteInput` so interactive vs automated (`Agent`) writes update draft state without an extra synchronous actor round-trip.

## Issues

- `2026-11-16T18:05-0800 crates/triaged/src/session.rs`: Importing `JudgeDecision` at module scope made the pre-existing explicit doc link target `triage_core::judge::JudgeDecision::Ask` redundant under `RUSTDOCFLAGS="-D warnings"` (`rustdoc::redundant_explicit_links`). Removed the redundant explicit target.

## Commits

- `0160a30`: feat: add worker lifecycle, blocking wait, and input guards
- `HEAD`: fix(triaged): remove redundant rustdoc link on JudgeDecision::Ask
