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
- Viewport-first replay: `trimHistoryTail` in `terminal_store.dart`
  (newest 1000 lines / 256 KiB, SGR-reset prologue, original end-offset
  baseline preserved for delta merges); daemon `RAW_OUTPUT_TAIL_CAP` cut
  1 MiB -> 256 KiB; Rust `snapshot_history_matches_the_served_tail_cap`
  pins the production cap, Dart `history_trim_test.dart` + store tests pin
  the trim behavior.
- Crash fix: `SessionVm` copies `rows` in its initializer so the field
  stays mutable — lazy rail placeholders seeded `const []` and the snapshot
  refresh's `..clear()..addAll()` threw `Cannot clear a constant list`,
  aborting the load. Regression test `rows stay mutable for the refresh
  clear-and-seed` failed before, passes after.

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
  Amended per user feedback: the toggle moved to the workspace header (next
  to judge/refit) and the accessory `kbd` key was removed, so the bottom
  bar keeps input keys only. The header key shows only where a soft keyboard
  can raise (native mobile + mobile web), via a null handler elsewhere.
- Activity sort re-ranks on local interaction: selecting, typing, or tapping
  a session bumps its stamp above every other (via `_nextLocalActivityStamp`,
  never the local clock) and re-sorts after a 1s debounce, so the rail
  tracks what the user touched instead of freezing at load-time daemon
  stamps. Stamps stay local; the next daemon context fetch re-asserts.
- Activity sort orders by daemon input recency, not output: the daemon
  stamps `last_input_ms` on every input write (persisted, handed over,
  restored like the output stamp) and the rail sorts by it, so a noisy
  background job no longer outranks typed-in sessions. No output fallback:
  never-touched sessions sort as unknown (last), which is the truth. The
  client stamp renamed `lastActivityMs` to `lastInteractionMs` to match.
- The debounced regroup waits out an open session context menu instead of
  sliding the row out from under it.

## Issues

- `triage-hook` test `detects_antigravity_and_claude_signatures` fails on
  pristine `main` too (verified in the main checkout) — pre-existing, not
  caused by this branch, which does not touch that crate.
- Mid-session the machine hit ENOSPC (115MB free), blocking all writes. Found
  ~69GB of agent probe/repro scratch in `/private/tmp` plus a 16GB bazel
  cache; user cleared some space themselves, then approved deleting /tmp
  entries older than 24h (kept bazel). Freed ~35GB (37GB available).
- 8 pairing tests (device-code flows in `http_tests`/`ipc`/`session`)
  fail on this branch because the merged tailscale-pairing work disables
  device-code pairing by default; verified byte-identical failure set with
  the replay changes stashed, so pre-existing relative to this commit.

## Commits

- 1601005 — feat(client): disk space line, rail sort toggle, keyboard kill switch
- 456b5ca — fix(client): address PR review on disk stats, sort restore, keyboard routing
- 4c83c33 — feat(core): probe disk space on Windows via GetDiskFreeSpaceExW
- 449ae5a — feat(client): header keyboard toggle; interaction re-ranks activity sort
- 7d6d21e — feat: sort rail by daemon input recency; regroup waits for menus
- 7cc7f9e — fix(client): merge create/push duplicate tiles; observe without stealing input leases
- 235c4e8 — fix(client): order input-unknown rail tier by output activity
- b954662 — feat(mcp): session-to-session messaging via side inboxes
- ba9fdc7 — feat(skills): installable coordination skill + label-aware MCP list
- 56b3cd7 — fix(review): harden probe pins, installer symlink checks, tier tests
- 3ad3e11 — feat(security): Tailscale-identity SSO pairing
- 2a09d98 — fix(client): viewport-first history replay; 256 KiB daemon tail cap
- HEAD — fix(client): SessionVm rows defensive copy; lazy sessions crashed refresh

## Progress

