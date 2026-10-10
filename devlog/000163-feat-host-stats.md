# 000163: feat/host-stats

## Agent

2026-10-05T10:16-0700.

## Intent

Show host CPU usage, battery level, and charging state in the daemon
selector in the side rail, so a quick glance tells whether the machine is
pegged or about to die. Builds on the existing 60s `getDaemonStats` poll.

## What Changed

- `crates/triage-core/src/host.rs` (new): CPU % from tick deltas (Mach CPU
  load info / `/proc/stat` / `GetSystemTimes`) and battery % + state
  (`pmset` / sysfs / `GetSystemPowerStatus`); best-effort `Option`s.
- `crates/triage-core/schema/triage.fbs`: `BatteryState` enum; `cpu_percent`
  / `battery_percent` (`int16`, default -1) + `battery_state` appended to
  `HelloResult` and `DaemonStatsResult`.
- `crates/triage-transport-ws`: `ServerResult` fields, gather wiring, FBS
  builders/decoders with unknown/clamp mapping, round-trip tests.
- Flutter: regen bindings, extended `DaemonStatsRecord` + decoders,
  `formatHostStats`, `hostStatus` line in the daemon selector pill.
- Tests: 7 Rust host unit tests, FBS round-trips incl. unknown, Dart
  formatter/decoder/usability/widget tests.

## Decisions

- Zero new deps: hand-rolled like `disk.rs` (Mach FFI via libSystem,
  `pmset` parse, sysfs, windows-sys with two added features).
- `-1 = unknown` with explicit FBS defaults, since 0 is valid for both
  legs; unknown battery states from future daemons map to Unknown rather
  than failing the hello decode.
- Segments hide independently; desktops show CPU only.

## Issues

- Trigger: user couldn't tell the machine was pegged (load 150) from the
  client; wants CPU + battery/charging visible per daemon.

## Commits

- 494e380: feat(stats): host CPU and battery in the daemon selector
- d171064: docs(devlog): record 192 deploy verification
- HEAD: fix(stats): review findings from host-stats audit

## Progress

- 2026-10-05T10:16-0700: branch cut from stack top
  (`feat/session-lifecycle-push` @ eed2c61); discovery starting.
- 2026-10-05T10:33-0700: implemented + verified. Live probe: CPU 30% at
  load ~4.4, battery 100% Full matching pmset. fmt/clippy clean; core
  108, transport 40, triaged 343 + 8 pre-existing; flutter 676.
- 2026-10-05T10:41-0700: PR 192 open (stack 8/8). Release-built, installed,
  reloaded: 64 sessions preserved. Live: hello + 3 polls carry
  cpu/battery (60→31→26 settling, 100/full steady); served bundle md5
  matches. Charging/discharging/unknown states covered by parser tests
  (this Mac sits at full on AC).
- 2026-10-09T22:49-0700: Rebased onto feat/session-lifecycle-push (5ea5853).
  Completed 8-pillar code review audit and resolved findings: deallocated
  Mach host port send rights via mach_port_deallocate, declared tick array
  as unsigned [0u32; CPU_STATE_MAX] to prevent signed overflow, rate-limited
  CPU sampling (1s) and battery reading (15s) via CachedReading to eliminate
  pmset fork overhead and cross-client jitter, prioritized "not charg"
  substring checks before affirmative "charg", made Linux multi-battery
  bay iteration resilient against unreadable bays, checked Windows
  BatteryFlag charging bit, merged partial poll metrics in Flutter client
  to prevent UI flickering, added serde(other) and wire-omission attributes,
  and added unit/widget regression tests. Round 2 confirmation review
  completed cleanly with zero findings across all 8 pillars.

## Research & Discoveries

- (pending)

## Lessons Learned

- (pending)

## Next Steps

- Cascade rebase to PR 193 (fix/scrollback-paging).
