# 000077 — feat/triaged-service

**Agent:** Claude (claude-opus-4-8) @ triage branch feat/triaged-service

## Intent

Make `triaged` runnable as a managed, per-user background service on all
supported platforms, so users no longer launch it by hand in a terminal. The
Windows daemon support (PR #87) made the daemon *run* on Windows; this branch
makes it *run as a login service* on macOS (LaunchAgent), Linux (systemd
`--user`), and Windows (Scheduled Task at logon).

Also folds in the four deferred Windows daemon follow-ups from #87:
1. Safe cleanups (redundant serve() probe, pipe-name length guard, test race).
2. Bounded named-pipe connect (timeout instead of unbounded wait).
3. `%LOCALAPPDATA%` for upgraded web assets on Windows.
4. Rename `UnixSocket*` → cross-platform `Ipc*`; de-dup per-platform serve.

## Decisions

- 2026-06-18T21:40-07:00 Per-user / login scope (not system/boot) — the daemon
  owns the user's interactive PTYs and a per-user socket/pipe, so it must run in
  the user's session. System services run as SYSTEM/root in session 0 and can't
  own interactive ConPTY or per-user paths.
- 2026-06-18T21:40-07:00 Hand-rolled per-platform registration over the
  `service-manager` crate — that crate's Windows path is `sc.exe` (system
  service, session 0), wrong for an interactive per-user daemon. Hand-rolling
  launchd/systemd/schtasks keeps full control and stays dependency-light.
- 2026-06-18T21:40-07:00 Template builders (plist/unit/schtasks argv) are plain
  cfg-independent functions so they unit-test on all three CI runners; only the
  side-effecting load/enable step is cfg-gated.

## What Changed

- 2026-06-18T21:48-07:00 `crates/triaged/src/service.rs` (new) — `triaged
  service <install|uninstall|start|stop|status>` CLI. `ServiceContext::detect`
  resolves the running binary via `std::env::current_exe()` and embeds it into
  the registration. Per-platform `platform` modules: macOS LaunchAgent via
  `launchctl load -w`, Linux systemd user unit via `systemctl --user enable
  --now`, Windows logon task via `schtasks /Create /SC ONLOGON` (windowless
  through `cmd /c start "" /b`). A `not(any(...))` fallback bails cleanly.
  Template builders (`plist_contents`, `systemd_unit_contents`,
  `schtasks_create_args`) are pure and gated `cfg(any(<platform>, test))` so they
  compile-and-test on every CI runner without dead-code warnings in non-test
  platform builds. 4 unit tests cover all three templates + XML escaping.
- 2026-06-18T21:48-07:00 `crates/triaged/src/main.rs` — dispatch `args[1] ==
  "service"` to `service::run_cli` before the daemon path; `--handover`
  unchanged.
- 2026-06-18T21:48-07:00 `crates/triaged/src/lib.rs` — `pub mod service;`.
- 2026-06-18T21:48-07:00 `crates/triaged/README.md` — "Running as a background
  service" section: command table, per-platform mechanism/location table, and a
  `loginctl enable-linger` note for surviving logout on Linux.

## Issues

- 2026-06-18T21:45-07:00 Dead-code under `-D warnings` differs per target: the
  pure builders are unused in non-test platform builds (e.g. `systemd_unit_*` on
  macOS), `ServiceContext.log_dir` was unused off macOS, and `home_dir` is unused
  on Windows. Resolved by `cfg(any(<platform>, test))` gating the builders +
  consts, dropping `log_dir` from the struct (macOS computes it inline), and
  gating `home_dir`/`default_log_dir` to the platforms that use them. Verified
  clean on host (macOS) and `x86_64-pc-windows-gnu`; Linux deferred to CI (no
  local cross-linker for ring's C deps).

## Next Steps

- Implement `service` subcommand + per-platform registration + tests.
- Fold in the four Windows follow-ups, each as its own commit.

## Commits

- HEAD — feat(triaged): manage triaged as a per-user login service