- 2026-09-28T22:15-0700: added installable `triage-coordination` skill
  (plan 000154-02) so agents know how to use the MCP messaging tools.
  Custom labels were invisible over MCP — the only distinguisher the user
  has — so `list_sessions` items now carry `custom_label`, backed by a new
  `GetRailLayout` IPC variant pair (`IpcClient` + dispatch). Read-only on
  purpose: agents route by labels the user assigns in the UI. Skill
  documents the discover-by-label loop (with repo/branch/worktree/cwd/
  snippet fallback), `$TRIAGE_SESSION_ID` self-identification, and
  send/poll/ack etiquette plus the known limits. `install.sh` mirrors
  agent-review-loop (5 targets, link/upgrade/dry-run, no refinements);
  `tests/verify-install.sh` covers install/idempotence/link/upgrade/
  dry-run against a fake HOME (15/15). Also fixed the MCP READMEs' stale
  read-only claim and tools table. Gates: fmt, clippy `-D warnings`,
  triaged 322 + mcp 11, shellcheck clean.
- 2026-09-28T21:55-0700: folded session-to-session messaging into this PR
  (one large PR, split before merge). Contract (`SessionMessage` + 3
  `SessionApi` methods with default deny impls) and daemon side inboxes
  (peek + idempotent ack, full-inbox rejection) came over from the
  `feat/session-messaging` branch; IPC wire variants + `IpcClient` +
  server dispatch and the three MCP tools
  (`send/receive/ack_session_messages`) were finished here. Gates: fmt,
  clippy `-D warnings`, Rust suites green except the pre-existing
  env-dependent `triage-hook` signature test (detects the running agent;
  untouched crate), `flutter test` untouched by this half. Also cleared
  28GB of >24h-old `/tmp` scratch after the disk filled mid-test-run.
- 2026-09-28T21:55-0700: fixed sort collapse after handover from a daemon
  predating input tracking. Reloading the PR #181 daemon over a main-based
  one adopted all sessions with `last_input_ms: 0` (handover
  `#[serde(default)]`); the rail sorts on input only, so every stamp tied at
  0 and the rail fell back to creation order. Fix: two-tier
  `compareRecencyStamps` in `session_grouping.dart` — known input outranks
  unknown input by input, and the unknown tier orders by output instead of
  creation order. First attempt (single blended stamp) was rejected by the
  existing "orders by input recency, not output" widget test: folding
  output into the same scale lets a noisy unknown-input job outrank a
  typed-in session, so the tiers must not share a scale. Threaded
  `lastOutputMs` through `SessionOrderingInput`/`SessionGroup`/`SessionVm`
  (bulk load, both ordering-input builders, open-session carry-forward);
  `session_started` push untouched (new sessions have no history). 5 new
  unit tests, full `flutter test` 620/620, `flutter analyze` clean. Daemon
  change not needed (it truthfully reports 0); needs an APK reinstall to
  reach the phone.
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
- 2026-09-26T18:22-0700: moved the keyboard toggle to the workspace header
  per user feedback (accessory `kbd` key removed; header key gated on
  `isMobilePlatform` via null handler) and fixed activity sort going stale
  (selection and terminal interaction now bump the stamp and re-sort after
  a 1s debounce). Widget tests for the header key states, the `kbd`
  removal, and tap-to-re-rank with debounce (each revert-verified). Gates:
  `flutter analyze`, `flutter test` (609 passed). Release APK installed on
  the Pixel over wireless adb for on-device check.
- 2026-09-26T20:46-0700: user reported activity order wrong on web (rarely
  used sessions on top) plus menu/row desync on right-click. Root causes:
  daemon activity is output recency (documented in schema), and the
  debounced regroup could fire under an open menu. Fixed with daemon-side
  `last_input_ms` (schema, JSON, FlatBuffers, persist, handover, restore;
  per user choice of daemon source over device-local history), client
  input-first ordering with the stamp renamed to `lastInteractionMs`, and
  regroup deferral while a context menu is open. Tests: input stamping +
  demotion carry (Rust), FB/JSON round-trips, input-vs-output ordering and
  menu deferral (widget), each revert-verified. Gates: fmt, clippy
  `-D warnings`, cargo suites (minus pre-existing ambient hook failure),
  bindings check, `flutter analyze`, `flutter test` (611 passed).
