# 000078 — fix/triaged-service-polish

**Agent:** Claude (claude-opus-4-8) @ triage branch fix/triaged-service-polish

## Intent

Knock out the deferred polish from #88 (the per-user service + Windows daemon
follow-ups):

1. **macOS service smoke test** — validate the `launchctl` integration on real
   macOS end-to-end (load → start → list → stop → unload), since only the plist
   *content* was unit-tested.
2. **Windows `service stop` granularity** — replace the blanket
   `taskkill /IM triaged.exe /F` with a PID-targeted kill: the daemon records its
   PID on startup and `stop` ends exactly that process, falling back to `/IM`.
3. **Windows bounded-connect lifecycle test** — assert the missing-daemon connect
   fails fast (well within the 5s `ConnectWaitMode::Timeout`) rather than hanging.

## Decisions

- 2026-06-18T23:35-0700 macOS smoke test runs against a throwaway dummy
  LaunchAgent (a `sleep`-based program under a `…smoketest` label), NOT a live
  `triaged service install`: a production `triaged` is already bound to
  `:7777`, so installing the real agent would spawn a second daemon that
  crash-loops under `KeepAlive` fighting for the port. The dummy exercises the
  exact `launchctl` verb sequence `service.rs` uses, non-disruptively.
- 2026-06-18T23:35-0700 Windows PID file at `%LOCALAPPDATA%\triage\triaged.pid`
  (handover is Unix-only, so on Windows there's exactly one daemon process to
  track). Best-effort write at startup; `stop` reads it, `uninstall` removes it.

## What Changed

- 2026-06-18T23:40-0700 `crates/triaged/src/service.rs` — Windows `stop` now
  prefers a PID-targeted `taskkill /PID <pid> /F` (reading the PID the daemon
  recorded at startup) over the blanket `/IM triaged.exe`, so stopping the
  service no longer also kills a `triaged` the user launched by hand. Added
  `pid_file_path()` (`%LOCALAPPDATA%\triage\triaged.pid`, USERPROFILE fallback),
  `record_running_pid()` (pub, best-effort startup write), and `recorded_pid()`
  (parse helper in the Windows platform mod). `uninstall` removes the PID file.
- 2026-06-18T23:40-0700 `crates/triaged/src/main.rs` — call
  `triaged::service::record_running_pid()` in the Windows serve block before
  `serve()`.
- 2026-06-18T23:40-0700 `crates/triaged/src/ipc.rs` — added Windows test
  `windows_connect_to_missing_daemon_fails_fast`: a bounded connect to a
  nonexistent pipe must error in < 2s (proving the missing-daemon path fast-fails
  rather than waiting out the 5s busy-pipe timeout).

## Issues

- 2026-06-18T23:36-0700 macOS `launchctl` smoke test (dummy `sleep` agent under
  `com.hyeons-lab.triaged.smoketest`, since a production daemon holds `:7777`).
  The exact verb sequence `service.rs` uses passed end-to-end:
  `load -w` → started the program; `start` → re-triggered; `list` → showed Label
  + PID 79381 (real process confirmed via `pgrep`); `stop` → killed it;
  `unload -w` → removed it (`list` then returned "Could not find"); no residual
  processes. Confirms the launchctl integration on real macOS; the plist body
  itself is covered by the `plist_contents` unit tests.

### PR review comments (Copilot, #89)

- 2026-06-19T08:30-0700 `crates/triaged/src/service.rs` — Copilot: Windows `stop`
  ignored `taskkill`'s exit status, so a stale PID file (daemon crashed, or a
  failed restart overwrote it) would make `/PID` fail yet still print "Stopped
  triaged." with the daemon still running. Fixed: the PID kill now uses a
  filtered `taskkill /FI "PID eq <pid>" /FI "IMAGENAME eq triaged.exe" /F` (so a
  reused PID can't kill an unrelated process), and only its *success* skips the
  `/IM` fallback — a stale/missing PID falls through to image-name kill. `stop`
  now also removes the PID file unconditionally so a stale PID is never re-read.
- 2026-06-19T08:30-0700 devlog — switched timestamp UTC offsets to the AGENTS.md
  `±HHMM` (no-colon) convention.
- 2026-06-19T06:31-0700 `crates/triaged/src/service.rs` — Copilot (round 2): the
  `/IM triaged.exe` fallback would also kill the running `triaged service stop` /
  `uninstall` CLI (itself a triaged.exe), so `uninstall` could self-terminate
  before reaching `schtasks /Delete`. Fixed: the fallback now excludes our own
  PID — `taskkill /FI "IMAGENAME eq triaged.exe" /FI "PID ne <self>" /F`.

## Next Steps

- Self-update epic Phase 0 (prebuilt release binaries) tracked separately.

## Commits

- 59e9039 — fix(triaged): target the recorded PID on Windows service stop; add tests
- b2ff70c — fix(triaged): verify taskkill success and clear the PID file on stop
- HEAD — fix(triaged): exclude the CLI's own PID from the taskkill fallback
