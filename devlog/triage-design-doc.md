# Triage: Attention-Routing Terminal Supervisor

> *"Eyes on every terminal, from anywhere."*

## The Problem

You have ~30 tabs open across ~15 worktrees. Some are regular dev terminals; others run AI agents (Claude Code, Aider, Codex, Cline). Two specific pains:

1. **Finding the right tab is slow.** A flat list of "zsh, zsh, zsh, claude, zsh, aider, zsh..." gives you nothing. You don't know what's where, what's running, what just finished, what's waiting on you.
2. **Agent tabs need attention asynchronously, and you miss it.** An agent finishes a 4-minute task, prompts you, and sits there for 20 minutes while you stare at a different tab. There's no signal.

A third pain falls out of solving the first two:

3. **You can't check or respond to your terminals from anywhere else.** Closing the laptop kills the dev loop. Checking from your phone at lunch isn't a thing. Picking up agent prompts from a different machine isn't a thing.

## Project Overview

Triage is an **terminal supervisor with attention routing and cross-device access**. It runs as a daemon on your machine, exposing your terminal sessions to a fast local TUI, a mobile-friendly web client, and AI agents via MCP. Sessions are auto-classified, grouped by repo/worktree, and tagged with status (running / idle / awaiting input / error). The "next tab that needs you" is one keypress away — and accessible from your phone over Tailscale.

The remote-access story generalizes Claude Code's remote-desktop UX to *any* terminal — your shells, your dev servers, your Aider session, your Codex session — under one navigation surface.

**Core stack:**
- **Daemon + TUI:** Rust (Tokio for async I/O)
- **TUI rendering:** Ratatui + `crossterm`
- **Terminal engine:** TBD via one-day spike — `wezterm-term` vs `alacritty_terminal`
- **PTY:** `portable-pty`
- **Human clients (web + iOS + Android + optional desktop):** Flutter app shell, one codebase, four artifacts
- **Terminal rendering:** xterm.js (via JS interop) on Flutter Web; xterm.dart on Flutter iOS / Android / Desktop
- **Remote transport (human clients):** WebSocket + JSON over TLS, via `web_socket_channel`
- **Agent transport (local):** MCP server (stdio + optional TCP)
- **Agent transport (remote, optional):** gRPC + mTLS via `tonic`
- **Logs/search:** Per-session log files + `ripgrep`

---

## 🏗 Architecture & Deep Dives

### 1. Daemon-Client Architecture *(the central design decision)*

Triage is a daemon. All session state — PTYs, scrollback, metadata, status — lives in the daemon process. Every UI surface is a **client** of the daemon. The TUI is privileged only by being co-located.

```
                    ┌── TUI client            (Rust + Ratatui, terminal-mode)
                    ├── Flutter client        (web PWA, iOS, Android,
[Triage daemon] ────┤                          + optional macOS/Linux/Windows desktop;
                    │                          xterm.js on web, xterm.dart on native)
                    ├── MCP server            (local AI agents)
                    └── gRPC                  (remote AI agents, optional)
```

**Why daemon-first:** "remote desktop for any terminal" falls out for free. The TUI is one view; the Flutter client (web / iOS / Android / optional desktop) is another. Both attach to the same state. Read and drive from either. Stay in sync. **Flutter Desktop coexists with the Ratatui TUI** — both are clients of the same daemon. Pick by preference.

**Process model:**
- `triage` (default) — starts Ratatui local client. Listens for additional clients on a local Unix socket and configured network ports.
- `triaged` — headless daemon. No TUI. For dev VMs / cloud machines.
- `triage connect <addr>` — TUI client connecting to a remote daemon over WebSocket.
- `triage pair` — initiate the pairing flow for a new device (shows a QR code).

**Local TUI ↔ daemon IPC:** when co-located, the TUI talks to the daemon over an in-process channel (no serialization). The same logical session API is exposed externally over Unix socket and WebSocket. **One API, multiple transports.** Define the daemon's session interface once (Rust trait + types); bind it to each transport as a thin adapter.

