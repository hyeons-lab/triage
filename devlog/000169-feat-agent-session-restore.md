# 000169: Track foreground AI agents and resume conversations on restore

## Agent

Muse Code (muse-spark) @ triage branch feat/agent-session-restore (2026-09-20T10:26-0700)
Antigravity (gemini-2.5-pro) @ triage branch feat/agent-session-restore (2026-09-22T17:38-0700)

## Intent

Track which AI agent (Claude Code, Codex, Antigravity `agy`, Muse) is
executing in each triage session plus its conversation/transcript id, persist
that as live-only state, and restore the session after a reboot by resuming
the exact conversation. Exiting the agent returns the session to shell
status; exited sessions carry no agent state.

## What Changed

- New `triage-core/src/agent.rs`: `AgentKind` plus the shared
  `AgentAttachment` (kind, conversation id, transcript/exe paths, timestamp).
- New `triaged/src/agent_detect.rs`: argv classification (interactive vs
  headless vs bookkeeping), transcript correlation with single-candidate
  gating, resume-command builder, per-pid process readers (Linux `/proc`,
  macOS `proc_pidpath` + `KERN_PROCARGS2`), and the `FgAgentTracker`
  hold/detach/re-correlate state machine.
- `triaged/src/session.rs`: actors observe the PTY foreground pgid on the
  idle path and report attach/detach through a new agent-update channel
  (coalesced like cwd updates); `Live` and the manifest carry the
  attachment; restore respawns the agent resume command with shell
  fallback; stale attachments (missing binary/transcript) restore the
  shell.
- `triage-core/schema/triage.fbs`: `AgentKind` enum, `AgentAttachment`
  table, `agent` field on `SessionSnapshot` (append-only, old clients
  ignore it); Rust encoder plus Dart bindings regenerated via the script.
- TUI sidebar agent badge; Flutter rail badge, glance-card rows, snapshot
  parsing, and widget tests.
- `TRIAGE_DISABLE_AGENT_TRACKING` opt-out; daemon README section.
- Deterministic stub-agent test helper compiled by `build.rs`; full
  lifecycle E2E test (observe, attach, daemon death, restore, re-attach
  with the same id).
