# 000102-01 — Fix daemon crash causes and bound session output logs

## Thinking

Investigation started from two reported symptoms: `triaged` killing sessions, and
the machine's UI stalling. Three independent causes turned up, only the third of
which is a code defect in this repo.

### 1. The SIGKILLs — macOS codesigning

Both crash reports on this machine
(`triaged-2026-07-21-231543.ips`, `triaged-2026-07-22-072744.ips`) are:

```
exception:   EXC_CRASH, signal "SIGKILL (Code Signature Invalid)"
termination: namespace CODESIGNING, code 4, "Launch Constraint Violation"
```

The shipped binary is adhoc / linker-signed (`codesign -dv` reports
`Signature=adhoc`, `flags=0x20002(adhoc,linker-signed)`). macOS caches the code
directory hash against the **inode**. Replacing the binary *in place* — writing
new bytes into the existing inode, as `cp` over a destination does — leaves the
cached CDHash pointing at content that no longer matches, so the kernel SIGKILLs
both the running daemon and every subsequent launch from that path until the
cache is invalidated.

Evidence lines up exactly: installed binary mtime `07:27:01`, crash at
`07:27:44`. Session logs `session-73.log` / `session-80.log` have mtimes frozen
at `Jul 21 23:15`, the minute of the other crash.

This is a *packaging* bug, not a runtime one — the fix is to never write over a
live inode. An atomic `rename(2)` into place allocates a fresh inode and the
signature is evaluated correctly.

### 2. launchd turns one bad launch into a storm

`launchctl print` reported `runs = 22`. `plist_contents` (service.rs) emits a
bare unconditional `KeepAlive`:

```xml
<key>KeepAlive</key>
<true/>
```

with no `ThrottleInterval`, so launchd re-spawns a binary that cannot launch
forever at the 10s default. The `Address already in use (os error 48)` lines in
`triaged.err.log` are respawns racing the listener socket.

Unconditional `KeepAlive` is also why a manual `triaged --handover` always runs
twice: launchd immediately respawns the job the handover just tore down.
`KeepAlive: {SuccessfulExit: false}` restarts on a crash but not after the clean
exit that ends a handover, which fixes both problems with one change.

### 3. Unbounded session logs, read whole into memory

This is the real defect and the cause of the resource blowup.

- `OutputState::ingest` (session.rs) writes **every** PTY byte to the session
  log. No cap, no rotation, no retention — the only `remove_file` calls in the
  daemon are for sockets, plists and pairing codes.
- Both replay paths read the **entire** file into a `Vec`:
  - `session.rs` adopt path — `fs::read(&h_sess.log_path)`
  - `HistoricalSession::restore` — `fs::read(&persisted.log_path)`
  and then push every byte through the wezterm emulator.
- Yet `RAW_OUTPUT_TAIL_CAP` is **1 MiB** — only the last 1 MiB is ever served to
  a client, and the module doc already records that a 64 KiB tail reproduced the
  screen exactly in the Phase 0 spike.

On this machine that is 1.5 GB across 126 logs dating back to May 31, with the
two largest at ~100 MB. The 14:27 handover adopted 13 sessions by this path,
which is why the daemon burned 9m54s of CPU in 9m22s of wall time, sits at ~2 GB
RSS, and logged `gap_ms: 25747` — a 25.7-second Phase-2 handover gap.

Gigabytes are written and fully re-read in order to serve at most 1 MiB.

### Offset semantics — why rotation is safe

Rotation rewrites the front of the log, which shifts byte offsets. That is only
safe if nothing depends on those offsets being stable across time.

`bytes_logged` is **not** persisted: `PersistedSession` has no such field, and
restore re-derives it by replaying the file, so it is always just "current length
of the log file". Absolute offsets therefore already rebase on every daemon
restart, and the system tolerates it.

`raw_output_start` is handed to clients only as part of a snapshot, always paired
with the `raw_output` it describes. The Dart client passes it straight through
(`triage_websocket_client.dart`) with no cross-snapshot arithmetic, and live
output de-duplicates by `output_seq`, which rotation does not touch.

So the invariant to preserve is simply **`bytes_logged == current file length`**.
Rotation reduces both together and every consumer stays consistent.

## Plan

1. **service.rs — bound launchd restarts.**
   - `KeepAlive` becomes `<dict><key>SuccessfulExit</key><false/></dict>` so a
     clean exit (handover) is not respawned, while a crash still is.
   - Add `<key>ThrottleInterval</key><integer>30</integer>` so a launch-failing
     binary backs off instead of storming.
   - Update the plist unit test to assert both.

2. **`scripts/install.sh` — never overwrite a live inode.**
   - `cargo build --release`, then install via a temp file in the destination
     directory followed by `mv` (atomic rename → fresh inode).
   - Document why in the script header and in `README`/`AGENTS` as appropriate.

3. **session.rs — bound replay on adopt and restore.**
   - Add `REPLAY_TAIL_CAP`.
   - Add a helper that returns `(file_len, tail_bytes)` reusing the existing
     bounded `read_raw_output_tail` seek+read.
   - Adopt and `HistoricalSession::restore` replay only the tail, but set
     `bytes_logged` to the true file length so offsets stay correct.

4. **session.rs — cap the log on write.**
   - `MAX_SESSION_LOG_BYTES` / `SESSION_LOG_RETAIN_BYTES`.
   - In `ingest`, once the file exceeds the max, rewrite it down to the retain
     size and reduce `bytes_logged` to match, preserving the invariant above.

5. **session.rs — age-based purge of historical logs at startup.**
   - Delete session logs for non-live sessions older than a retention window.

6. **One-off cleanup** of the existing 1.5 GB backlog on this machine, keeping
   the currently-live sessions.

7. **Validate**: `cargo fmt --all --check`, `cargo clippy --workspace
   --all-targets --all-features -- -D warnings`, `RUSTDOCFLAGS="-D warnings"
   cargo doc --workspace --all-features --no-deps --locked`, `cargo test
   --workspace`. Then `/review-fix-loop max`.
