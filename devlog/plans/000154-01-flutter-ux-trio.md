# 000154-01 — Flutter UX trio: disk free, rail sort toggle, keyboard toggle

## Thinking

The three asks share the Flutter client but differ in scope. Disk free needs
daemon support: the client cannot know the daemon host's disk without the
protocol carrying it. The cheapest compatible carrier is the `hello`
handshake, which the client already issues on every connect, reconnect, and
daemon switch — so the value refreshes on exactly the events that already
rebuild the rail. A dedicated pollable request would add a new
ClientRequest/ServerResult pair plus flatbuffers tables on both sides for
fresher numbers; disk pressure changes slowly relative to a session, and the
hello path keeps the blast radius to two appended `uint64` fields plus
encode/decode. Staleness within one long-lived connection is the accepted
trade, noted for a follow-up if the user wants live polling.

Which filesystem? The daemon's own state dir (`$HOME/.local/state/triage`)
is what the daemon fills (logs, manifests); on typical single-volume hosts
this equals the root volume. Fall back to `$HOME` then `.` when the state
dir does not exist yet. `statvfs` via `libc` (already a unix dep of
triage-core) keeps the helper in the shared crate as a free function, so the
`SessionApi` trait and its five implementors stay untouched.

Flatbuffers compat: appended scalar fields default to 0 for old binaries,
and serde `#[serde(default)]` covers the JSON path both directions (old
daemon omits, new client defaults; new daemon adds, old client ignores).
0/0 means "unknown" and the client hides the line.

Sort toggle: `_applyPins` already funnels every rail order through
`groupSessionsByRepo` + `flattenGroups`. A flat mode that builds one
synthetic group of activity-ordered ids flows through the same path:
`buildRailItems` suppresses headers for a single group, and
`resolveRailReorder` degrades to whole-list session pinning, which stays
meaningful when switching back to grouped mode. Persist per server next to
the pins. Pure ordering helper goes in `session_grouping.dart` for unit
tests.

Keyboard toggle: both terminal panes gate IME/soft-keyboard behavior on a
mobile check today (`hardwareKeyboardOnly`, autofocus, tap-to-focus,
xterm.js activation). One `softKeyboardEnabled` flag threaded through both
pane constructors plus the shared accessory bar covers native iOS/Android
and mobile web from one state bit. Persist globally (device UX preference,
not per daemon). The accessory bar is always rendered on mobile, so the
`kbd` key is reachable with the keyboard both up and down.

## Plan

1. Rust — disk stats:
   - `crates/triage-core/src/disk.rs` (new): `DiskStats { free_bytes,
     total_bytes }`, `daemon_disk_stats() -> Option<DiskStats>` via
     `statvfs` on Unix, `None` elsewhere; unit test (total > 0,
     free <= total on Unix).
   - Export from `triage-core/src/lib.rs`.
   - `schema/triage.fbs`: append `disk_free_bytes` / `disk_total_bytes`
     to `HelloResult` with a compat comment.
   - `triage-transport-ws/src/lib.rs`: extend `ServerResult::Hello`
     (serde defaults), fill from `daemon_disk_stats()` in the hello
     handler; extend hello unit tests.
   - `triage-transport-ws/src/flatbuffers_proto.rs`: encode/decode the
     new fields (owned + borrowed); extend tests.
2. Dart — disk stats:
   - `scripts/generate-dart-flatbuffers.sh`, commit regenerated bindings.
   - `triage_websocket_client.dart`: surface the two fields from the
     FlatBuffers hello parse (JSON path already passes the map through).
   - New `lib/daemon_disk_stats.dart`: `formatDiskFree(free, total)` ->
     `"12,340 MB free (23%)"`, null when unknown; unit test.
   - `main.dart`: `_diskFreeBytes/_diskTotalBytes` state set from hello
     on connect, cleared on disconnect/switch; thread through
     `SessionRail` into `_ConnectionStatus` as a second line under the
     status, same 12px style; hidden when unknown.
3. Sort toggle:
   - `session_grouping.dart`: `orderSessionsByActivity(inputs, pins)`
     pure helper (pinned-first, activity desc, input-order ties);
     unit tests.
   - `server_store.dart`: `railSortModePrefKeyFor(serverId)`.
   - `main.dart`: `SessionRailSortMode` enum, per-server load/persist,
     `_applyPins` branches to a single activity-ordered group in flat
     mode, toggle `IconButton` in the SESSIONS header row.
4. Keyboard toggle:
   - `server_store.dart`: global `softKeyboardEnabledPrefKey`.
   - `terminal_accessory_bar.dart`: `kbd` key with `onToggleKeyboard` /
     `keyboardEnabled` (highlighted while suppressed).
   - Both panes: `softKeyboardEnabled` (default true) +
     `onToggleSoftKeyboard`; gate `hardwareKeyboardOnly`, autofocus,
     tap-to-focus/keyboard activation, and unfocus on disable.
   - `main.dart`: global load/persist, pass to `TerminalPane`, respect
     in refocus paths; accessory-bar test for the new key.
5. Validate: `cargo fmt --all -- --check`, `cargo clippy
   --all-targets --all-features -- -D warnings`, `cargo test
   --workspace` (or scoped), `flutter analyze`, `flutter test`.
   Regenerated bindings verified with `--check`.

## Amendment 2026-09-25T19:00-0700 — pollable daemon stats

The user asked for the disk figure to refresh during sessions (they keep
running out of disk mid-session), so hello-seeding alone is not enough.
Added a `get_daemon_stats` request alongside the hello fields (schema union
append, request/response plumbing both sides, `DaemonStatsResult`): hello
seeds the line on connect, a 60s client-side poll keeps it current. Union
entries appended at the end so existing wire IDs do not shift.
