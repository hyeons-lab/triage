# Plan 000126-01: local-model approval judge for agent tool calls

## Thinking

### The problem

`agy` (the Antigravity CLI, `~/.local/bin/agy`) supports lifecycle hooks. Its
`PreToolUse` hook receives the tool call as JSON on stdin and returns a decision
on stdout:

```json
{"toolCall": {"name": "run_command", "args": {"CommandLine": "npm test"}}, "stepIdx": 19, ...}
```

```json
{"decision": "allow" | "deny" | "ask" | "force_ask", "reason": "..."}
```

Contract is documented at
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`.

We want a local model to answer that question so routine commands stop
interrupting the user, while anything genuinely risky still stops and routes to
whichever client the user is at. That second half is what Triage already does,
so the judge belongs next to it.

Two properties of the hook drive the whole design:

1. It runs **synchronously and blocks the agent loop** (stated under "Current
   Limitations" in the hook docs).
2. It fires on **every** tool call, including trivia like `ls`.

### Rejected approaches

**Screen-scraping the session buffer.** Triage sees rendered PTY bytes, so a
judge reading the terminal grid would be guessing at a repainted TUI frame
rather than reading a command. `PreToolUse` hands us the exact `CommandLine`
string. Structured input wins outright, and it also means no keystroke injection
and no input-lease contention with the TUI or the Flutter client.

**A standalone `llama-server`.** Works, but stands up a second resident model, a
second config surface, and a second thing to supervise, when `triaged` already
keeps a warm `CeraEngine` on a dedicated worker thread
(`crates/triaged/src/summarizer.rs`).

**A hook binary that links cera directly and loads per invocation.** This is the
obvious "no server needed" reading, and it is the one thing the latency budget
cannot absorb. Every hook invocation would pay a cold engine load: 664 MB of
GGUF today, 1.48 GB after the 2.6B bump, on every `ls`. The constraint is model
*residency*, not transport.

**Chosen:** a judge job on the daemon's existing cera worker, reached over the
existing IPC socket by a thin shim binary that loads nothing. One resident
model, already paid for.

### Grammar-constrained decode

cera 0.4.0 (the version pinned in `Cargo.lock`) exposes
`GenerateOpts::grammar: Option<Arc<Grammar>>` and applies a per-step logit mask
(`cera/src/grammar.rs`, `GrammarMask::apply`). Verified present in the vendored
registry source, so no cera bump is required.

Constraining output to `allow|deny|ask` means the decision is a single decoded
token. No JSON parsing, no risk of the model narrating instead of deciding, and
the latency floor is one short prefill plus one token. The optional `reason`
string is deliberately left out of v1: it doubles decode cost on the blocking
path and agy only shows it to the user.

### Trust boundary

The model is not the safety mechanism. Order of evaluation in the judge:

1. **Deterministic denylist** (never reaches the model): `rm -rf`, force-push,
   `curl | sh`, writes under `~/.ssh`, `~/.gemini/antigravity-oauth-token`,
   keychain access. Returns `deny`.
2. **Deterministic allowlist** (never reaches the model): `cargo check`,
   `cargo fmt`, `git status`, `ls`, `rg`, and friends. Returns `allow`. This is
   the bulk of real traffic, and it keeps the model off the hot path entirely.
3. **The model** decides the ambiguous middle, answering `allow` or `ask` only.
   It is never allowed to return `deny`, because a deny it invents is
   indistinguishable to the user from a deny the denylist meant.

Every path that fails, times out, or returns something unparseable falls through
to `ask`. Fail closed. `ask` is not a failure state: it is the normal agy
permission prompt, which is exactly what happens today without any of this.

### Session identity

The hook process runs inside agy's process tree, inside the PTY, so it needs to
know which Triage session it belongs to. `triaged` currently sets only `TERM`
and `COLORTERM` on spawn (`crates/triaged/src/session.rs:4449`). Adding
`TRIAGE_SESSION_ID` there gives the shim its identity for free, and it survives
handover because adopted PTYs keep their environment.

If the variable is absent (agy running outside Triage), the shim returns `ask`
and exits without touching the socket. Running agy outside Triage then behaves
exactly as it does today.

### Per-session enablement

The daemon owns the state, per the project's first architectural rule, so the
TUI and the Flutter client toggle the same thing rather than each keeping their
own idea of it. Config supplies the default; the per-session override lives in
`ManagedSession` and rides along in `SessionContextRow` so clients can render
the current state without a second round trip.

The TUI has no modal or overlay system at all today: `draw` is a sidebar plus a
terminal pane, and the `keybindings.overview` / `keybindings.search` config keys
have no implementation behind them. So the settings screen is greenfield, and it
is worth building the overlay primitive properly since overview and search will
both want it later.

### Model bump

Current summarizer default is `LFM2.5-1.2B-Instruct-GGUF` / `Q4_0`
(`crates/triage-core/src/config.rs:486`).

Target is `LFM2.5-2.6B-GGUF`. Verified against the LeapBundles registry:

- The id has **no `-Instruct` segment**, unlike the 1.2B. Not extrapolable.
- Quants available: `Q4_0`, `Q4_K_M`, `Q5_K_M`, `Q8_0`.
- `Q4_0` is 1.48 GB versus 664 MB today.
- `inference_type` is `llama.cpp/text-to-text`, so cera loads it unchanged.

Two knock-on effects, both deliberate:

- The engine is shared with the summarizer, so rail labels change too. Better
  labels, more RAM, slower per summary. Acceptable.
- `context_size = 1024` was sized for one terminal screen. A judge prompt
  carrying a policy preamble plus a long `CommandLine` wants 2048. If the two
  workloads end up wanting genuinely different windows, that is the point to
  split into two engines, not before.

Going with `Q4_K_M` rather than `Q4_0`: for a component whose entire job is
judgment on ambiguous input, quality per byte matters more than decode
throughput, and residency means the load cost is paid once.

## Plan

### Phase 1: judge core

- New `crates/triaged/src/judge.rs`.
- `JudgeRequest { session_id, tool_name, command_line, cwd }` and
  `JudgeDecision { Allow, Deny, Ask }`.
- Deterministic denylist and allowlist as ordered rule sets, evaluated before
  any inference. Pure functions, table-driven, unit-tested standalone.
- `judge_with_model` builds the chat prompt, sets
  `GenerateOpts::grammar` to a GBNF alternation over `allow|ask`, decodes with
  `max_tokens` of 2, maps the token back to a decision.
- Every decision path emits a structured `tracing` event carrying the command,
  the decision, and which layer produced it. This log is the audit trail; treat
  it as a feature, not debug output.

### Phase 2: worker priority

- Extend the summarizer worker to accept a two-variant job enum
  (`Summarize` / `Judge`), or a second `SyncSender` drained with priority.
- Judge jobs jump the queue: a judge call blocks a human-facing agent loop,
  while a rail label is cosmetic.
- Preempt an in-flight summary using the session's `cancel_handle()`
  (`cera/src/session.rs:774`) rather than waiting out a 180-token detail
  summary. Cancelled summaries are simply re-enqueued by the existing debounce
  on the next settle, so nothing is lost.
- Judge jobs are request/response, unlike the fire-and-forget summarize jobs, so
  the job carries a reply channel.

### Phase 3: IPC surface

- `WireRequest::JudgeToolCall(JudgeRequest)` and
  `WireSuccess::JudgeDecision(JudgeDecision)` in `crates/triaged/src/ipc.rs`
  (enums at `:531` and `:585`, dispatch at `:1084`).
- Returns `Ask` rather than an error when the summarizer is disabled, the model
  failed to load, or the session has the judge turned off. The shim should never
  have to interpret an error string to stay safe.
- Bound the daemon-side wait so a wedged worker cannot hold the hook past agy's
  timeout.

### Phase 4: session environment

- Set `TRIAGE_SESSION_ID` alongside `TERM` / `COLORTERM` at
  `crates/triaged/src/session.rs:4449`.
- Confirm it survives handover adoption (it should: env is fixed at spawn and
  adopted PTYs are not respawned). Cover with a handover test.

### Phase 5: hook shim

- New `crates/triage-hook` binary, deliberately minimal: read stdin JSON, read
  `TRIAGE_SESSION_ID`, one IPC round trip, print `{"decision": ...}`.
- Links `triaged` for `IpcClient` only. No cera dependency, so startup stays in
  the low milliseconds.
- Absent env var, absent socket, dead daemon, malformed payload: print
  `{"decision":"ask"}` and exit 0. It must never be the reason agy breaks.
- Internal timeout comfortably under the hook's own, so we produce `ask`
  ourselves rather than being killed mid-write.

### Phase 6: per-session policy

- `judge_enabled: Option<bool>` on the session state, `None` meaning "inherit
  the config default".
- Surface it on `SessionContextRow` (`crates/triage-core/src/session.rs:146`) so
  clients render current state from the data they already pull.
- `WireRequest::SetSessionJudgePolicy` to toggle, mirrored over the WebSocket
  adapter so the Flutter client can adopt it without further daemon work.

### Phase 7: TUI settings screen

- Build a reusable overlay primitive first (centered rect, `Clear`, focus
  capture, Esc to dismiss). Overview and search will both want it.
- Settings overlay scoped to the selected session: judge on/off/inherit, plus a
  read-only line showing the effective default and the loaded model.
- Bind it to a new `keybindings.settings` key, defaulting to something that does
  not collide with the existing F-keys or the Alt navigation pairs.
- Keystrokes route to the overlay, not the PTY, while it is open. This is the
  part most likely to regress input handling, so it gets its own tests.
- Flutter client settings sheet is explicitly **out of scope** for this branch.
  The daemon surface is designed so it can land independently.

### Phase 8: model and config

- `bundle_id = "LFM2.5-2.6B-GGUF"`, `quant = "Q4_K_M"`, `context_size = 2048` in
  `SummarizerConfig::default()` (`crates/triage-core/src/config.rs:483`).
- New `[judge]` config section: `enabled`, `default_enabled_per_session`,
  `deny_patterns`, `allow_patterns`, `timeout_ms`.
- Retire or repurpose the dead `[approval] patterns` key
  (`crates/triage-core/src/config.rs:385`), which parses and validates but has
  no consumer anywhere in the workspace. Decide explicitly rather than leaving
  two overlapping keys.
- Measure judge round-trip latency at 2.6B before committing to the default. If
  a warm decision does not land comfortably inside a second, reconsider the
  quant or keep a smaller model for the judge alone.

### Phase 9: wiring and docs

- `.agents/hooks.json` in this repo registering `triage-hook` for `PreToolUse`
  with `matcher: "run_command"`, plus an explicit `timeout`.
- `docs/approval-judge.md`: the contract, the layered rule order, how to disable
  it, and how to read the audit log.
- Note explicitly that this is not to be combined with
  `--dangerously-skip-permissions`, which bypasses the decision path entirely.

### Phase 10: tests

- Rule tables: denylist and allowlist hits, ordering, and the guarantee that the
  model can never return `deny`.
- Judge fallback: disabled summarizer, unloaded model, cancelled generate, and
  worker timeout all produce `Ask`.
- Shim: missing env var, unreachable socket, malformed stdin, daemon error, all
  produce `{"decision":"ask"}` and exit 0.
- IPC round trip for the new variants.
- TUI: overlay open/close, keystrokes not leaking to the PTY while open, toggle
  round-tripping to the daemon.
- Handover: `TRIAGE_SESSION_ID` survives adoption.

### Phase 11: validation

Full CI-equivalent set locally before pushing:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps --locked
cargo test --workspace
```

Then `/review-fix-loop high` until clean or only micro-nitpicks remain.

### Sequencing

Phases 1 through 5 are the working vertical slice: a real decision reaching agy
through a real hook. That is the point to stop and try it against actual agy
traffic before building the settings UI on top, because live traffic is what
tells us whether the rule tables are drawn in the right place and whether 2.6B
is fast enough on the blocking path.
