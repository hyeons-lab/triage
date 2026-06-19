# Plan 000078-01 — triaged service polish

## Thinking

Three deferred #88 items. Two are code, one is validation.

**Stop granularity.** `service stop` on Windows does `taskkill /IM triaged.exe
/F`, which ends every triaged.exe the user owns — including one launched by hand.
The logon task launches the daemon detached (`cmd /c start "" /b`), so the task
doesn't track the daemon PID and `schtasks /End` can't reach it. The clean fix is
a PID file: the daemon writes its PID on startup, `stop` reads it and targets
that PID. Handover is Unix-only, so Windows has exactly one daemon process — no
PID churn to worry about.

**Bounded-connect test.** The 5s timeout's busy-pipe path is hard to force
deterministically (need to saturate the single instance and prevent re-arm). The
testable, valuable invariant is the *missing-daemon* path: connecting to a pipe
with no server must fail fast (ERROR_FILE_NOT_FOUND), not wait the full timeout.

**macOS smoke test.** A production daemon holds `:7777`, so a live install would
crash-loop. Run the exact `launchctl` verbs against a dummy `sleep` agent under a
`…smoketest` label instead — validates the integration without disruption.

## Plan

1. `service.rs`: add `pid_file_path()` + `record_running_pid()` (Windows);
   rewrite Windows `stop` to taskkill the recorded PID (fallback `/IM`);
   `uninstall` removes the PID file.
2. `main.rs`: call `service::record_running_pid()` in the Windows serve block.
3. `ipc.rs` tests: `#[cfg(windows)]` test that `transport::connect` to a missing
   pipe errors in well under the timeout.
4. Run the macOS launchctl smoke test; record the transcript in the devlog.
5. Validate: host + Windows-target clippy/fmt; host triaged tests.
