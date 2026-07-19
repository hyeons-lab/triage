# 000092 — fix/cli-args-and-web-origin

## Intent

Two robustness fixes surfaced while writing the remote-access setup guide:

1. `triaged` had no argument parsing, so *any* invocation — including
   `triaged --help` — started a daemon. Because a starting daemon hands over
   from a running one, asking for help silently shut down the live daemon.
2. The web client discarded the page origin whenever it was not served on port
   7777, falling back to a hardcoded `ws://127.0.0.1:7777/ws`. That breaks any
   deployment behind a reverse proxy.

## What Changed

### `triaged` argument parsing

`crates/triaged/src/main.rs` now parses arguments into an `Invocation` enum
(`Help`, `Version`, `Service`, `Daemon`) before any daemon logic runs.
`--help`/`-h`/`help` and `--version`/`-V` print and exit. Unrecognized
arguments are rejected with a non-zero exit instead of falling through to a
daemon start.

Mirrors the existing house pattern (`StartupMode::from_args` in `triage`,
`ServerConfig::from_args` in `triage-mcp`), including a `HELP` constant.

### Web client origin fallback

`defaultWebSocketUriForBase` in `flutter/triage_client/lib/main.dart`
previously required `base.port == _defaultDaemonPort` before trusting the page
origin. The origin is now used whenever the host is not loopback, regardless of
port.

## Decisions

- **The loopback carve-out is deliberate, not an oversight.** The existing test
  `uses daemon websocket target for Flutter dev server base URL` encodes a real
  workflow: `flutter run -d chrome` serves from loopback on its own port while
  the daemon listens separately on 7777. Dropping the port check outright would
  have broken it. The rule is now "a loopback origin on a non-daemon port means
  dev server; any non-loopback origin is the daemon."
  - Known trade-off: running the Flutter dev server bound to a *non-loopback*
    address (`--web-hostname 192.168.1.5`) now resolves to the dev server's own
    port rather than the daemon. Judged rarer than the reverse-proxy case, which
    was completely broken.
- **Unknown arguments are rejected rather than ignored.** Ignoring them is what
  turned a typo into an outage. Accepted args are exactly `service`,
  `--handover`/`-U`, and the new help/version flags.
- **Help wins over launch flags.** `triaged --handover --help` prints usage
  rather than performing a handover.
- `Restart=on-failure` in the systemd unit was left alone. The handover exit is
  a clean `exit 0`, so the unit correctly declined to restart — the bug was the
  unintended handover, not the restart policy. `Restart=always` would race with
  legitimate handovers.

## Issues

The daemon-shutdown bug was found by triggering it: running `triaged --help`
to inspect its flags handed over from and shut down the running systemd
service. `Adopting 0 inherited live sessions` — no live PTYs were lost. The
service was restored with `systemctl --user start triaged.service`.

## Research & Discoveries

- Separately diagnosed a connectivity report on WSL2 (`networkingMode=mirrored`):
  Windows resolves `localhost` to `::1` first, but `remote.bind` defaults to
  `0.0.0.0:7777` — IPv4 only — so nothing answers on `::1`. `http://127.0.0.1:7777`
  works. A dual-stack `bind = "[::]:7777"` would make `localhost` work; not
  changed here as it is a config-level decision.
- The Hyper-V firewall for the WSL VM has `DefaultInboundAction = Block`, which
  drops inbound connections from other hosts. Relevant to any remote-access
  setup: tailnet traffic to the daemon needs that opened.

## Progress

- Rust: 262 workspace tests pass (7 new arg-parser tests).
- Dart: 52 widget tests pass (3 new origin tests; the dev-server test is
  unchanged and still passing).
- Verified end-to-end against the live daemon: `triaged --help` prints usage
  and exits 0 with the running service untouched (same PID, still serving 200);
  `triaged --handver` exits 1 with a usage error.

## Commits

- HEAD — fix(triaged): parse CLI arguments so --help cannot displace a running daemon

## Next Steps

- Consider whether `remote.bind` should default to dual-stack `[::]:7777` so
  `localhost` resolves correctly on Windows/WSL clients.
- The remote-access setup guide (Tailscale) is still unlanded; it fills the
  Phase 6 gap in `devlog/triage-design-doc.md` ("Tailscale setup doc — not
  written").
