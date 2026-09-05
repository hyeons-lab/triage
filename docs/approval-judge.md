# Tool-call approval judge

Lets an agent CLI running inside a Triage session auto-approve its own routine
tool calls, while anything risky still stops and prompts you. The decision is
made locally, by the model the daemon already keeps resident for session
summaries. Nothing leaves the machine.

This is not `--dangerously-skip-permissions`. That flag removes the decision
point entirely; this adds one and answers it.

## How a decision is made

Every request passes through three layers, in order:

1. **Deterministic deny rules.** Destructive, credential-reading, or
   outward-facing commands are refused here and never reach the model.
2. **Deterministic allow rules.** A small set of read-only and build commands is
   approved here. This is most real traffic, which also keeps the model off the
   blocking path for the common case.
3. **The model.** Whatever is left is genuinely ambiguous, and the model chooses
   between `allow` and `ask`.

Two properties are worth knowing, because they bound how much the model is
trusted:

- **The model can never deny.** Decode is grammar-constrained to `allow|ask`, so
  emitting `deny` is impossible rather than merely discouraged. A denial the
  model invented would look, to you, identical to one a rule meant.
- **Every failure is an `ask`.** A disabled judge, an unreachable daemon, an
  unloaded model, a timeout, an unparseable payload: all answer `ask`, which is
  precisely what the agent does with no hook installed. The worst a broken judge
  can do is give you back the prompts you already had.

Layer 3 is the summarizer's model. The judge does not load one of its own, so
`[summarizer] enabled = false` removes that layer: the deterministic rules still
run, and everything they do not settle becomes `ask`. That is a safe
configuration, just a quieter one, and worth knowing before you conclude the
judge is ignoring you.

The default resident bundle is `LFM2-2.6B-GGUF` (`Q4_K_M`). If customizing the
underlying summarizer model bundle, note that the approval judge requires single-token
grammar constraint (`allow|ask`) at decode step 0; reasoning models (e.g. `LFM2.5`) that
emit mandatory `<think>` blocks before the decision token will fail grammar evaluation
and fall back to `ask`.

The hook blocks the agent's loop for as long as a decision takes, so the layering
is also a cost decision. Layers 1 and 2 answer in under 10ms. Layer 3 costs about
40ms on Apple silicon, where the engine runs on Metal, and closer to 0.7s on the
CPU path, which is what you get on a platform without a Metal build.

Allow rules match a leading token sequence, and only on a command containing no
shell metacharacter at all. That guard is what makes prefix matching safe: with
it, `git status; rm -rf ~` cannot match the `git status` rule. Deny rules also
inspect every segment a shell would run, not just the first, so a destructive
command hidden behind a benign one is still caught.

## Setup

Install the shim so it is on `PATH`:

```bash
cargo install --path crates/triage-hook
```

The shim is lightweight and decoupled from `triaged`, depending only on `triage-core` for
protocol types and deterministic rules. It does not require building the Flutter web bundle.

Turn judging on or customize it in `~/.config/triage/config.toml`. Both `enabled`
and `default_enabled_per_session` are `true` by default, so auto-approval runs
out of the box for all sessions:

```toml
[judge]
# Already the default; set it to false to switch the judge off entirely.
enabled = true
# Already the default; set to false to make judging opt-in per session.
default_enabled_per_session = true
# Extra rules, additive to the built-ins. Config can extend the deny list but
# never weaken it, and an allow entry is still subject to the metacharacter guard.
deny_substrings = ["terraform apply"]
allow_commands = ["npm test", "pnpm lint"]
```

The hook configuration lives in `~/.agents/hooks.json` globally (or `~/.gemini/config/hooks.json` for Antigravity):

```json
{
  "triage-approval-judge": {
    "enabled": true,
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [{ "type": "command", "command": "triage-hook", "timeout": 15 }]
      }
    ]
  }
}
```

For Meta Muse CLI (`muse`), hooks are configured in `~/.config/muse/settings.json` (or `$XDG_CONFIG_HOME/muse/settings.json`):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "triage-hook",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

When `muse` executes a tool call, `triage-hook` automatically detects Muse's PreToolUse payload signature (via `tool_use_id` / `toolUseId` or the `MUSE_TOOL_USE_ID` environment variable) and formats responses to match Muse's protocol, including `updatedInput` on auto-approval and `permissionDecisionReason` on denial. Explicit format overrides can also be passed via `--format=muse` or `TRIAGE_HOOK_FORMAT=muse`.

Restart `triaged` so it picks up the config, or run `triaged reload`. When started
inside a Triage session, judging honors that session's policy override (toggleable via
**`a`** in the TUI or the Auto-Approval switch in Flutter). Agent sessions running outside
a Triage PTY follow the daemon's configured `default_enabled_per_session` policy, with safe
in-process fallback to `ask` if the daemon is not running.

## Reading the audit log

The daemon logs one structured event per decision, at `info`, carrying the
command verbatim. This is the record of what was approved on your behalf, so it
is a feature rather than debug output:

```bash
RUST_LOG=triaged::session=info triaged
```

Each event carries `session_id`, `tool`, `command`, `decision`, `source`, and
`reason`. `source` is the important one: `allow_rule` and `deny_rule` mean a rule
decided, `model` means the model did, and `fallback` means nothing could decide
and you were asked.

## The settings screen and keybindings

In the Ratatui local terminal TUI:
- Press **`F5`** to open the centered Approval Judge settings overlay.
- Inside the overlay: press **`y`** (enable), **`n`** (disable), **`r`** (reset to default), or **`Esc`** / **`q`** / **`F5`** to close.

In the Flutter client:
- Toggle the **Auto-Approve** switch in the rail header.
- Open the tabbed **Settings Dialog** $\rightarrow$ **Approval Judge** tab to inspect decision history and manage custom allow/deny rules.

## Cross-Platform Portability

- **macOS & Linux**: Full Unix domain socket IPC (`/tmp/triage-<uid>/triage.sock` or `$XDG_RUNTIME_DIR/triage/triage.sock`) with zero-downtime descriptor handover and resident model inference.
- **Windows**: `triaged` daemon supports Windows named pipes (`\\.\pipe\triage-<user>`); `triage-hook` on Windows falls back to offline deterministic rule evaluation with safe fallback to `ask`.

## Turning it off

Any of these is sufficient, from narrowest to broadest:

- Press `a` in the TUI or toggle the switch in Flutter to turn the session off.
- Set `default_enabled_per_session = false` to make judging opt-in per session.
- Set `enabled = false` under `[judge]`.
- Set `"enabled": false` in `~/.agents/hooks.json`, or delete the file.

## Timeouts

Three bounds are layered, deliberately in this order:

| Bound | Default | What it protects |
| --- | --- | --- |
| `judge.timeout_ms` | 8s | The daemon's wait on the model |
| Shim internal | 10s | A wedged daemon socket |
| Hook `timeout` | 15s | The shim process itself |

Each is comfortably inside the next, so a stall surfaces as a clean `ask` from
the innermost layer that noticed, rather than as a killed process and an agent
left interpreting empty output.