- 2026-09-28T12:20-0700: user reported single-tap new session spawning
  multiple stuck tiles showing the same session, plus mid-typing dropped
  letters on mobile. Root cause: the daemon broadcasts `session_started` at
  spawn, so the push can land while create still awaits subscribe/attach; the
  push handler plants a placeholder and the create path then inserts a second
  tile for the same id. Twins share one rail key (element miswiring leaves
  the visible pane on the stuck placeholder) and fight over the input lease,
  which is the drops. Fix: create replaces an existing same-id tile in place
  (mirroring the load path, incl. controller rebind) instead of inserting.
  Regression widget test plants the push before tapping create: red (3 keyed
  widgets for one id), green after. Gates: `flutter analyze`, `flutter test`
  (612 passed). Rust untouched.
- 2026-09-28T12:20-0700: user confirmed drops happen mid-typing in ALL
  sessions on both mobile and web, so the twin-tile fix can't be the whole
  story. Investigated down the stack and exonerated each layer with evidence:
  daemon input/output paths never drop (zero drop lines in the log; the two
  grep hits were my own commands in judge records), output fan-out replays
  rather than drops, the WS send is ordered fire-and-forget, the mobile IME
  path is phone-only but web drops too, and there is no lease TTL. Remaining
  lossy step: daemon lease rejections of writes ("does not hold input
  lease"), whose bytes are lost with no retry. Root cause of the flapping:
  every client attach (select, load, refresh, resubscribe) used
  InteractiveController, so merely LOOKING at a session stole its lease from
  the other client/agent typing there; plus the lease-error handler cleared
  the selected session instead of the rejected one, flapping innocents.
  Fix (client-only): Observer on select/load/refresh/revive with the flag
  resynced from the attach response's lease holder (both transports already
  carry it; create keeps Interactive since a fresh lease has no victim),
  typing still acquires on demand via buffer-and-flush, and the error
  handler targets the session named in the message with selected-session
  fallback. Three widget tests (Observer-on-select, first-keystroke
  acquire+deliver, named-session error retarget), each red before / green
  after. Gates: `flutter analyze`, `flutter test` (615 passed), no fallout.
  Left uncommitted (no explicit commit ask); still needs push + web/APK
  rebuild + reinstall + daemon reload for on-device verification.

## Research & Discoveries

## Lessons Learned

- 2026-09-29T08:52-0700: restoring a file with `mv backup target` preserves
  the backup's old mtime, so cargo sees the target as unchanged and re-runs
  a stale test binary. After a mutant probe restored this way, both disk
  probe pins kept failing on already-restored source until `touch` forced a
  rebuild. Prefer `cp` (fresh mtime) for mutant restores, or `touch` after
  `mv`. The scare was pure staleness: the pins genuinely fail under the
  hardcoded-zeros mutant and pass on real code.
- 2026-09-29T08:52-0700: a regression test for a symlink-ancestor walk
  initially passed under the leaf-only mutant because the planted link sat
  at a level that was itself another file's leaf parent, so the old check
  fired first. A distinguishing test must plant the fault where the old
  logic is blind: the link went to a middle level no file's parent, with
  the nested fixture one level deeper. Always run the new test against the
  old code before trusting it.

## Next Steps

- Implement disk stats (Rust then Dart), sort toggle, keyboard toggle.
- `cargo fmt`, `cargo clippy --all-targets --all-features -- -D warnings`,
  `cargo test --workspace` (scoped as needed), `flutter analyze`,
  `flutter test`.
