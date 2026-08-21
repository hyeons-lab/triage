# triage-hook

A lightweight, decoupled CLI lifecycle-hook shim that asks Triage whether an agent tool call may run.

`triage-hook` sits between autonomous AI agent CLIs (such as **Antigravity**, **Claude Code**, or other agent runtimes) and the `triaged` daemon, inspecting proposed tool calls and commands before execution to auto-approve routine, safe operations while ensuring risky actions stop for user confirmation.

---

## The Core Invariants

`triage-hook` is designed so it **can never break an agent session**:

1. **Always exits 0**: It never fails with a non-zero exit code or uncaught panic.
2. **Always prints exactly one valid JSON decision**: The agent always receives an unambiguous decision payload on stdout.
3. **Failures always degrade to `ask`**: If the daemon is unreachable, the socket is missing, the payload cannot be parsed, or an evaluation times out, `triage-hook` answers `ask` (prompting the user interactively). The worst a broken hook can do is revert to standard manual confirmation prompts.
4. **Strictly bounded timeout (10s)**: It enforces its own internal 10-second timeout—comfortably within typical agent hook timeouts (15s–30s)—so it returns `ask` cleanly rather than being SIGKILLed mid-execution.
5. **Zero model overhead**: `triage-hook` is a fast binary with no embedded model. In-memory model inference runs inside the resident `triaged` daemon.

---

## Installation

### From Source

```bash
cargo install --path crates/triage-hook
```

Or install from crates.io once published:

```bash
cargo install triage-hook
```

### Prebuilt Binaries

`triage-hook` is included in the prebuilt `Triage-cli-<os>-v<version>` release archives on GitHub.

---

## Agent Configuration

### Antigravity

Add the hook to `~/.gemini/config/hooks.json` (or project-level `.gemini/hooks.json`):

```json
{
  "triage-approval-judge": {
    "enabled": true,
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

### Claude Code

Add the hook to `~/.agents/hooks.json`:

```json
{
  "triage-approval-judge": {
    "enabled": true,
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

---

## Multi-Format Auto-Detection

`triage-hook` automatically detects the calling agent format based on payload signatures:

- **Antigravity / Gemini Format**: Detects `conversationId` / `stepIdx` and outputs `decision`, `reason`, and granular `permissionOverrides` arrays (e.g. `command(git status)`, `file(...)`, `tool(...)`).
- **Claude Code Format**: Detects `hook_event_name` and outputs `hookSpecificOutput` with `permissionDecision` and `permissionDecisionReason`.
- **Generic Format**: Outputs standard `{ "decision": "allow|ask|deny", "reason": "..." }`.

You can also explicitly force a format via `--format=<antigravity|claude|generic>` or the `TRIAGE_HOOK_FORMAT` environment variable.

---

## Offline Resiliency

If the `triaged` daemon is stopped or unreachable, `triage-hook` automatically loads `~/.config/triage/config.toml` and evaluates **Layer 1 (deterministic deny)** and **Layer 2 (deterministic allow)** rules in-process. If the command cannot be settled deterministically offline, it safely defaults to `ask`.

---

## Documentation

See [`docs/approval-judge.md`](../../docs/approval-judge.md) for full architecture details, rule customization, and audit logs.
