# 000152-01 agent session restore

## Thinking

2026-09-20T10:26-0700. The user loses AI agent conversations across reboots:
triage restores shells only, and re-finding the right conversation in agent
history is confusing. Research established the shape of the fix before any
code:

- Sessions today: shell in a PTY, JSON manifest (v1) with
  command/args/cwd/last_known_cwd/log/exited/activity, rewritten on
  lifecycle events plus a 60s activity backstop. Restart yields Historical
  sessions; user-triggered `restore_session` respawns restorable shells
  only. The agent running inside is lost.
- Resume verbs verified against installed CLIs: `claude --resume/--continue`,
  `codex resume [id]/--last`, `muse resume <ref>/--last`,
  `agy --conversation/--continue`.
- Transcript stores verified for claude/codex/muse; muse's store is noisy
  with subagent sessions; agy CLI storage is unlocated (spike, with
  `--continue` fallback).
- Detection without user setup means process-tree scan from the PTY child
  PID plus argv parsing, with transcript correlation only as a gated
  fallback. Ungated newest-file correlation misattributes in multi-session
  repos, and a wrong resume is worse than a shell, so correlation requires a
  single unambiguous candidate and otherwise records kind-only.
- The user set the lifecycle semantics during plan review: exiting the agent
  and working at the shell must restore to a shell; exited sessions keep no
  agent state (history already shows what to restore). So attachments are
  live-only, detached on observed exit, and the manifest holds them purely
  as a crash snapshot, with transition-triggered debounced writes so detach
  lands in seconds.
- Two facts still need grounding before design lock (work item 1): the
  `portable_pty` child-PID API per platform, and whether `SessionSnapshot`
  crosses the flatbuffers wire schema. Native introspection (`codex agents`,
  muse session tooling) may beat process scanning for those agents.

## Plan

Goal: triage tracks, per session, which AI agent is currently executing and
which conversation/transcript it is in. If the agent is still running when
the daemon dies or the machine reboots, restoring the session resumes that
exact conversation. If the user exited the agent and went back to the shell,
the session restores as a shell. Exited sessions carry no agent state.

Success criteria:

- A session with a live interactive agent shows agent kind and conversation
  id with no user setup.
- Post-reboot restore relaunches the agent resumed into the same
  conversation (all four agents).
- Exit agent plus shell use clears the attachment; post-reboot restore
  yields a shell.
- Exited sessions persist no attachment.
- Correlation attaches an id only on a single unambiguous candidate;
  otherwise kind-only with the UI marking most-recent resume as a guess.
- Non-agent sessions restore as today. Pointers only, no transcript
  content.

Key decisions:

1. Detection is process-tree scan plus argv, with gated correlation as
   fallback. Interactive runs only (headless `--print`/`exec` classified
   out by argv; lifetime threshold across consecutive samples).
2. Attachments are live-state only. Detach on observed agent exit or
   session exit; transition-triggered debounced manifest writes (cwd-settle
   pattern); 60s activity loop as backstop.
3. Restore follows the attachment: present means relaunch agent resume at
   last_known_cwd; absent means shell as today; stale/missing/guess means
   shell with notice or marked most-recent resume; restore never fails.
   Attachment wins over stored command; agent restore rewrites it. UI
   previews the resume command and auto-runs, with a config flag for
   confirmation.
4. Extend existing cfg-gated process helpers; Unix-first phasing allowed
   only on spike evidence.
5. Ground snapshot wire encoding before extending; old clients must ignore
   the new field.
6. Clients show badge plus details (TUI and Flutter). No new IPC surface
   beyond the snapshot field.

Phases: 1 daemon core (spikes, adapters, sampler, manifest, restore);
2 clients; 3 optional hooks precision. PR 1 phase 1, PR 2 phase 2.

Work plan:

1. Grounding spikes: portable_pty child-PID API per platform; snapshot
   encoding and compat rule; `codex agents` / muse session tooling
   evaluation; muse top-level versus subagent transcript distinction; agy
   storage location. Written finding per spike.
2. Agent adapters (`triaged/src/agent_detect.rs`) with unit tests.
3. Sampler (5-10s jittered) with overhead bound and platform tests.
4. Manifest lifecycle (defaulted field, transition writes, strip on
   demote/shutdown/exit).
5. Restore agent branch plus stub-agent end-to-end suite (primary
   validation) and manual per-agent reboot confirmation.
6. Snapshot, IPC, TUI, Flutter surfacing with widget tests.
7. Docs and config (lifecycle doc, confirmation flag, opt-out, trust
   note).

Validation: stub-agent E2E in CI; `cargo test -p triaged agent_detect`
and session suites; clippy `-D warnings`; fmt check; sampler overhead
bound; LaunchAgent reboot path; auth-expiry degradation to interactive
login.

Risks: residual ambiguity gated not eliminated (hooks escape hatch);
seconds-wide detach race accepted; CLI/storage drift isolated in
adapters; agy/muse fallbacks documented; Unix-first allowed on evidence.
Rollback is additive behind manifest defaults.

Open questions: none. Defaults decided: auto-run resume with shell
fallback (confirmation flag available); detection on by default as
read-only observation.

## Spike Findings

(to be appended as work item 1 completes)

### 2026-09-20T10:26-0700 work item 1 findings

1. portable-pty 0.9.0 `Child::process_id() -> Option<u32>` is real on
   all platforms (unix returns std Child id; Windows uses GetProcessId).
   One API gives the sampler its root PID everywhere. No Unix-first
   phasing needed for PID discovery (descendant enumeration is still
   per-platform work).
2. `SessionSnapshot` crosses flatbuffers
   (`crates/triage-core/schema/triage.fbs`, table SessionSnapshot). Rust
   bindings regenerate via build.rs flatc; Dart via
   `scripts/generate-dart-flatbuffers.sh`. Appending table fields is
   backward/forward compatible, so the attachment rides a new optional
   field plus a new table with no version bump; old clients ignore it.
3. Native introspection rejected for phase 1: `codex agents` is an
   interactive browser with no machine-readable list; `muse
   session-message list` reports ingress unavailable; `muse trace` needs
   explicit log paths. Process plus argv stays primary for all four
   agents; transcript correlation stays secondary.
4. Transcript schemas (keys only, no content read):
   - claude: `~/.claude/projects/<cwd-slug>/<uuid>.jsonl`, slug
     deterministic from cwd.
   - codex: first-line `session_meta` carries `cwd`, `originator`,
     `parent_thread_id`, `thread_source`, `agent_path`. Correlate on
     root threads with cwd match; `originator == "codex-tui"` marks
     interactive (exec originator value unverified, so argv
     classification stays authoritative for headless filtering).
   - muse: `session.jsonl` envelopes; `runtime.session.route_facts`
     record has `cwd` and `pid` for correlation;
     `runtime.session` record has `root_session_id` /
     `parent_task_id` for top-level versus subagent filtering.
5. agy local conversation store unlocated (server-backed
   `/v1/conversations` with a local FTS index; no stable on-disk path
   found). Phase 1 agy support is argv-only (`--conversation <id>`
   capture) with `--continue` fallback for fresh runs. Documented
   limitation.
