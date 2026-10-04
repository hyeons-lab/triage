# 000162 — feat/session-lifecycle-push

## Agent

Muse Code powered by Meta Muse Spark, session fern-metis.

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

- No protocol change: the push chain (broadcast → transport → decode →
  handlers) already existed and was verified live; the work is a daemon
  leak fix plus client anti-entropy for missed pushes.
- Reconcile reuses the push application paths (no second rail-mutation
  implementation); idempotent guards make push/reconcile races safe.
- Label conflicts resolve daemon-wins on present keys, push-local-up on
  absent keys — same rule as the connect-time load.

## Issues

- Trigger: user shutdown of stuck session-294 then recreated 295 as
  `cera-gaps`; remote web client held the dead row (blank frozen pane) with
  no refresh trigger to discover 295.

## Commits

- HEAD — feat(rail): reconcile rows and labels; forget labels on shutdown

## Progress

- 2026-10-04T16:34-0700: branch cut from stack top (`fix/context-list-fanout`
  @ a281de5); discovery starting.
- 2026-10-04T16:58-0700: implemented + verified. Daemon label test fails
  pre-fix, passes post; widget reconcile test fails with the timer
  disabled, passes enabled. fmt/clippy clean; triaged lib 343 pass + 8
  pre-existing pairing failures (identical set on clean base); transport
  39 pass; flutter 667 pass.

## Research & Discoveries

- `SessionEvent` has `Exited` but no created/removed; subscriptions are
  per-session, so lifecycle needs a daemon-wide channel.
- Client handles `Exited` by marking the row, never removing it.

## Lessons Learned

- (pending)

## Next Steps

- Discover broadcast infra + shutdown/label semantics; write plan 000162-01.
