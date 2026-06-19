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

### Windows daemon follow-ups (from #87)

- 2026-06-18T21:55-07:00 `crates/triaged/src/ipc.rs` — **Safe cleanups.**
  Removed the Windows `serve()` self-connect "already in use" preflight;
  `create_sync()` sets `FILE_FLAG_FIRST_PIPE_INSTANCE`, so a second daemon's
  create fails atomically (the probe could itself block and left a phantom
  connection in the accept loop). The create error context now hints "is another
  triaged already running?". Added a 210-char length cap to `windows_pipe_token`:
  an over-long token collapses to a readable prefix + sha256 hash so it stays
  under the 256-char NPFS limit and unique per path. Windows-only test
  `windows_pipe_token_caps_overlong_names` covers it.
- 2026-06-18T22:05-07:00 `crates/triaged/src/ipc.rs` — **Bounded connect.** The
  Windows client now connects via the raw named-pipe stream
  (`DuplexPipeStream::<Bytes>::connect_by_path_with_wait_mode`) with a 5s
  `ConnectWaitMode::Timeout`, instead of the cross-platform `local_socket`
  connect that hardcodes an unbounded wait. A missing daemon still fails fast
  (the pipe doesn't exist); only an all-instances-busy pipe (`ERROR_PIPE_BUSY`)
  consumes the timeout, so a busy pipe can no longer block the client forever.
  Introduced a `transport::ClientStream` alias (Unix `UnixStream`; Windows the
  named-pipe stream) distinct from the server-accepted `LocalStream`; `connect`
  and `finish_write` now take `ClientStream`. This also mitigates the test
  readiness-probe race — a throwaway probe connection that momentarily consumes
  the single pipe instance now bounds the real client's wait at 5s (re-arm is
  microseconds) instead of risking an unbounded block. Confirmed the API against
  interprocess 2.4.2 source; validated only by the `windows-latest` CI runner.
- 2026-06-18T22:12-07:00 `crates/triaged/src/http.rs` — **`%LOCALAPPDATA%` web
  assets.** `default_override_dir` now returns `%LOCALAPPDATA%\triage\web` on
  Windows (falling back to `%USERPROFILE%\AppData\Local`), instead of the
  Unix-style `~/.local/share`. The Unix branch is unchanged byte-for-byte to
  avoid shifting the path for existing installs. Both the daemon (reads) and the
  client upgrade flow (writes) call this one function, so they stay in agreement.

- 2026-06-18T22:20-07:00 `crates/triaged/src/ipc.rs` (+ triage, triage-mcp)
  — **Type rename + dedup.** Renamed the now-cross-platform `UnixSocketConfig` /
  `UnixSocketServer` / `UnixSocketClient` → `IpcConfig` / `IpcServer` /
  `IpcClient` across all five referencing files. De-duplicated the two `serve`
  accept loops via a shared `spawn_client_handler` (the thread-spawn +
  benign-disconnect filter), and the two `handle_connection` bodies via a shared
  `dispatch_request` (subscribe-stream vs one-shot request/response); each
  platform handler keeps only its genuinely-divergent part (Unix stream-clone +
  SCM_RIGHTS handover; Windows single-stream + handover bail).

### Documentation

- 2026-06-18T22:04-07:00 READMEs — user-facing docs for the service + Windows
  support across crates and GitHub. Root `README.md`: new "Running" section
  (foreground vs `triaged service install`, cross-platform transport note,
  handover caveat). `crates/triaged/README.md`: "Running as a background service"
  command/mechanism tables (added earlier with the feature). `crates/triage/
  README.md`: daemon-start prerequisite with the service option. `crates/
  triage-mcp/README.md`: "Prerequisite: a running daemon" note. Each links to the
  `triaged` crate docs for detail.
- 2026-06-18T22:45-07:00 `crates/triaged/README.md` — added a platform-support
  paragraph to the intro (macOS/Linux/Windows, the per-platform control-plane
  transport, login-service registration, ConPTY vs PTY) so the description states
  the cross-platform story up front instead of only in the Windows section.
- 2026-06-18T22:55-07:00 `flutter/triage_client/README.md` — fleshed out the
  Flutter client README, which had a description but no instructions. Added:
  supported platforms (Web/iOS/Android/macOS/Windows/Linux); "Getting the client"
  (prebuilt release builds linking the `triaged` unsigned-binary steps, plus
  build-from-source with Flutter 3.44 stable — `flutter pub get` / `run` /
  `build`); "Connecting to a daemon" (address formats, `ws://127.0.0.1:7777/ws`
  default, device-code + PIN pairing linking the `triaged` Pairing section, the
  no-TLS/reverse-proxy caveat); and a Development (`analyze`/`test`) note.
  Corrected "secure WebSocket" → plain WS (the daemon terminates no TLS itself).

### PR review comments (Copilot, #88)

- 2026-06-18T22:35-07:00 `crates/triaged/src/ipc.rs` — Copilot flagged that the
  pipe-name cap measured `chars().count()`, but NPFS's 256-limit is in **UTF-16
  code units**; a non-BMP char is one `char` but two units, so a capped token
  could still overflow. Fixed: `MAX_PIPE_TOKEN_LEN` is now a UTF-16-unit budget,
  measured with `encode_utf16().count()`, and the over-long prefix is built by
  `truncate_utf16_units` (accumulates `char::len_utf16`, stops on a char boundary
  so a surrogate pair is never split). Extended the test with a `🦀`-repeat
  (astral) input that would overflow under the old char-based cap.

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

Service feature and all four Windows follow-ups are done. Remaining validation /
polish, deliberately out of scope here:

- **Manual end-to-end service test per OS.** Template generation is unit-tested,
  but the actual `launchctl` / `systemctl --user` / `schtasks` install→start→
  status→uninstall round trip needs a manual smoke test on each platform.
- **Bounded-connect runtime check.** Compiles on the Windows target and is
  exercised by `windows-latest` CI, but the `ERROR_PIPE_BUSY` timeout path
  itself isn't directly asserted — worth a Windows lifecycle test someday.
- **Windows service stop granularity.** `service stop` does a best-effort
  `taskkill /IM triaged.exe`; with multiple users' daemons this is coarse.
  Consider matching the per-user task/pid instead.

## Commits

- aaa7551 — feat(triaged): manage triaged as a per-user login service
- 83461d6 — refactor(triaged): drop redundant pipe probe, cap pipe-name length
- ddf3e5d — fix(triaged): bound the Windows named-pipe client connect with a timeout
- f309af3 — fix(triaged): store upgraded web assets under %LOCALAPPDATA% on Windows
- 2187e0a — refactor(triaged): rename UnixSocket* to Ipc*, de-dup serve/handle_connection
- 30323cc — docs: document the triaged background service and cross-platform support
- ae43f10 — style(triaged): rustfmt service test assertion
- HEAD — fix(triaged): measure the pipe-name cap in UTF-16 code units
