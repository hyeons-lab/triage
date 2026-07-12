# 000087 — Reconcile design-doc roadmap with the codebase

**Agent:** Claude (claude-opus-4-8) @ triage branch docs/design-doc-status-reconcile

## Intent

The roadmap checkboxes in `devlog/triage-design-doc.md` had drifted from what is
actually implemented in `crates/` and `flutter/triage_client/`. Reconcile the
Phase 2–8 status so the doc reflects reality (source of truth for "what's next"),
rather than the original aspirational plan.

## What Changed

- 2026-07-11T22:25-0700 `devlog/triage-design-doc.md` — added a "Status
  reconciled with the codebase" banner and updated Phase 2–8 checkboxes against
  the shipping code:
  - **Phase 2 (Daemon Session Core) → complete:** session actor, log tee, attach
    modes (`AttachMode`), input lease/takeover all implemented.
  - **Phase 3 (Local API + IPC) → complete:** `SessionApi` trait, Unix socket
    adapter, in-process embedded-TUI path, multi-client fan-out + single-holder
    lease.
  - **Phase 4 (TUI Client) → partial:** layout, mouse, inferred session context
    done; agent classification, needs-response detection, attention-routing
    hotkeys, notifications, overview grid, and search modal not started.
  - **Phase 5 (MCP Server) → partial:** read-only stdio tools shipped; write/input
    (lease-gated) tools, TCP transport, and the Claude config example pending.
  - **Phase 6 (Remote Web Client + Auth) → mostly done, spec-divergent:** both
    xterm.js spikes proven by the shipping web client; WebSocket server + pairing
    ship as device-code/PIN issuing per-device tokens (not bearer), URL not QR,
    TLS not yet; Tailscale doc unwritten.
  - **Phase 7 (Native Mobile + Notifications) → mostly not started:** native
    `xterm.dart` pane exists and drives desktop, but no mobile touch UX and no
    push (APNs/FCM) infrastructure.
  - **Phase 8 (Persistence) → partial:** metadata serialize/restore + replay done;
    shell recreation and log rotation pending.

## Decisions

- 2026-07-11T22:25-0700 Items functionally complete but divergent from the
  original spec (e.g. device-code/PIN pairing instead of bearer auth) are checked
  with an inline note, rather than left unchecked — the doc tracks capability, and
  the note preserves the spec delta.

## Commits

- HEAD — docs(design): reconcile roadmap checkboxes with the codebase
