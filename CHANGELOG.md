# Changelog

All notable changes to Triage are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.3.0] - 2026-08-20

### Added

- **Tool-Call Approval Judge & Agent Lifecycle Hooks** (`triaged`, `triage-hook`, `triage-core`, `triage`, `triage_client`):
  - Integrated 3-tier local security judge for autonomous agent CLIs running in Triage sessions (Antigravity, Claude Code, Cline, etc.):
    - **Layer 1 (Deterministic Deny)**: Instantly rejects destructive commands, credential access, and outward-facing exfiltration.
    - **Layer 2 (Deterministic Allow)**: Auto-approves routine read-only inspections, builds, tests, and lints without invoking the model.
    - **Layer 3 (Resident Model)**: Grammar-constrained local model (`cera` / `LFM2-2.6B-GGUF`) evaluating ambiguous commands strictly to `allow` or `ask`.
  - Added new `triage-hook` crate: lightweight, decoupled PreToolUse lifecycle hook shim with multi-format auto-detection for Antigravity (`~/.gemini/config/hooks.json`) and Claude Code (`~/.agents/hooks.json`), offline fallback to deterministic rules, and bounded 10s execution timeout.
  - Added TUI controls: **`a`** key to toggle per-session auto-approval, **`F5`** / **`S`** for the full-screen Approval Judge settings overlay, and status line policy badges.
  - Added Flutter client features: tabbed Settings Dialog (General, Approval Judge, Diagnostics, About), real-time tool-call decision audit stream, interactive custom allow/deny rule manager, and rail auto-approval toggle switch.
  - Added `triaged reload` CLI command for direct, clean descriptor handover across upgrades.
  - Automated agent hook provisioning on service install and daemon startup.
- **Terminal Emulation & Rendering Enhancements**:
  - Added support for **Synchronized Output Mode 2026** (DEC private mode 2026 / BSU & ESU) to eliminate cursor jumping and flickering during rapid batch terminal updates.
  - Activated `xterm-addon-unicode11` with `allowProposedApi: true` in web terminal for proper emoji, wide glyph, and CLI progress spinner rendering.
  - Filtered synthetic terminal query auto-responses (CPR, DA1-3, DSR, Kitty keyboard flags, DECRPM, OSC color reports, window size queries) to prevent phantom keystrokes and input lockups.
  - Preserved raw newlines across the VT pipeline to prevent layout distortion on prompt redraws.
  - Unified web keyboard handling under `xterm.js` `onData` for native IME and shortcut support.
- **Zero-Downtime Handover & SIGTERM Rescue** (`triaged`):
  - Self-pipe signal handling initiating a background successor rescue (`triaged --handover`) on `SIGTERM` (`launchctl stop`, `systemctl --user stop`, user logout, or standard `kill`), preserving live PTY handles across service restarts.
  - Fine-grained mutex locking preventing blocked PTY actor round-trips from stalling the global session manager.
  - Resolved descriptor leaks with `FD_CLOEXEC` on PTY master dups and TCP listener sockets.
- **Multi-Client Sizing & Clipboard Improvements**:
  - Restrict PTY size arbitration to the currently focused client so background or mobile clients cannot distort the terminal viewport.
  - Touch selection on mobile web and Flutter client properly copies to clipboard with non-detaching scrollback clear safeguards.
- **CI / Publishing**:
  - Made crate publishing re-runnable and resilient against crates.io sparse index.

---

## [0.2.1] - 2026-08-07

### Added

- Multi-device pairing challenge support with allowlisted Tailscale identity approval (`pair_approval_tailnet_users`).
- Session rail grouping by repository and ordering by activity.
- Visual drag feedback when rearranging session rail rows.

### Fixed

- Fixed web terminal clipboard paste handling.
- Bumped `cera` inference dependency to 0.4.0.

---

## [0.2.0] - 2026-07-28

### Added

- FlatBuffers binary wire protocol for session snapshots, input streaming, and event fanout.
- Native Flutter desktop clients (macOS, Windows, Linux) and Android support.
- Zero-downtime Unix process handover (`triaged --handover`) with descriptor passing (`SCM_RIGHTS`).
- Model Context Protocol (MCP) server `triage-mcp` for read-only agent inspection.
- Signed release archives with minisign and sha256 checksums.

---

## [0.1.6] - 2026-07-15

### Added

- Initial release of `triaged` daemon, `triage` Ratatui TUI, and embedded web client.
- PTY multiplexing on macOS, Linux, and Windows (ConPTY).
- Background service management (`triaged service install/status/stop/start/uninstall`).
