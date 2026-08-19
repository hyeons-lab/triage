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
TRIAGE_SKIP_FLUTTER_BUILD=1 cargo install --path crates/triage-hook
```

The shim depends on `triaged` for its IPC client, and `triaged`'s build script
builds the Flutter web client (or fails outright when the SDK is missing). The
shim embeds none of it, so skipping that build is the right call here. Drop the
variable if you want the web client built anyway.

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

The hook configuration lives in `.agents/hooks.json` (or `~/.agents/hooks.json` globally):

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

Restart `triaged` so it picks up the config, and start the agent from inside a
Triage session. Sessions started outside Triage have no `TRIAGE_SESSION_ID`, so
the shim answers `ask` without opening the socket, and the agent behaves exactly
as it does today.

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

## The settings screen

Press **F5** in the TUI to open per-session settings for the selected session.

| Key | Effect |
| --- | --- |
| `y` | Auto-approve tool calls in this session |
| `n` | Always prompt in this session |
| `r` | Follow the configured default again |
| `Esc`, `q`, `F5` | Close |

The three-way choice is deliberate. `r` is not the same as `n`: a session
following the default tracks it if the default later changes, whereas `n` pins
the session off regardless. A session you have never touched follows the default.

While the overlay is open every keystroke is consumed by it, so nothing leaks
into the shell behind it. `Ctrl-Q` still quits.

Overrides live in the daemon's memory only. A daemon restart or a handover drops
them and every session reverts to the configured default, which errs towards
prompting rather than towards silently auto-approving in a session whose owner
has forgotten they enabled it.

F5 is hardcoded rather than read from `[keybindings]`, because the TUI reads none
of that section today; adding a key there would be another setting that parses
and does nothing.

## Turning it off

Any of these is sufficient, from narrowest to broadest:

- Press F5 and then `n` to turn the session off.
- Set `default_enabled_per_session = false` to make judging opt-in per session.
- Set `enabled = false` under `[judge]`.
- Set `"enabled": false` in `.agents/hooks.json`, or delete the file.

## Timeouts

Three bounds are layered, deliberately in this order:

| Bound | Default | What it protects |
| --- | --- | --- |
| `judge.timeout_ms` | 8s | The daemon's wait on the model |
| Shim internal | 10s | A wedged daemon |
| Hook `timeout` | 15s | The shim itself |

Each is comfortably inside the next, so a stall surfaces as a clean `ask` from
the innermost layer that noticed, rather than as a killed process and an agent
left interpreting empty output.
