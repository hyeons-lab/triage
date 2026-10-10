# 000163-01: Host CPU + battery in the daemon selector

## Thinking

The stats vertical already exists: `triage_core::disk` gathers
(libc-only, best-effort `Option`), the transport calls it per
`GetDaemonStats` and per hello, `DaemonStatsResult` (FBS + JSON) carries
it, and the rail's `_ConnectionStatus` pill renders one `diskStatus`
line. CPU + battery extend the same pipe with no architecture change.

Gathering (new `triage_core::host`, mirroring `disk.rs`, zero new deps):
- CPU % from cumulative tick deltas: macOS `kern.cp_time` via
  `sysctlbyname`, Linux `/proc/stat`, Windows `GetSystemTimes`
  (windows-sys already a dep; add the feature). A process-static
  last-sample makes each poll self-contained; the first poll seeds and
  reports unknown. Pure delta math is unit-testable; wrap/zero-delta
  yields unknown, never bogus.
- Battery % + state (charging/discharging/full/unknown): Linux sysfs
  (`capacity` + `status`), Windows `GetSystemPowerStatus`, macOS `pmset
  -g batt` parse (IOKit would need new FFI deps; pmset's format is
  decade-stable and a 60s fork is negligible). Pure parsers, unit-tested.
  Desktops (no battery) report unknown and the client hides the segment.

Protocol: append `cpu_percent` / `battery_percent` (`int16`, default
-1 = unknown: 0 is a valid reading, so the disk 0/0 convention cannot
apply) and a `BatteryState` byte enum to `DaemonStatsResult` and to
`HelloResult`'s appended stats, with explicit FBS defaults so new-client
+ old-daemon reads unknown instead of 0. JSON: null/absent = unknown.
Dart bindings regenerated with the pinned flatc script.

Client: extend `DaemonStatsRecord`, decode both protocols, add a
`hostStatus` line under disk in `_ConnectionStatus`
("CPU 12% · Battery 87% (charging)"), segments hidden when unknown.

## Plan

1. `triage-core/src/host.rs`: tick samplers + delta math + battery
   probers + parsers; unit tests on the pure fns; live smoke tests
   (gated like disk's: succeed-or-unknown, never bogus).
2. Transport: `ServerResult::DaemonStats`/hello structs + JSON encode +
   FBS builder/parser for the three fields; extend the FBS round-trip
   tests.
3. Schema: append fields + enum with defaults; regen Dart bindings via
   `scripts/generate-dart-flatbuffers.sh`.
4. Dart: record + decoders + `formatHostStats` + pill line; widget/unit
   tests for formatting and hide-on-unknown.
5. Gates: fmt, clippy, focused + full Rust suites, analyze, flutter test.
6. Commit, push with explicit refspec, PR stacked on #191 (8/8).
7. Release-build, install, reload, verify rail line against
   `pmset -g batt` / load on the Mac.
