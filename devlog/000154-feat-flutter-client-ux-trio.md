# 000154 — feat/flutter-client-ux-trio

## Agent

Muse Code powered by Meta Muse Spark. Session fern-metis, 2026-09-25T18:03-0700.

## Intent

Three Flutter client requests in one branch:

1. Show the daemon host's remaining free disk space in the daemon selector
   (upper left), below the "Connected to Daemon" line, same font size, as
   MB free plus percentage.
2. Toggle the sessions list between the default per-repo grouping and a flat
   list ordered by last interaction, independent of repo.
3. A button on mobile clients to disable the soft keyboard (and re-enable it),
   which pops up uninvited and causes layout/scroll churn.

## What Changed

- Plan: `devlog/plans/000154-01-flutter-ux-trio.md`.
- Disk space: `triage-core/src/disk.rs` (statvfs probe of the state-dir
  volume), `disk_free_bytes`/`disk_total_bytes` on `HelloResult`, new
  `get_daemon_stats` request + `DaemonStatsResult`, Dart bindings
  regenerated, client seeds from hello and polls every 60s, free-space line
  under the connection status (`lib/daemon_disk_stats.dart` formats
  `"12,340 MB free (23%)"`, hidden when unknown).
- Sort toggle: `orderSessionsByActivity` in `session_grouping.dart` (shared
  comparator with repo grouping), per-server persisted `SessionRailSortMode`,
  toggle button in the SESSIONS header (icon names the target mode), flat
  mode renders one headerless group with whole-list session pinning.
- Keyboard toggle: `kbd` key on the shared accessory bar (lights while
  suppressed), `softKeyboardEnabled` on both terminal panes gating focus /
  IME / textarea activation, device-global persisted switch.
- Tests: Rust disk unit tests, `daemon_stats_reports_live_disk_probe`,
  flatbuffers hello + daemon-stats round-trips; Dart `daemon_disk_stats`
  format tests, `orderSessionsByActivity` tests, accessory-bar `kbd` tests.

## Decisions

- Disk stats ride the existing `hello` handshake (`HelloResult` gains
  `disk_free_bytes` / `disk_total_bytes`) rather than a new request type, so
  no new flatbuffers request/response plumbing is needed on either side.
  Amended during the branch (see the plan amendment): a pollable
  `get_daemon_stats` request was added alongside the hello fields, since the
  figure must refresh during long sessions; hello seeds it on connect and a
  60s poll keeps it current.
- The daemon stats the filesystem holding its state dir
  (`$HOME/.local/state/triage`, falling back to `$HOME`, then `.`) via
  `statvfs` on Unix and `GetDiskFreeSpaceExW` on Windows (caller-available
  bytes, mirroring `f_bavail`); anything else reports unknown (0/0) and the
  client hides the line.
- Flat sort mode reuses the existing pin machinery: one synthetic group, no
  headers, rows by activity; drags pin session ids as usual.
- Keyboard toggle lives on the shared accessory bar (`kbd` key), so native
  mobile and mobile web get it from one widget; state is device-global,
  persisted in prefs.

## Issues

- `triage-hook` test `detects_antigravity_and_claude_signatures` fails on
  pristine `main` too (verified in the main checkout) — pre-existing, not
  caused by this branch, which does not touch that crate.
- Mid-session the machine hit ENOSPC (115MB free), blocking all writes. Found
  ~69GB of agent probe/repro scratch in `/private/tmp` plus a 16GB bazel
  cache; user cleared some space themselves, then approved deleting /tmp
  entries older than 24h (kept bazel). Freed ~35GB (37GB available).

## Commits

- 1601005 — feat(client): disk space line, rail sort toggle, keyboard kill switch
- 456b5ca — fix(client): address PR review on disk stats, sort restore, keyboard routing
- HEAD — feat(core): probe disk space on Windows via GetDiskFreeSpaceExW

## Progress

- 2026-09-25T18:03-0700: worktree + branch created, plan written.
- 2026-09-25T19:00-0700: all three features implemented and validated —
  `cargo fmt --check`, clippy `-D warnings`, workspace tests (minus the
  pre-existing hook failure), Dart bindings `--check`, `flutter analyze`,
  `flutter test` (561 passed). Left uncommitted for review.
- 2026-09-26T10:26-0700: addressed Copilot + Antigravity review on PR #181.
  Disk-test flake fixed via invariant assertions; `hardwareKeyboardOnly`
  desktop regression fixed via extracted `terminalHardwareKeyboardOnly`
  predicate; `_restorePins` re-groups on restored sort mode; flat mode
  returns no groups for no sessions; focus retries gated on suppression;
  `f_frsize == 0` falls back to `f_bsize`; percent divides before scaling;
  collapsed tooltip carries disk status; poll guard checks `mounted`.
  Windows disk probing left out of scope (new platform feature; non-Unix
  reports unknown by design and the client hides the line). New widget test
  pins flat rail under daemon pins with stored byActivity; revert runs show
  it fails without the mode restore and passes without the race branch (the
  test env restores pre-load, so the race arm stays review-only). Gates:
  fmt, clippy, cargo tests, bindings check, `flutter analyze`, `flutter
  test` (607 passed); hook failure still the pre-existing ambient-env one.
- 2026-09-26T13:10-0700: user asked why Windows disk reporting was scoped
  out; fair point (same feature on a supported platform), so added it: new
  target-scoped `windows-sys` dep, `#[cfg(windows)]` probe, shared
  `disk_stats_from_bytes` tail, per-platform test gates. The Windows code is
  validated locally via `cargo check/clippy --target
  x86_64-pc-windows-msvc`, which caught a real bug (`PCWSTR` is a type
  alias in windows-sys 0.61, not a constructor); execution coverage comes
  from the CI windows leg.

## Research & Discoveries

## Lessons Learned

## Next Steps

- Implement disk stats (Rust then Dart), sort toggle, keyboard toggle.
- `cargo fmt`, `cargo clippy --all-targets --all-features -- -D warnings`,
  `cargo test --workspace` (scoped as needed), `flutter analyze`,
  `flutter test`.
