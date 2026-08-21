# Configuration Reference

Triage is configured through a single TOML file located at:

```
~/.config/triage/config.toml
```

(On Windows: `%USERPROFILE%\.config\triage\config.toml` or `%APPDATA%\triage\config.toml`).

The configuration file is optional. All fields have sensible defaults, and missing keys or tables use their built-in default values. Unknown keys are rejected with an error on daemon startup.

---

## Full Example `config.toml`

```toml
[general]
default_shell = "/bin/zsh"

[ui]
theme = "catppuccin-mocha"
sidebar_width_percent = 22
group_by = "worktree"        # "worktree", "repo", or "flat"

[attention]
idle_threshold_ms = 1500
notify_on_awaiting = true
notify_sound = true

[agents]
known = ["claude", "aider", "codex", "cline", "continue"]

[agents.custom_pack]
process_names = ["my-custom-agent"]
prompt_patterns = ['\? for shortcuts', '\[y/n\]']

[remote]
bind = "0.0.0.0:7777"
require_pairing = true
pair_approval_tailnet_users = []
pair_approval_trust_local_peers = true

[mcp]
tcp_bind = "127.0.0.1:7778"

[grpc]
enabled = false
# bind = "127.0.0.1:50051"

[judge]
enabled = true
default_enabled_per_session = true
timeout_ms = 8000
deny_substrings = ["terraform apply", "drop table"]
allow_commands = ["npm test", "pnpm lint", "cargo check"]

[keybindings]
overview = "ctrl+e"
search = "ctrl+f"
next_attention = "g w"
cycle_agents = "g a"
cycle_current_repo = "g r"
pause_all = "ctrl+shift+p"

[summarizer]
enabled = true
bundle_id = "LFM2-2.6B-GGUF"
quant = "Q4_K_M"
context_size = 1024
max_tokens = 24
detail_max_tokens = 180
settle_ms = 1500
min_regen_ms = 5000

[update]
check = true
interval_hours = 6
channel = "stable"
```

---

## Section Details

### `[general]`

General environment and process settings.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `default_shell` | string | `"/bin/zsh"` | Default interactive shell to spawn for new terminal sessions when `$SHELL` is unset. |

---

### `[ui]`

User interface defaults for TUI and graphical clients.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `theme` | string | `"catppuccin-mocha"` | Visual color theme name. |
| `sidebar_width_percent` | integer | `22` | Percentage of screen width allocated to the session sidebar (must be between 1 and 80). |
| `group_by` | string | `"worktree"` | Session grouping mode in the rail: `"worktree"`, `"repo"`, or `"flat"`. |

---

### `[judge]`

Settings for the resident tool-call approval judge. See [Approval Judge Documentation](approval-judge.md) for architecture and lifecycle hook setup.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Master switch for tool-call judging across the daemon. When `false`, all queries fall back to `ask`. |
| `default_enabled_per_session` | boolean | `true` | Default auto-approval policy for newly spawned sessions. Per-session overrides can be toggled interactively with **`a`** in the TUI or the Auto-Approve switch in Flutter. |
| `timeout_ms` | integer | `8000` | Maximum time (in milliseconds) the daemon may spend evaluating a single decision before safely falling back to `ask`. |
| `deny_substrings` | array of strings | `[]` | Extra substrings that trigger an instant deterministic denial. Additive to built-in security deny rules. |
| `allow_commands` | array of strings | `[]` | Extra command prefixes that are auto-approved without invoking the model (e.g. `"npm test"`). Must not contain shell metacharacters (`;&|$\`><()`). |

---

### `[summarizer]`

