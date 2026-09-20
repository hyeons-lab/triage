# 000152 feat/agent-session-restore

## Agent

Muse Code, 2026-09-20T10:26-0700.

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
- See `devlog/plans/000152-01-agent-session-restore.md` for the full plan
  and spike findings.

## Issues

- SSH to github.com fails inside the sandbox (`No user exists for uid 501`,
  no agent). HTTPS remote works for fetch; use
  `git -c url."https://github.com/".insteadOf="git@github.com:"` for
  fetch/push commands from this environment.
- CI Format-and-Lint failed on a rustdoc broken intra-doc link
  (`argv[0]` in `agent_detect.rs` docs); Copilot flagged the `mac_argv`
  slicing and the agent-launch restore fallback (PR #177 comments
  4057908648, 4057908658). All three fixed in the follow-up commit below.

## Commits

- ea0d979 — feat(session): track foreground AI agents and resume conversations on restore
- HEAD — fix(session): harden agent restore fallback and macOS argv parsing

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

## Next Steps

Await CI + Copilot re-review on PR #177, merge, remove the worktree.