**Multi-client semantics:** many clients can attach to the same session simultaneously, but input is controlled by an explicit ownership model. Clients attach as observers by default; one client at a time holds the interactive input lease for a session. A focused local TUI can acquire the lease immediately. Remote clients and agents must request or take over the lease, producing a visible status event for every attached client. Status changes (e.g., `awaiting-input`) broadcast to all attached clients. This avoids silent multi-writer races while still allowing phone handoff, remote intervention, and agent-driven input.

### 2. Terminal Engine & State Management

- **Engine spike** (acceptance-gated, not time-box-only): `wezterm-term` vs `alacritty_terminal`. Both are production-grade VT state machines; wezterm-term has the cleaner public API and the friendlier license. Pick only after testing resize, late attach, alt-screen, mouse reporting, bracketed paste, scroll regions, reconnect, and replay from log.
- **Daemon owns canonical VT state.** PTY I/O lives in dedicated Tokio tasks that update terminal state behind a daemon-owned session actor. Output also tees to a per-session append-only log file. Clients may render locally, but the daemon's grid snapshot, scrollback cursor, sequence numbers, and resize state are the source of truth.
- **TUI client** queries grid snapshots/diffs from the daemon and renders via Ratatui.
- **Flutter clients** may consume raw PTY bytes for efficient rendering after attach, but initial attach and reconnect start from daemon snapshots. Terminal rendering is platform-specific: on Flutter Web, **xterm.js** is embedded inside the Flutter widget tree via `HtmlElementView` and `dart:js_interop`; on Flutter native targets (iOS, Android, desktop), **xterm.dart** parses VT escape sequences directly. Both engines are wrapped in a common Flutter widget API (`TerminalPane`). The shared interface covers byte attach/detach, snapshot load, incremental write, status, resize, and lifecycle. It does not try to hide everything: focus handling, selection / copy, theming surface (CSS for xterm.js vs Dart theme objects for xterm.dart), accessibility tree, and layout hit-testing remain platform-branched, handled with `kIsWeb` checks or conditional imports.

### 3. Local UX: Sidebar, Grouping, Attention Routing *(the heart of the local product)*

Navigation primitive: a **repo-grouped sidebar with status pills.**

```
katatui/feat/auth-rework      [1/3]
  ● claude   · waiting        <── highlighted, needs you
  ● zsh      · running   2m
  · zsh      · idle
inference_engine/main         [1/2]
  ● aider    · working   8m
  · zsh      · npm dev    running
home                          [0/2]
  · zsh
  · zsh
```

Groups collapse/expand. Header shows `[agents-waiting / agents-total]`. Repos come from inferred context (§6).

**"Needs-response" detection.** A tab transitions to `awaiting-input` when any of these fire:
1. **MCP-reported:** agent calls `set_status("waiting")` — most accurate.
2. **Heuristic:** terminal idle >N seconds AND last output matches a configured prompt pattern (`[Y/n]`, `(y/N)`, trailing `?`, known agent prompt strings).
3. **Process state:** foreground process is blocked on stdin and has been idle.
4. **Pattern packs ship with Triage** for Claude Code, Codex, Aider, Cline, Continue. User can add custom packs in TOML.

**Agent tab classification:**
- Foreground process matches a known agent CLI (`claude`, `aider`, `codex`, ...)
- Session was created through the MCP `create_session` tool
- User-configurable title/process pattern list
- Manual toggle (`mark-as-agent` action)