Local LLM inference settings for automated session activity summaries and status badges.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Master switch for local LLM inference. When `false`, background summaries and Layer 3 model judging are disabled. |
| `bundle_id` | string | `"LFM2-2.6B-GGUF"` | HuggingFace / LeapBundles GGUF model repository. |
| `quant` | string | `"Q4_K_M"` | Quantization level (e.g., `Q4_K_M`, `Q4_0`). |
| `context_size` | integer | `1024` | Maximum context tokens for inference window. |
| `max_tokens` | integer | `24` | Maximum tokens to generate for one-line rail summaries. |
| `detail_max_tokens` | integer | `180` | Maximum tokens for detailed multi-sentence popover summaries. |
| `settle_ms` | integer | `1500` | Quiet duration (in ms) before re-summarizing active session output. |
| `min_regen_ms` | integer | `5000` | Minimum throttle interval between consecutive summary updates for a session. |
| `cache_dir` | string (optional) | `None` | Custom directory for caching model weights. Defaults to `~/.cache/triage/models`. |

---

### `[remote]`

Remote WebSocket and HTTP server configuration.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `bind` | string | `"0.0.0.0:7777"` | Network address and port to bind for HTTP/WebSocket traffic. Set to `"127.0.0.1:7777"` for local loopback only. |
| `require_pairing` | boolean | `true` | When `true`, remote clients must complete a device-code + PIN authentication handshake. |
| `pair_approval_tailnet_users` | array of strings | `[]` | List of Tailscale user logins (e.g. `["you@example.com"]`) allowed to approve pairing remotely via `/pair`. |
| `pair_approval_trust_local_peers` | boolean | `true` | Whether same-host / loopback requests to `/pair` are auto-trusted. Set to `false` when running behind a local reverse proxy. |
| `tls_cert` | string (optional) | `None` | Path to TLS certificate file (must be set alongside `tls_key`). |
| `tls_key` | string (optional) | `None` | Path to TLS private key file (must be set alongside `tls_cert`). |
| `web_assets_path` | string (optional) | `None` | Custom filesystem path to override embedded web client assets. |

---

### `[attention]`

Activity and attention routing heuristics.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `idle_threshold_ms` | integer | `1500` | Milliseconds of inactivity before a session is marked idle. |
| `notify_on_awaiting` | boolean | `true` | Emit system notifications when a session enters the "awaiting input" state. |
| `notify_sound` | boolean | `true` | Play audible alert sound on attention notifications. |

---

### `[agents]`

CLI agent process detection and prompt patterns.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `known` | array of strings | `["claude", "aider", "codex", "cline", "continue"]` | Known agent process executable names for automatic status badge tagging. |
| `custom_pack.process_names` | array of strings | `[]` | Additional agent executable names to track. |
| `custom_pack.prompt_patterns` | array of strings | `[]` | Regular expression patterns matching agent interactive prompts. |

---

### `[mcp]`

Model Context Protocol (MCP) server configuration.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `tcp_bind` | string | `"127.0.0.1:7778"` | TCP address and port for MCP server when run in TCP listener mode. |

---

### `[grpc]`

gRPC server configuration (optional high-performance backend).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `false` | Enable gRPC endpoint. |
| `bind` | string (optional) | `None` | Socket address for gRPC listener (required when `enabled = true`). |

---

### `[update]`

Automated release update check configuration.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `check` | boolean | `true` | Periodically poll GitHub releases for new published versions. |
| `interval_hours` | integer | `6` | Polling interval in hours (must be > 0). |
| `channel` | string | `"stable"` | Release channel to monitor (`"stable"`). |

---

### `[keybindings]`

Configurable shortcut keys in the TUI client.

| Key | Default | Action |
| --- | --- | --- |
| `overview` | `"ctrl+e"` | Open overview grid. |
| `search` | `"ctrl+f"` | Open session search. |
| `next_attention` | `"g w"` | Focus next session awaiting user attention. |
| `cycle_agents` | `"g a"` | Cycle focus among running agent sessions. |
| `cycle_current_repo` | `"g r"` | Cycle focus among sessions in the current repository. |
| `pause_all` | `"ctrl+shift+p"` | Pause/resume background agent processing. |
