# Plan 000077-01 — triaged per-user service

## Thinking

`triaged` is a per-user daemon: it owns the user's PTYs, listens on a per-user
Unix socket / named pipe, and stores web assets under the user's home. So the
service must run **in the user's login session**, not as a system service.

Per-platform login mechanisms:
- macOS: LaunchAgent in `~/Library/LaunchAgents/`, loaded with
  `launchctl bootstrap gui/<uid>` (modern) / `launchctl load -w` (fallback).
- Linux: systemd user unit in `~/.config/systemd/user/`, `systemctl --user
  enable --now`. Note `loginctl enable-linger` if it should survive logout.
- Windows: Scheduled Task at logon via `schtasks`. Run windowless with
  `cmd /c start "" /b "<exe>"` so no console flashes.

The `service-manager` crate only does `sc.exe` system services on Windows, which
run in session 0 as SYSTEM — wrong for an interactive per-user daemon. So we
hand-roll all three. Template generation is pure string-building → unit-testable
on every runner; the load/enable/start calls are the only cfg-gated side effects.

## Plan

1. `crates/triaged/src/service.rs`:
   - `pub fn run_cli(action: &str) -> anyhow::Result<()>` dispatching
     install/uninstall/start/stop/status.
   - `ServiceContext { exe: PathBuf, label, log_dir }` from `current_exe()`.
   - cfg modules: `launchd` (macos), `systemd` (linux), `task` (windows), each
     with `install/uninstall/start/stop/status`.
   - Pure builders: `plist_contents`, `systemd_unit_contents`,
     `schtasks_create_args` — unit-tested unconditionally.
2. `main.rs`: dispatch `args[1] == "service"` → `service::run_cli` before the
   normal daemon path; keep `--handover` handling.
3. README: document `triaged service install` per platform.
4. Windows follow-ups, each its own commit (see devlog Intent 1–4).

## Commit order (value-first)

1. Service feature + tests.
2. Windows safe cleanups.
3. Bounded connect.
4. `%LOCALAPPDATA%` web assets.
5. `UnixSocket*` → `Ipc*` rename + serve/handle_connection de-dup.
