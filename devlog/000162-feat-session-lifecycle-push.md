# 000162: feat/session-lifecycle-push

## Agent

- Muse Code powered by Meta Muse Spark, session fern-metis.
- 2026-10-18T16:44-0700: Antigravity @ triage branch feat/session-lifecycle-push

## Intent

The rail only reflects sessions/labels as of (re)connect: sessions created or
shut down elsewhere never appear/disappear, and label edits don't propagate,
until a manual refresh. Push daemon-wide lifecycle events (created/removed,
label changed) over both protocols and apply them live in the rail. Also
fixes the label leak: `shutdown_session` deletes the record and log dir but
leaves the custom label behind (session-294's `cera-gaps` survived alongside
295's).

## What Changed

- `crates/triaged/src/session.rs`: `shutdown_session` now forgets the custom
  label in memory and excludes the retiring `session_id` from `custom_labels`
   inside `encode_manifest` across both `Live` and `Historical` teardown paths;
  `broadcast_to_global_senders` debug-logs dropped pushes with the message kind;
  `shutdown_session_forgets_the_custom_label` tests both live and historical
  sessions.
- `crates/triage-transport-ws/src/lib.rs`: `ServerMessage::kind()` helper plus
  `server_message_kind_matches_serde_type_tag_for_all_variants` unit test.
- `flutter/triage_client/lib/main.dart`: extracted `_applySessionStarted` /
  `_applySessionTerminated` / `_applyCustomLabelUpdated` from the push
  branches; added a 60s `_railReconcileTimer` (in-flight, generation, and
  server-id guarded, started after `_loadDaemonSessions` completes and stopped
  with the stats poll) that diffs the rail against `list_sessions`,
  `list_session_contexts` (when new sessions appear), and `getRailLayout`
  (adding, updating, and clearing removed custom labels when non-null) and
  replays the delta through those same paths without redundant `setRailLayout`
  RPCs when pins did not change.
- `flutter/triage_client/test/widget_test.dart`: reconcile widget test covering
  row addition with context enrichment, row removal, label addition, and label
  removal.

## Decisions

- No protocol change: the push chain (broadcast -> transport -> decode ->
  handlers) already existed and was verified live; the work is a daemon
  leak fix plus client anti-entropy for missed pushes.
- Reconcile reuses the push application paths (no second rail-mutation
  implementation); idempotent guards make push/reconcile races safe.
- Label conflicts in `_reconcileRail` treat a non-null `getRailLayout` as
  authoritative for custom labels (applying present labels and clearing local
  labels absent from the daemon's map) while skipping label mutations when
  `getRailLayout` returns `null` (unsupported or transient failure).

## Issues

- Trigger: user shutdown of stuck session-294 then recreated 295 as
  `cera-gaps`; remote web client held the dead row (blank frozen pane) with
  no refresh trigger to discover 295.

## Commits

- 634d824: feat(rail): reconcile rows and labels; forget labels on shutdown
- bc813bc: fix(rail): harden label manifest cleanup and rail anti-entropy reconcile
- HEAD: fix(rail): guard shutdown label removal and reconcile generation lifecycle

## Progress

- 2026-10-04T16:34-0700: branch cut from stack top (`fix/context-list-fanout`
  @ a281de5); discovery starting.
- 2026-10-04T16:58-0700: implemented + verified. Daemon label test fails
  pre-fix, passes post; widget reconcile test fails with the timer
  disabled, passes enabled. fmt/clippy clean; triaged lib 343 pass + 8
  pre-existing pairing failures (identical set on clean base); transport
  39 pass; flutter 667 pass.
- 2026-10-05T05:12-0700: PR 191 open (stack 7/7). Release-built, installed,
  reloaded: 69 sessions preserved. Live-verified label forget (set=true
  before shutdown, leaked=false after) and served bundle md5. Cleared the
  session-294 ghost label; only 295 carries cera-gaps now.
- 2026-10-18T16:44-0700: rebased onto `fix/context-list-fanout` and addressed
  Round 1 review findings (historical session shutdown manifest rewrite, single
  atomic manifest write excluding retiring `custom_labels`, `ServerMessage::kind`
  serde tag pin test, and `_reconcileRail` context enrichment, label deletion,
  in-flight guard, and `syncToDaemon` gating).
- 2026-10-18T17:01-0700: addressed Round 2 review findings (remove custom label
  before releasing `sessions` mutex in `shutdown_session` so concurrent
  `persist_manifest` calls cannot resurrect it, unlink temporary manifest file
  on `replace_manifest` error, recheck connection/pairing before starting
  `_railReconcileTimer` after `_loadDaemonSessions`, scope in-flight reconcile
  tracking by `_sessionLoadGeneration`, and seed restored local custom labels to
  the daemon when `_restoreCustomLabels` resolves after `_loadDaemonSessions`).

## Research & Discoveries

- `SessionEvent` has `Exited` but no created/removed; subscriptions are
  per-session, so lifecycle needs a daemon-wide channel.
- Client handles `Exited` by marking the row, never removing it.

## Lessons Learned

- Periodic anti-entropy reconcile loops must diff both additions and deletions,
  preserve local state when an optional bulk RPC returns `null`, and enrich
  newly discovered items with the same companion metadata (`list_session_contexts`)
  as initial load.

## Next Steps

- Complete Round 3 review on `feat/session-lifecycle-push`.
