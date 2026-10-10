# 000162: feat/session-lifecycle-push

## Agent

2026-10-04T16:34-0700.

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
  label (memory + manifest); `broadcast_to_global_senders` debug-logs dropped
  pushes with the message kind.
- `crates/triage-transport-ws/src/lib.rs`: `ServerMessage::kind()` helper.
- `flutter/triage_client/lib/main.dart`: extracted `_applySessionStarted` /
  `_applySessionTerminated` / `_applyCustomLabelUpdated` from the push
  branches; added a 60s `_railReconcileTimer` (generation+server guarded,
  started/stopped with the stats poll) that diffs the rail against
  `list_sessions` + `getRailLayout` and replays the delta through those
  same paths.
- `flutter/triage_client/test/widget_test.dart`: reconcile widget test.

## Decisions

- No protocol change: the push chain (broadcast -> transport -> decode ->
  handlers) already existed and was verified live; the work is a daemon
  leak fix plus client anti-entropy for missed pushes.
- Reconcile reuses the push application paths (no second rail-mutation
  implementation); idempotent guards make push/reconcile races safe.
- Label conflicts resolve daemon-wins: the daemon is authoritative during
  periodic anti-entropy, clearing local labels for live sessions that lack
  a daemon label to prevent resurrecting deleted labels.

## Issues

- Trigger: user shutdown of stuck session-294 then recreated 295 as
  `cera-gaps`; remote web client held the dead row (blank frozen pane) with
  no refresh trigger to discover 295.

## Commits

- f254cf2: feat(rail): reconcile rows and labels; forget labels on shutdown
- c5f90b0: docs(devlog): record 191 deploy verification
- 19be91a: docs(devlog): correct deploy timestamp
- HEAD: fix(rail): review findings from session-lifecycle-push audit

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
- 2026-10-09T22:20-0700: Rebased onto fix/context-list-fanout (e02a592). Multi-agent
  review loop completed across 8 pillars (2 rounds). Resolved daemon authoritative
  label clearance during anti-entropy to prevent resurrection of deleted labels,
  eliminated duplicate shutdown manifest write with single atomic update, ensured
  immediate in-memory custom label eviction upon manifest commit, added reentrancy
  guards and mounted checks in rail reconcile, eliminated all em dashes, and
  strengthened unit and widget tests.

## Research & Discoveries

- `SessionEvent` has `Exited` but no created/removed; subscriptions are
  per-session, so lifecycle needs a daemon-wide channel.
- Client handles `Exited` by marking the row, never removing it.

## Lessons Learned

- In client-server anti-entropy reconciliation, treating absent backend entities
  as offline client edits resurrects deletions on every sync cycle; the backend
  must remain authoritative.
- In multi-threaded daemons, evict in-memory state immediately upon persistent
  commit success rather than after auxiliary teardown (such as thread joining),
  preventing concurrent operations from re-serializing obsolete state.

## Next Steps

- Push feat/session-lifecycle-push to origin upon user approval and cascade
  stack to feat/host-stats (PR #192).
