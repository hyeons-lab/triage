# 000163: feat/host-stats

## Agent

- Muse Code powered by Meta Muse Spark, session fern-metis.
- 2026-10-18T17:33-0700: Antigravity @ triage branch feat/host-stats

## Intent

Show host CPU usage, battery level, and charging state in the daemon
selector in the side rail, so a quick glance tells whether the machine is
pegged or about to die. Builds on the existing 60s `getDaemonStats` poll.

## What Changed

- `crates/triage-core/src/host.rs` (new): CPU % from tick deltas (Mach CPU
  load info / `/proc/stat` / `GetSystemTimes`, preserving the last reading
  across same-tick polls and caching the macOS Mach host port) and battery
  % + state (`pmset` with 15s TTL cache / sysfs / `GetSystemPowerStatus`,
  handling `"not charging"`, unreadable secondary Linux `BAT*` bays, and
  Win32 `BatteryFlag` bitmasks); `#[serde(other)]` on `BatteryState::Unknown`.
- `crates/triage-core/schema/triage.fbs`: `BatteryState` enum; `cpu_percent`
  / `battery_percent` (`int16`, default -1) + `battery_state` appended to
  `HelloResult` and `DaemonStatsResult`.
- `crates/triage-transport-ws`: `ServerResult` fields, shared
  `current_host_stats()` tuple unpacking, FBS builders/decoders with
  unknown/clamp mapping, round-trip tests for both `HelloResult` and
  `DaemonStatsResult`.
- Flutter: regen bindings, extended `DaemonStatsRecord` + decoders (with
  finite-number guards) + per-leg `mergeDaemonStats` non-flicker merge,
  `formatHostStats`, `hostStatus` line in the daemon selector pill.
- Tests: Rust host unit tests (including unsigned Mach ticks above `i32::MAX`,
  same-tick sampler preservation, `pmset` `"not charging"`, Linux sysfs
  tempdir aggregation, and Windows `BatteryFlag` bitmasks), FBS round-trips
  incl. `HelloResult` and unknown, Dart formatter/decoder/merge/FBS/widget
  tests.

## Decisions

- Zero new deps: hand-rolled like `disk.rs` (Mach FFI via libSystem,
  `pmset` parse, sysfs, windows-sys with three added features).
- `-1 = unknown` with explicit FBS defaults, since 0 is valid for both
  legs; unknown battery states from future daemons map to Unknown rather
  than failing the hello decode.
- Segments hide independently; desktops show CPU only; poll updates merge
  per leg so a transient unknown on one probe never flickers a sibling leg
  out.

## Issues

- Trigger: user couldn't tell the machine was pegged (load 150) from the
  client; wants CPU + battery/charging visible per daemon.

## Commits

- 2d213f3: feat(stats): host CPU and battery in the daemon selector
- 88b1156: docs(devlog): record 192 deploy verification
- HEAD: fix(stats): harden host CPU/battery probes and per-leg stats merge

## Progress

- 2026-10-05T10:16-0700: branch cut from stack top
  (`feat/session-lifecycle-push` @ eed2c61); discovery starting.
- 2026-10-05T10:33-0700: implemented + verified. Live probe: CPU 30% at
  load ~4.4, battery 100% Full matching pmset. fmt/clippy clean; core
  108, transport 40, triaged 343 + 8 pre-existing; flutter 676.
- 2026-10-05T10:41-0700: PR 192 open (stack 8/8). Release-built, installed,
  reloaded: 64 sessions preserved. Live: hello + 3 polls carry
  cpu/battery (60->31->26 settling, 100/full steady); served bundle md5
  matches. Charging/discharging/unknown states covered by parser tests
  (this Mac sits at full on AC).
- 2026-10-18T17:33-0700: rebased onto `feat/session-lifecycle-push` and
  addressed Round 1 review findings (cache `mach_host_self()` port in
  `OnceLock`, read Mach `cpu_ticks` as unsigned `u32`, preserve CPU reading
  across same-tick polls and use `checked_sub` for counter wraps, cache
  macOS `pmset` for 15s, handle `"not charging"` on macOS/Linux/Windows,
  skip unreadable Linux `BAT*` bays, add `#[serde(other)]` on
  `BatteryState::Unknown`, merge `DaemonStatsRecord` per leg in the client,
  and expand Rust/Flutter unit and FlatBuffers tests).

## Research & Discoveries

- Plan 000163-01 initially proposed `kern.cp_time` via `sysctlbyname` on
  macOS, but `kern.cp_time` is absent on modern macOS; switched to Mach
  `host_statistics64(HOST_CPU_LOAD_INFO)` linked from `libSystem`.
- `mach_host_self()` is a Mach trap (`host_self_trap`) that increments the
  send-right user reference count on each call, unlike `mach_task_self_`,
  so the returned port must be cached in a `OnceLock` (or deallocated).

## Lessons Learned

- Composite poll records that bundle independent probes (disk, CPU, battery)
  must merge per leg over the previous reading rather than replacing the
  entire record wholesale when any single leg is usable.