- **2026-09-22T17:38-0700** Rebased onto `origin/main` (incorporating PR #174
  and PR #176). Resolved conflict in `flutter/triage_client/lib/main.dart`
  (_SessionGlanceCard popover composition). Renumbered devlog and plan from
  000152 to 000153 to resolve sequence collision with merged PR #176.
- **2026-09-25T17:47-0700** Rebased onto `origin/main` (incorporating PR #178
  and PR #179). No conflicts. Renumbered devlog and plan from 000153 to
  000154 to resolve sequence collision with merged PR #178.
- **2026-10-20T12:46-0700** Committed R2-R5 review-loop hardening (`agent_detect.rs`,
  `session.rs`, `agent.rs`, `triage.fbs`, `main.dart`, `triage_websocket_client.dart`,
  and tests), rebased onto `origin/main` (`879b8a3`, incorporating PRs #180-#197),
  regenerated FlatBuffers bindings (`VT_AGENT = 36` after `VT_RAW_OUTPUT_PREFIX = 34`),
  and renumbered devlog and plan to `000169`.
- **2026-10-20T14:01-0700** Added `AgentKind::Grok` support across `triage-core`
  (including platform-suffixed `~/.grok/downloads/grok-<os>-<arch>` binary stems),
  FlatBuffers schema + Dart bindings, `triaged/src/agent_detect.rs` (argv classification,
  `--resume <id>` / `--continue` resume builder, `~/.grok/sessions/<encoded-cwd>/<id>/summary.json`
  correlation with `active_sessions.json` PID disambiguation), and unit tests.

## Decisions

- Actor-driven foreground observation instead of the planned global
  sampler thread: the actor already polls every 750ms with `tcgetpgrp`,
  which answers "what is executing" directly and cheaply, with no full
  process scans, no child-pid plumbing, and no handover pid transfer.
  Sudden-output floods cannot stall attach because the hold is
  elapsed-based, not poll-count-based.
- Attachments capture the agent's absolute exe path at observe time, so
  restore never depends on the daemon's `PATH` (login shells extend it
  beyond what the daemon sees).
- The launch record keeps the shell baseline even for agent respawns, so a
  later stale attachment still has a shell to fall back to; demotion
  clears attachments (exited sessions carry none), which also
  self-heals a failed agent restore into a shell on the next attempt.
- Windows detection is a stub (documented follow-up): no process
  introspection exists in-repo, argv there needs PEB reads, and it cannot
  be verified without a Windows host. macOS/Linux fully covered.
- No restore-confirmation flag in v1: confirmation UI would be a second
  feature across both clients, and the shell fallback makes auto-run
  safe. Reopen if auto-run proves surprising.
- No bulk list RPC in v1: the TUI attaches every session at startup so
  badges are present everywhere; Flutter remote shows badges after
  attach. A `list_session_agents` call (mirroring snippets) is the
  follow-up if attach-first proves insufficient there.
- See `devlog/plans/000169-01-agent-session-restore.md` for the full plan
  and spike findings.

## Issues

- SSH to github.com fails inside the sandbox (`No user exists for uid 501`,
  no agent). HTTPS remote works for fetch; use
  `git -c url."https://github.com/".insteadOf="git@github.com:"` for
  fetch/push commands from this environment.
- CI Format-and-Lint failed on a rustdoc broken intra-doc link
  (`argv[0]` in `agent_detect.rs` docs); Copilot flagged the `mac_argv`
  slicing and the agent-launch restore fallback (PR #177 comments
  4057908648, 4057908658). All three fixed in e1fdd70.
- Windows CI failed 5 tests: the two new restore tests (no process
  observation on Windows, so nothing re-attaches) plus three
  pre-existing correlate/slug tests (Unix-path assumptions and
  unescaped `\` in JSON fixtures). Fixed by `#[cfg(unix)]` gates and
  fixture escaping.
- The Antigravity review (PR conversation comment, not inline threads)
  was missed on the first resume pass: triage had only pulled inline
  threads plus failing checks, and the advisory check reads SUCCESS.
  Lesson: PR triage must pull conversation comments too.

## Commits

- d44666c: feat(session): track foreground AI agents and resume conversations on restore
- 1fd7199: fix(session): harden agent restore fallback and macOS argv parsing
- 017e529: fix(session): gate Windows-observation tests and escape fixture paths
- 289fb00: fix(session): address Antigravity review findings
- d2dd3f3: fix(session): address R1 agent-review-loop findings
- ae90479: fix(session): retry stub-agent observation for exec race
- e8f2c6b: chore(devlog): renumber devlog and plan to 000153 after rebase onto main
- bb58a32: fix(session): address R2-R5 agent-review-loop findings and harden agent restore
- HEAD: feat(session): add Grok agent tracking and conversation restore

## Progress

- [x] Worktree and branch created from origin/main at b2982bf
- [x] Branch devlog and plan file created
- [x] Grounding spikes (work item 1)
- [x] Agent adapters (work item 2)
- [x] Foreground observation + manifest lifecycle (work items 3-4)
- [x] Restore agent branch + stub-agent E2E (work item 5)
- [x] Snapshot/IPC/client surfacing (work item 6)
- [x] Docs and config (work item 7)
- [x] Final validation, commit, push, PR (#177)
- [x] 2026-09-20T13:27-0700 resumed: synced worktree to origin branch
  (ea0d979), fixed lint failure + Copilot findings with regression tests
- [x] 2026-09-20T14:55-0700 R1 agent-review-loop synthesis implemented:
  tracker retry + seeding, handover agent carry, restore/demote
  hardening, TUI/Flutter badge parity; repaired non-compiling synthesis
  (missing HandoverSession initializers, seeded-adoption borrow error,
  clippy type_complexity), added seeded-tracker regression tests
- [x] 2026-10-20T12:46-0700 R2-R5 review-loop hardening committed and rebased
  onto `origin/main` (`879b8a3`), devlog and plan renumbered to `000169`
- [x] 2026-10-20T14:01-0700 Added `AgentKind::Grok` support and tests

## Research & Discoveries

See plan file and spike findings (to be appended).

## Lessons Learned

- `KERN_PROCARGS2` packs NUL padding between its strings; an argv parser
  must skip NUL runs, not just split on them. Probed directly after the
  first implementation silently produced empty argv.
- Stub test processes must ignore argv deterministically: `/bin/sleep`
  with junk args happens to stay observable on macOS but exits on Linux,
  so observation tests would have been platform-flaky. The build.rs
  compiled stub removes the gamble everywhere including Windows CI.
- PTY tests cannot run under the sandboxed shell (`openpty: Operation
  not permitted`, same for pre-existing session tests); they need an
  unsandboxed run.
- `cargo doc -D warnings` is a CI gate the fmt/clippy/test trio does not
  cover; run it locally before pushing Rust doc changes (a bare
  `argv[0]` in a doc comment broke the PR #177 lint job).
- Findings outside this branch (2026-09-20T14:55-0700): triage-hook's
  `detects_antigravity_and_claude_signatures` fails locally because
  ambient `MUSE_TOOL_USE_ID` leaks into non-hermetic `detect_format`
  tests (green in CI); scrub agent env vars for local workspace runs.
  `interrupted_descriptor_chunks_preserve_the_mapped_prefix` flakes
  under parallel load locally (passes alone and on rerun).
- A multi-agent review synthesis can arrive non-compiling: budget a
  repair pass (missing struct initializers, borrow errors, new lints)
  plus regression tests for the synthesized behavior before committing.
- `observe_pid_stub_agent_with_argv_id` failed Ubuntu CI twice after
  one pass with identical exercised code: the parent can read /proc
  before the child execs, observing the pre-exec image as nothing.
  Retry briefly (2s) instead of observing once; production observation
  targets long-exec'd foreground pids, so the race is test-only.

## Next Steps

Await CI + Copilot re-review on PR #177, merge, remove the worktree.
