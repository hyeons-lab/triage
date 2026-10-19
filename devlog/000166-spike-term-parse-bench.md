# 000166: spike/term-parse-bench

## Intent

Phase −1 of the triage-term plan: benchmark 1 MiB replay on the Pixel for the
xterm 4.0 fork (status quo) vs xterm2 5.2.0. Proceed to the Rust crate only if
xterm2 misses the frame budget or emulation-consistency demands it; otherwise
do the xterm2 swap and shelve triage-term. Spike branch: no product code.

## What Changed

- Plan: `devlog/plans/000166-01-term-parse-bench.md`.
- 2026-10-02T17:41-0700 `flutter/triage_client/pubspec.yaml`, `pubspec.lock`: added `xterm2: ^5.2.0` under `dev_dependencies` so both `xterm` (4.0 fork) and `xterm2` coexist for side-by-side benchmarking.
- 2026-10-02T17:41-0700 `flutter/triage_client/tool/bench_payload.dart`, `tool/parse_bench.dart`: added deterministic SGR-heavy CRLF benchmark payload generator and headless parse throughput benchmark (`xterm4` vs `xterm2`, one-shot and 8 KiB chunked at 256 KiB and 1 MiB).
- 2026-10-02T17:41-0700 `flutter/triage_client/integration_test/replay_bench_test.dart`, `test_driver/replay_bench_driver.dart`: added profile-mode widget frame-time benchmark in ABBA order with timeline summary validation.

## Decisions

- Benchmark on device (Pixel) for the gate number; desktop iteration first for
  speed. Relative comparison is meaningful anywhere; the absolute frame budget
  needs the slowest target.
- Both packages coexist in one pubspec (`xterm` git override + hosted
  `xterm2`) since the names differ: no dep swap needed for the comparison.
- 2026-10-18T21:50-0700 Declare `xterm2` under `dev_dependencies`, terminate truncated benchmark payloads with `\x1b[0m\r\n` so replay never ends mid-escape sequence, and fail `replay_bench_driver.dart` with `StateError` if any expected timeline key is missing.

## Commits

- 73cbe61: spike(term-bench): phase -1 gate numbers; xterm2 holds one frame
- 1b2991d: docs(spike): note flutter drive uninstalls device app
- HEAD: fix(term-bench): harden benchmark payload/driver, move xterm2 to dev_dependencies, and renumber devlog

## Progress

- 2026-10-02T16:57-0700: worktree + branch created, plan written (000166-01).
- 2026-10-02T17:41-0700: Phase −1 complete. Headless + widget benches built
  (`tool/`, `integration_test/`, `test_driver/`); host JIT/AOT, desktop
  profile, and two Pixel profile runs recorded. Gate decision STOP (see
  Research). Bench harness kept on the branch for the xterm2 swap to reuse.
- 2026-10-18T21:50-0700: rebased onto `fix/triage-hook-format-env`, renumbered
  devlog/plan to `000166`, moved `xterm2` to `dev_dependencies`, hardened
  payload truncation, widget teardown, and driver timeline verification.

## Research & Discoveries

- 2026-10-02T16:57-0700 headless bench (SGR-heavy CRLF payload,
  `maxLines: 50000`, host M-series): 256 KiB one-shot xterm4 15.9 ms JIT /
  13.8 ms AOT vs xterm2 7.6 / 3.7 ms; 1 MiB one-shot xterm4 54.5 / 57.1 ms
  vs xterm2 19.7 / 17.4 ms. xterm2 ≈ 2.6–3.7× faster; matches its published
  SGR numbers (~57 MiB/s).
- Widget bench (profile macOS, visible 800×600 TerminalView, 256 KiB
  one-shot): UI-thread block xterm4 15.3/19.8 ms vs xterm2 6.7/4.5 ms,
  in-app matches headless, validating the method. First run without warmup
  showed xterm4 avg build 71.9 ms (font/shader/first-paint); ABBA + warmup
  removed the bias, and timeline frame-build times miss sync-write blocks
  entirely (blocked thread produces no frames): the stopwatch is the real
  gate metric, timeline the first-paint check (both clean when warm).
- Pixel 10 Pro Fold gate (profile, 256 KiB one-shot, two ABBA runs):
  UI-thread block xterm4 36.5/24.4/39.8/27.6 ms (median ~32, ≈2 frames)
  vs xterm2 13.6/14.6/13.4/16.5 ms (median ~14, ≤1 frame). First-paint
  timelines too noisy (2 frames/trace) to separate packages. Wireless-adb
  drive needs `--no-dds` (DDS breaks the in-app VM-service websocket).
- GATE DECISION: STOP. xterm2 holds a one-frame (16.7 ms) budget with thin
  margin where xterm4 misses it 2×. The Rust crate would shave ~12 ms off
  an occasional one-shot event at a cost of weeks, unjustified on
  performance, and no current bug demands a shared core. Follow-up is the
  xterm2 swap with fork-parity verification, not triage-term. Neither
  package addresses the typing lag (separate, still undiagnosed) or
  reconnect frequency; chunked+yield replay remains good hardening for
  either package given xterm2's thin margin.
- `flutter drive` uninstalls the app package on completion (drive_service
  stop method). The gate runs wiped the user's release install from the
  Pixel; rebuilt and reinstalled `app-release.apk` from
  feat/flutter-client-ux-trio at ac06f3d after. Future on-device benches
  must reinstall the release APK as their last step.
