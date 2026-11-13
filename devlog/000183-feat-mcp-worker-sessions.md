# feat/mcp-worker-sessions

## Intent

Expose the existing session lifecycle through MCP so review coordinators can launch AGY, Claude, Muse, Codex, or another executable in a chosen worktree and stop the sessions they own.

## Progress

- [x] Inspect the open PR stack and create a worktree from PR #213.
- [x] Record the implementation plan.
- [x] Add validated session launch and shutdown tools.
- [x] Test protocol validation, forwarding, failures, and a real session lifecycle.
- [x] Update MCP and coordination documentation.
- [x] Run local CI gates and the max-effort local review loop.
- [x] Prepare the single commit and PR description targeting the parent branch.

## Decisions

2026-11-12T14:03-0800 Stack on feat/d1-approval-judge (PR #213), above feat/terminal-cell-sync (PR #212), as requested. Leave both parent worktrees untouched.
2026-11-12T14:03-0800 Reuse SessionApi::start_session and SessionApi::shutdown_session. Launch executables with an argv vector and an explicit absolute cwd; keep runtime-specific launch flags in the caller.
2026-11-12T14:03-0800 Return the created session ID directly without a fallible post-launch snapshot or label update. The coordinator records worker ownership and retains reports outside coordination mail.

## Next Steps

Implement the plan in devlog/plans/000183-01-mcp-worker-sessions.md.

## What Changed

2026-11-12T20:37-0800 crates/triage-mcp/src/main.rs: expose start_session and shutdown_session through the existing daemon API, validate object arguments and omission-only dimension defaults, and cover argv forwarding, protocol errors, backend failures, and a real isolated PTY lifecycle.
2026-11-12T20:37-0800 crates/triage-mcp/README.md, skills/triage-coordination/SKILL.md: document agent-runtime launch arguments, readiness, persistent result files, exact-ID worker ownership, shutdown, and wake/wait behavior.

## Issues

2026-11-12T20:37-0800 The first max review found that derived struct decoding accepts positional arrays and optional integer fields accept null as omission. Both were reproduced by failing tests, then fixed. The class sweep found the existing MCP handlers already enforce object containers.
2026-11-12T20:37-0800 The review also identified pre-existing IPC cause truncation. It is outside this branch's thin lifecycle wrapper scope and remains a separate follow-up.

## Verification

2026-11-12T20:37-0800 Initial Rust workspace tests, strict clippy, Rustdoc, format/version checks, generated Dart bindings, Flutter analysis, 705 Flutter tests, and Android release build passed. The two added validation regressions failed before fixes. Chrome is unavailable locally, so browser transport tests remain for CI. Post-fix verification and full review confirmation are pending.

## Review Follow-up

2026-11-12T20:56-0800 The full confirmation review identified reusable session IDs after cold restart. Updated tool metadata and both guidance documents to require fresh ownership evidence and a unique run/task handshake before cancelling persisted IDs. The daemon's numeric allocator is unchanged.
2026-11-12T20:56-0800 The input-shape class sweep also traced populated positional JSON-RPC envelopes into the lifecycle handlers. A raw-stdio regression failed before adding an outer object guard; valid object launch and shutdown requests remain positive controls. This covers the production decoder in addition to typed handler tests.
2026-11-12T20:56-0800 All local CI gates passed after the validation fixes: 867 Rust tests, strict clippy, rustdoc, formatting, version consistency, 705 Flutter tests, 74 browser transport tests, Flutter analysis, generated bindings, and Android release build. The temporary browser download closed the earlier local browser-test gap without changing project dependencies.

## Outcome

2026-11-12T21:20-0800 Implementation and local verification are complete. Two full final reviewer sets, each covering all eight pillars, reported no findings. Coverage checks found zero debt, and final source hashes match the code that passed all CI commands locally. Three executable validation regressions were demonstrated failing before fixes; cancellation guidance also accounts for numeric ID reuse after cold restart.
2026-11-12T21:20-0800 Final validation: 868 Rust tests (including 22 MCP tests), strict workspace clippy, Rustdoc with warnings denied, formatting/version consistency, Flutter analysis, 705 Flutter tests, 74 browser transport tests, generated Dart binding consistency, and Android release build. Actual agent CLI conversations and the user's running daemon were not changed.

## Commits

HEAD: feat(mcp): expose session lifecycle tools
