# 000163 — feat/host-stats

## Agent

Muse Code powered by Meta Muse Spark, session fern-metis.

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

- HEAD — feat(stats): host CPU and battery in the daemon selector

## Progress

- 2026-10-05T10:16-0700: branch cut from stack top
  (`feat/session-lifecycle-push` @ eed2c61); discovery starting.
- 2026-10-05T10:33-0700: implemented + verified. Live probe: CPU 30% at
  load ~4.4, battery 100% Full matching pmset. fmt/clippy clean; core
  108, transport 40, triaged 343 + 8 pre-existing; flutter 676.

## Research & Discoveries

- (pending)

## Lessons Learned

- (pending)

## Next Steps

- Discover DaemonStats shape + selector UI; write plan 000163-01.
