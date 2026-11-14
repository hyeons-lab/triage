# Managed worker groups

## Intent

Support an orchestrator delegating across CLI sessions with durable parent/topic ownership, reusable launch profiles, explicit task state, and cleanup limited to its workers.

## Decisions

- 2026-11-13T16:38-0800 Stack on the open clickable-terminal-urls branch above the MCP session-control PR. Keep the separate wheel-input fix independent.
- 2026-11-13T16:38-0800 Put lifecycle and durable state in the daemon. Keep native-subagent selection in the coordination skill because that capability belongs to the calling runtime.
- 2026-11-13T16:38-0800 Keep code worktrees and completed results during cleanup. Session shutdown must require stable ownership rather than reusable display IDs.

## Progress

- [x] Fetch and create isolated worktree; verify no upstream.
- [x] Record implementation plan before code.
- [x] Implement and validate managed groups and worker protocol.
- [x] Run local CI gates and max review loop.
- [x] Prepare reviewed commit and stacked PR publication.

## What Changed

- 2026-11-13T17:40-0800 `triage-core` worker models/config/API, daemon worker registry, local IPC, and MCP tools: parent/topic ownership, nested helper links, retry-safe launches, explicit worker state/results, and group/subtree cleanup.
- 2026-11-13T17:40-0800 Session incarnation metadata persists through manifests, restore, and PTY handover. Worker status uses shared exit metadata; pending adoption remains owned, and cleanup retries reconcile late shutdown completion.
- 2026-11-13T17:40-0800 Worker profiles supply literal command/argv templates and bootstrap prompts; the CLI can report durable updates without per-runtime MCP configuration. Coordination guidance selects native helpers when suitable and otherwise uses managed sessions.
- 2026-11-13T17:40-0800 Regression coverage includes isolated real PTYs, the full MCP/IPC/CLI path, concurrency/retry, cold restore, production adoption, capacity and persistence failure, and authoritative ownership checks.
- 2026-11-13T17:40-0800 Correct the inherited browser trim bound by replacing a wide shift with the equivalent exact integer literal, keeping transport assertions intact.

- 2026-11-13T19:59-0800 Owned shutdown skips discarded history replay and repository enrichment for both live and finished workers. Failed manifest removal retains the stopped identity for retry; ordinary shutdown still returns completed output.
- 2026-11-13T19:59-0800 Worker IPC preserves nested error causes and the failed registry path. Tests observe actual task/relationship receipt and cover wide browser offsets at the exact protocol bound.
- 2026-11-13T19:59-0800 Portable cached context retries cover full observer queues in idle and output-closed states, preserving repository grouping without a synchronous actor wait.

- 2026-11-13T20:16-0800 Registry directory setup now shares the persistence error context, so its OS failure also names the affected registry path.

## Issues

- 2026-11-13T17:40-0800 The first max review found recovery and cleanup defects: stale registry reload, deferred adoption ownership, scope-widening null input, Windows backup recovery, cleanup capacity, and redundant status/persistence work. Applied fixes and added direct regressions; targeted fix verification found no open confirmed issue.
- 2026-11-13T17:40-0800 The open parent stack changed during review. Refreshed onto its latest clickable-terminal-urls commit before confirmation. This exposed a browser-only shift regression that the VM suite does not detect; fixed the production bound and repeated the CI gate set.

- 2026-11-13T19:59-0800 A narrowed review found context retries could remain dormant after queue backpressure. Added a throttled retry at the portable actor-loop boundary and a controlled full-queue regression.
- 2026-11-13T19:59-0800 Independent verification found late owned cleanup rebuilt terminal history under the session lock and normal owned cleanup built an unused fallback. Direct owned removal avoids both paths; unreplayable-history and blocked-context controls cover live/finished cleanup. Diagnostic and positive-delivery gaps were fixed in the same scoped pass.

## Next Steps

- Finish full confirmation and independent review, then commit and open the stacked PR.
- Installation and real-provider authentication/startup/model-turn smoke tests remain separate rollout work; no live daemon or installed CLI configuration has been changed.

- 2026-11-13T18:09-0800 Confirmation found two fix-induced cases: a finished actor alone did not confirm child exit, and managed launch omitted the rail's cached git context. Cleanup now retains unconfirmed ownership, while a post-start actor notification publishes cached metadata asynchronously. Regressions fail before each fix; the context case uses canonical cwd to avoid an incidental symlink refresh masking it. Added real EOF exit observation through group status, without snapshot polling.

## Research & Discoveries

- 2026-11-13T19:59-0800 Local CI gates pass: format, version consistency, all-target/all-feature Clippy, strict rustdoc, and 928 Rust tests (one pre-existing ignored model test). All 28 worker regressions pass, including isolated real PTYs and MCP/IPC/CLI updates.
- 2026-11-13T19:59-0800 Flutter analysis, generated binding consistency, 746 VM tests, 76 Chrome tests, and Android release build pass. Both frontend suites retain two expected native-builder skips.
- 2026-11-13T19:59-0800 Before/after controls fail for replay-dependent cleanup and discarded IPC causes before fixes. Task-omission and narrowed-browser-cap mutants fail their intended assertions; restored sources and worker tests pass. Coverage tools not installed were recorded as unavailable, rather than reported as executed.

- 2026-11-13T20:40-0800 Added the live owned post-shutdown manifest-failure regression: ownership, inbox and label survive failed removal, then retry closes the session. Removing the retention guard fails the identity assertion; exact production bytes restored. All 929 Rust tests and 29 worker regressions pass.

## Commits

HEAD — feat(workers): add managed session groups

## Review Completion

- 2026-11-13T20:50-0800 All confirmed behavior, diagnostic, and verification findings are addressed. Final eight-pillar confirmation is clean; independent verification found no production defect and its missing-test finding is pinned by a guard-deletion control. Final post-polish confirmation found no remaining issue.
- 2026-11-13T20:50-0800 Local gates pass with 929 Rust tests, 29 worker regressions, 746 Flutter VM tests, 76 Chrome tests, generated bindings, analysis, and Android release. Installation, real-provider model turns, and automatic worktree/registry pruning remain outside this change.
- 2026-11-13T20:50-0800 Publish this reviewed commit as a PR on the still-open clickable-terminal-urls branch. Retain this worktree until merge.