**Attention-routing hotkeys** (the keys that earn the product):
- `Tab` / `Shift+Tab` — next/prev tab (position-based, the floor)
- `g w` — jump to next `awaiting-input` tab *(the killer hotkey)*
- `g a` — cycle only agent tabs
- `g r` — cycle only tabs in current repo
- `[` / `]` — back/forward through attention history (the tabs you've actually been switching between, not file order)
- `b` — bury current tab; stops counting toward "needs-attention" until state changes

**Notification surface:** when a tab enters `awaiting-input` and isn't focused, sidebar badge appears; optional OS notification via `notify-rust`; optional sound. Configurable globally and per-tab. On the web client: PWA + Web Push for mobile notifications.

### 4. Remote Access: Flutter Client *(the cross-device headline)*

Triage generalizes Claude Code's remote-desktop pattern to *any* terminal. From your phone or any browser, you can see and drive every session running in your daemon.

**Transport:** WebSocket + JSON over TLS, consumed in Flutter via `web_socket_channel` (works across web, mobile, desktop).

**Frontend architecture:** Flutter app shell, one codebase producing four artifacts (web PWA, iOS native, Android native, optional desktop). Terminal rendering is per-target — see §2.

**Why the hybrid:** xterm.js is the most mature terminal emulator on the web (used by VS Code, Tabby, Hyper). xterm.dart is the only credible Dart-native option for Flutter native targets and is production-proven on iOS / Android via Flutter Server Box. Flutter unifies the shell; each target uses the best-of-breed engine.

**Scenarios it has to nail:**
- **At lunch:** open phone, see which agents are waiting, respond to one, lock phone.
- **From the couch:** laptop's still in the office; check on it from another room.
- **Cross-machine:** dev VM in cloud runs `triaged`; drive it from your laptop's web client.

**Pairing & auth:**
- First-time remote setup: TUI (or `triage pair`) shows a QR code. Scan from phone. QR contains daemon pubkey + connection info; pairing exchange creates a per-device bearer token stored on the phone.
- Remote transports require authentication and encryption. No anonymous WebSocket access.
- Local transports use local trust boundaries first: in-process channels need no auth, Unix sockets are owner-only filesystem objects, and stdio MCP inherits the trust of the spawning process. Add explicit local tokens only when TCP or cross-user access is enabled.
- TLS for network transports. Self-signed certs by default; cert injection for users with their own CA.

**Networking:**
- Local network: just works.
- Across NAT: **lean on Tailscale or WireGuard.** Document the setup. **Do not build relay infrastructure** — there's no business model for a self-hosted dev tool to operate a hosted relay, and Tailscale already solves it cleanly.
- Optional much later: open relay protocol so power users can self-host a relay if they want.

**Push notifications:**
- Android (native + PWA via Web Push): full support via FCM.
- iOS native: APNs via `firebase_messaging` or platform channel. This is the reason the iOS native app matters — iOS Safari has no Web Push API.
- iOS Safari PWA: graceful degrade to in-app badge + lightweight polling; banner suggests native-app install for reliable notifications.

**UX parity with TUI:**
- Same repo-grouped sidebar, status pills, attention badges.
- Tap a tab to attach; full terminal pane inside.
- Same `awaiting-input` cycling (touch gestures + hotkeys).
- Push notifications when a tab enters `awaiting-input`.
- Approval-gate prompts (§8) render as native-feeling sheets on mobile.

### 5. AI Agent Integration

**MCP server (local agents) — primary integration surface.**
Stdio transport in the common case; optional TCP for headless setups.

Tool surface:
- `list_sessions()` → `[{id, title, repo, branch, worktree, status, ai_note, is_agent}]`
- `create_session({title?, cwd?, shell?})` → `{session_id}`
- `inject_input({session_id, keys})` — keys are raw bytes or named (`<Enter>`, `<C-c>`). Subject to approval gates if configured.
- `read_output({session_id, since_seq?, max_bytes?})` → paginated, bounded.
- `tail_output({session_id})` → streaming; server-cancellable.
- `set_note({session_id, text})` — agent's intent narration (shown in UI).
- `set_status({session_id, status})` — agent reports `working` / `waiting` / `done` / `error`. **This is what powers reliable "needs-response" detection** — heuristics are the fallback for agents that don't integrate.
- `wait_for_idle({session_id, idle_ms, timeout_ms})` — replaces polling for "command finished."
- `interrupt({session_id})` — SIGINT.

**gRPC server (remote agents, optional).**
For AI agents on a *different machine* (sandbox VM, cloud worker) to drive Triage over the network. Same logical surface as MCP, exposed via `tonic` over TCP + mTLS. Only built when a concrete remote-agent need lands — the WebSocket API already covers human remote access.

### 6. Inferred Session Context

Self-reported context (agent declaring "I'm in repo X on branch Y") is unreliable — agents forget, lie, or run subcommands elsewhere. Triage derives context from PTY ground truth:

- **Session identity cwd:** track the shell or long-lived root process cwd as the durable session context. Foreground child cwd is useful context, but it should not permanently reclassify the session every time `vim`, `fzf`, `git`, or a build tool becomes foreground.
- **Foreground cwd:** poll `/proc/<pid>/cwd` (Linux) / `proc_pidinfo` (macOS) on the foreground process and expose it as a secondary signal with a confidence level.
- **Repo + branch:** walk up from the selected cwd looking for `.git`; read `HEAD` for the branch. Cache per-cwd with short TTL.
- **Worktree:** prefer structured git discovery (`git rev-parse --show-toplevel` when available, direct `.git` parsing as fallback) to differentiate worktrees of the same repo. Show worktree name (not just repo) in the sidebar — the user's pain is specifically about losing track across worktrees.
- **Touched repositories:** union of all distinct repo roots observed across the session's lifetime.
- **Foreground command:** parse foreground process name + argv to surface "what's running right now" independent of agent self-report.

The agent's `set_note` text remains useful as intent narration ("bisecting the test failure"). It just doesn't get to declare what's actually happening — Triage observes that.

### 7. Search, Logs, Overview Cards

- **Per-session logs** at `~/.local/state/triage/sessions/<id>.log`. Rotation: 100MB per session, last 7 days.
- **Search:** modal hotkey shells out to `rg` over the log directory. MVP, fast, zero new deps.
- **Tantivy is deferred** and re-scoped to indexing *semantic events* (commits, file edits, errors, test runs) extracted from streams — a separate feature, not v2 of raw-text search.
- **Overview grid** (`Ctrl+E`): card per session — title, repo+worktree+branch, status pill, AI note, runtime, last 3 lines. **No downsampled thumbnails** — they're illegible. The status card is the right primitive.

### 8. Approval Gates & Human-in-the-Loop *(optional / later phase)*

For users running unsupervised agents on potentially dangerous commands. Keystrokes pass through a configured matcher (regex over the command being submitted); matches pause the session and surface an approval modal in whatever client has focus — `Cmd+K`-style in TUI, native-feeling sheet in web/mobile. Global pause-all hotkey.

Was front-and-center in earlier drafts; with the navigation/remote story now the headline, this moves to its own optional phase. Ship when users ask.

### 9. Configuration & Theming

TOML at `~/.config/triage/config.toml`:

```toml
[general]
default_shell = "/bin/zsh"

[ui]
theme = "catppuccin-mocha"
sidebar_width_percent = 22
group_by = "worktree"   # "repo" | "worktree" | "flat"

[attention]
idle_threshold_ms = 1500
notify_on_awaiting = true
notify_sound = true

[agents]
# Bundled pattern packs auto-detect known agent CLIs.
known = ["claude", "aider", "codex", "cline", "continue"]

[agents.custom_pack]
process_names = ["my-agent"]
prompt_patterns = ['\? for shortcuts', '\[y/n\]']

[remote]
# WebSocket server for human clients (web/mobile).
bind = "127.0.0.1:7777"
require_pairing = true
tls_cert = "~/.config/triage/certs/server.crt"
tls_key  = "~/.config/triage/certs/server.key"

[mcp]
# stdio is implicit when Triage is spawned by an agent. TCP is opt-in.
tcp_bind = "127.0.0.1:7778"

[grpc]
# Disabled by default. Only for remote AI agents.
enabled = false
# bind = "0.0.0.0:50051"

[approval]
# Optional. Empty = off.
patterns = []

[keybindings]
overview           = "ctrl+e"
search             = "ctrl+f"
next_attention     = "g w"
cycle_agents       = "g a"
cycle_current_repo = "g r"
pause_all          = "ctrl+shift+p"
```

---

## 🛠 Implementation Roadmap

Daemon-first. Local navigation first. Remote access once the local product is worth using from anywhere.

> **Status reconciled with the codebase on 2026-06-11.** Checkboxes below reflect what is actually implemented in `crates/` and `flutter/triage_client/`, not the original aspirational plan. Items that are functionally complete but differ from the original spec (e.g. device-code/PIN pairing instead of bearer auth) are checked with an inline note. Partial items stay unchecked with a note on what remains.

### Phase 0: Tooling & Architecture
- [x] Cargo workspace under `crates/`: `triage-core` (session trait + shared types), `triaged` (state owner), `triage` (Ratatui local client), `triage-transport-ws` (WebSocket transport adapter, server-side), `triage-mcp` (MCP server). Flutter app at `flutter/triage_client/` (outside the Cargo workspace, scaffolded in Phase 4).
- [x] `tracing` to `~/.local/state/triage/triaged.log`.
- [x] TOML config parser.
- [x] CI: fmt, clippy, check, and test on Linux; workspace tests on macOS.
- [x] Test harness: golden snapshots for renderers; virtual terminal fixtures for PTY/session logic. **Set this up early** — TUI/PTY code is notoriously hard to test retroactively.

### Phase 1: Terminal Engine Acceptance
- [x] Engine spike (`wezterm-term` vs `alacritty_terminal`) with a written compatibility matrix.
- [x] Verify resize, late attach, reconnect, alt-screen, bracketed paste, mouse reporting, scroll regions, replay, and log tee behavior.
- [x] Decide and document the canonical daemon state model.

### Phase 2: Daemon Session Core — ✅ complete
- [x] PTY spawning via `portable-pty`.
- [x] Session actor owns PTY I/O, canonical VT state, scrollback sequence numbers, resize state, and metadata. (`ActorState` in `crates/triaged/src/session.rs`)
- [x] Per-session log tee. (`OutputState` log file + `ingest()`)
- [x] Define attach modes: observer, interactive controller, and agent controller. (`AttachMode` enum in `crates/triage-core/src/session.rs`)
- [x] Implement input lease/takeover semantics and broadcast lease changes to clients. (`InputLeaseState`; `LeaseChanged` broadcast on attach/acquire)

### Phase 3: Local API + IPC — ✅ complete
- [x] Define the daemon's session API (Rust trait + types) — the source of truth all transports bind to. (`SessionApi` trait in `crates/triage-core/src/session.rs`)
- [x] Local Unix socket adapter exposing the API. (`IpcServer`/`IpcClient` in `crates/triaged/src/ipc.rs`)
- [x] In-process channel for the embedded TUI (zero-IPC path, same trait). (`triage --embedded` constructs `SessionManager` directly; `SessionManager` impls `SessionApi`)
- [x] Multi-client semantics: many attaches per session, all see output, one active input lease per session. (per-session subscriber fan-out + single-holder lease enforcement on `write_input`)

### Phase 4: TUI Client (the local product) — 🚧 partial (core layout + navigation done; attention-routing features pending)
- [x] Sidebar + main view layout (Ratatui). (`draw_sidebar`/`draw_terminal` in `crates/triage/src/main.rs`)
- [x] Mouse handling (tab switching, scrollback, PTY pass-through for `htop`/`vim`/fzf). (`handle_mouse_event`; selection via OSC 52)
- [x] Inferred session context (session cwd, foreground cwd, repo, branch, worktree) via `proc_pidinfo` / `/proc` plus git discovery. (`resolve_session_context`/`git_repository_root`; cwd tracked from OSC 7)
- [ ] Agent tab auto-classification. *(not started — only holder kind Interactive/Agent is displayed)*
- [ ] Needs-response detection (manual mark + heuristics first, MCP-reported status once MCP lands, pattern packs for Claude Code, Aider, Codex, Cline, Continue). *(not started)*
- [ ] Attention-routing hotkeys (`g w`, `g a`, `g r`, attention history). *(not started — only basic nav hotkeys exist)*
- [ ] Notification surface (OS notifications, badges, sounds). *(not started)*
- [ ] Overview grid (`Ctrl+E`). *(not started)*
- [ ] Search modal (`Ctrl+F`) over per-session logs via `rg`. *(not started)*

### Phase 5: MCP Server (local AI agents) — 🚧 partial (read-only tools over stdio; input/lease + TCP pending)
- [x] MCP server crate against the spec (stdio transport first). (`run_stdio` in `crates/triage-mcp/src/main.rs`)
- [x] Tool surface from §5, bound to the same session API. *(read-only so far: `list_sessions`, `snapshot_session`, `styled_rows`)*
- [ ] Agent input is subject to the same lease model as human clients. *(no write/input tools exposed yet, so lease enforcement on the MCP path is unexercised)*
- [ ] Optional TCP transport behind config flag. *(stdio only)*
- [x] Worked example: Claude Code config snippet registering Triage. (`crates/triage-mcp/README.md` — `claude mcp add triage -- triage-mcp`, plus a Claude Desktop `mcpServers` block)

### Phase 6: Remote Web Client + Auth

Remote access starts with a browser/web client before native mobile. That validates the daemon transport, auth, attach/reconnect, and terminal rendering path with less distribution overhead.

Two spikes gated the rest of Phase 6 — both effectively proven by the shipping web client:

- [x] **Spike A: xterm.js-in-Flutter-Web bridge.** `TerminalPane` embeds xterm.js via `HtmlElementView` + `dart:js_interop`, ingests raw PTY bytes from the WebSocket, and forwards keyboard + mouse input back. (`lib/widgets/terminal_pane_web.dart`, `web/xterm.js`; Playwright coverage in `test_web/`)
- [x] **Spike B: browser reconnect/late attach.** Reconnect with exponential backoff + deferred history replay at the fitted grid size. (`_scheduleReconnect` / `applyHistory` in `lib/main.dart`; daemon replay buffer + `snapshot_session`)

Once spikes pass:
- [x] WebSocket server on the daemon. (`crates/triaged/src/ws.rs`, multiplexed with HTTP) — **auth via device-code + PIN pairing issuing per-device tokens, not bearer; TLS not yet implemented** (assumes Tailscale / loopback for now).
- [x] Pairing flow: `triage pair` surfaces a pairing URL; the daemon's web pairing page approves a device code + PIN and issues a device token. (`pairing_url_for_bind` in `crates/triage/src/main.rs`; `pairing_page_response` in `crates/triaged/src/http.rs`; `pair()` in `crates/triaged/src/session.rs`) — **delivers a URL, not a scannable QR code yet.**
- [x] Define the Flutter `TerminalPane` widget API — shared interface for byte attach/detach, write, status, lifecycle. **Platform-branched** at focus handling, selection / copy, theming surface, accessibility tree, layout hit-testing via conditional imports. (`terminal_pane.dart` → `terminal_pane_web.dart` / `terminal_pane_stub.dart`)
- [x] Flutter web app scaffold: sidebar + session navigation. (`SessionRail` in `lib/main.dart`) — **repo/worktree grouping and attention-prioritization UX not yet implemented.**
- [ ] Tailscale setup doc. *(not written)*

### Phase 7: Native Mobile + Notifications — 🚧 partial (Android UX shipped; iOS validation + push pending)

The native rendering path (`terminal_pane_stub.dart` over `xterm.dart`) is what desktop *and* mobile builds run. The Android client is in daily use; what remains is iOS validation and **push-notification infrastructure, of which none exists**.

- [ ] **Spike: xterm.dart scroll-region validation.** Run vim, tmux, htop, lazygit, less inside xterm.dart on iOS and Android. Confirm whether Issue #222 affects our use. If yes, budget for in-house patch or fork. *(exercised on Android via the shipping client; no iOS on-device validation, and no deliberate pass over the scroll-region app matrix)*
- [x] **Mobile touch UX.** On-screen modifier-key bar (Esc/Ctrl/Tab/arrows/Shift+Tab), soft-keyboard handling (verified on-device), touch scroll + long-press selection, and a full-screen session rail with drag-to-reorder. (`Platform.isIOS`/`isAndroid` branches in `lib/main.dart` + `lib/widgets/`)
- [x] **Multi-daemon switching.** The client remembers labeled daemons and switches between them, keeping a per-daemon pairing token and rail order. (`lib/services/server_store.dart`, `ServerManagerDialog` in `lib/main.dart`)
- [ ] Web build: PWA manifest, service worker, Web Push via FCM (Android only). *(PWA manifest + a stale-service-worker cleanup script exist; no Web Push / FCM)*
- [ ] iOS native build: APNs integration. *(stock Flutter `AppDelegate`; no APNs, no notification plugin in `pubspec.yaml`)*
- [ ] Android native build: FCM integration. *(stock Flutter `MainActivity`; no FCM)*
- [x] Optional Flutter Desktop build (macOS first; Linux / Windows after). *(macOS/Linux/Windows runner folders present; builds from the shared codebase using the native `xterm.dart` pane — actively developed on macOS)*
- [ ] Behavioral compatibility test suite — same byte stream → equivalent rendered grid in both engines for SGR, cursor positioning, scroll regions, mouse events, alt-screen, bracketed paste. *(single-engine acceptance tests exist; no cross-engine xterm.js-vs-xterm.dart parity suite)*

### Phase 8: Persistence — 🚧 partial (save/restore + replay done; shell recreation + log rotation pending)
- [x] Session metadata serialized on daemon exit (title, cwd, env, notes, classification, last known repo/worktree). (`persist_manifest` → `sessions.json`; `HandoverState` in `crates/triaged/src/handover.rs`)
- [x] Rehydrate UI state on daemon start: restore metadata and replay last N lines to UI buffer. (`restore_sessions` + `EVENT_REPLAY_BUFFER`; client-side `applyHistory`)
- [ ] Optional shell recreation for sessions that were plain shells. Do not promise resurrection of arbitrary programs, editors, or agent processes. *(not started)*
- [ ] Log rotation enforcement. *(no rotation/size-cap policy)*

### Phase 9 (optional, prioritize on demand)
- [ ] Approval gates + cross-client approval modals.
- [ ] gRPC server (`tonic` + mTLS) for remote AI agents.
- [ ] Tantivy-based event index (commits, errors, file edits).

---

## 🤖 Instructions for the Implementing Agent

1. **Daemon owns state.** TUI, web, MCP, gRPC are all clients. Do not put session state in the TUI process.
2. **One API, many transports.** Define the daemon's session interface once; bind it to in-process channel, Unix socket, WebSocket, MCP, and gRPC as separate thin adapters. Resist transport-specific business logic.
3. **Async hygiene.** PTY reads, log writes, and every transport handler live on Tokio. UI threads never block on I/O.
4. **One writer per session.** Multiple clients can observe a session, but input goes through the session lease model. Lease changes are visible events.
5. **Inferred over declared.** Repo, branch, worktree, and foreground command come from the OS. Track confidence and distinguish durable session context from transient foreground command context. `set_note` is intent narration only.
6. **Match auth to the transport boundary.** Remote network transports require auth and encryption. In-process, owner-only Unix sockets, and stdio inherit local trust unless a TCP or cross-user mode is enabled.
7. **macOS first; Linux parity.** Native `portable-pty` allocation. Confirm mouse capture works in iTerm2, Terminal.app, Ghostty. Mirror on Linux before either is considered done.
8. **Flutter shell, per-target terminal engine.** The Flutter app shell is shared across web / iOS / Android / desktop. Terminal rendering is platform-specific: xterm.js via JS interop on Web, xterm.dart on native. Wrap both behind a common `TerminalPane` widget for the shared operations (snapshot load, byte attach/detach, write, resize, status, lifecycle), and accept that focus handling, selection / copy, theming, accessibility tree, and layout hit-testing branch on platform. Make the branches explicit and documented rather than scattered. **Prove the xterm.js-in-Flutter-Web bridge first**. **Validate xterm.dart against scroll-region apps before native mobile work**.
9. **Test the impossible-to-test parts early.** Golden snapshots for Ratatui renders; virtual terminal tests for PTY logic. Retrofitting tests onto a TUI is misery.
10. **Don't replace Ratatui with Flutter Desktop.** Both are first-class local clients. Ratatui TUI serves terminal-mode users; Flutter Desktop serves users who prefer a graphical app. Maintain both behind the same daemon API.
