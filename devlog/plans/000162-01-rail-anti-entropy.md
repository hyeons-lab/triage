# 000162-01 — Rail anti-entropy + label cleanup

## Thinking

Discovery changed the shape of this task: the push chain already exists
end-to-end. The daemon broadcasts `SessionStarted` / `SessionTerminated` /
`SessionCustomLabelUpdated` over a global channel, the transport forwards
them on both protocols (verified live over JSON: label, started, and
snippet pushes all arrived), the Dart client decodes, routes, and handles
all three (insert/remove/relabel with regroup + reselect). Drain runs every
10ms against a 256-cap channel, so saturation drops are implausible.

What is actually broken:

1. `shutdown_session` forgets snippet/judge/inbox/parked state but NOT the
   custom label — session-294's `cera-gaps` survived its record and log
   dir. Certain daemon bug, small fix.
2. Global pushes are fire-and-forget with no replay: any miss (old
   service-worker-cached tab, a gap the client never noticed) leaves the
   rail stale until the next reconnect. The per-session event log has
   `after_event_seq` replay; globals have nothing.
3. Dropped global sends are silent (`try_send` Full is swallowed), so a
   future saturation regression would present exactly like this report
   with no log trail.

The fix has three parts. (1) Forget the label on shutdown, with a daemon
regression test. (2) Client anti-entropy: a 60s reconcile while connected
that diffs rail rows against `list_sessions` and reuses the existing
started/terminated application paths, plus a label diff against
`getRailLayout` reusing the label path. One ~1ms RPC per minute heals any
missed push from any cause; no protocol change. (3) Debug-log dropped
global sends with the message kind, so saturation is observable.

No FBS schema change, no new event types, no new RPCs.

## Plan

1. Daemon: `forget_custom_label` (or equivalent) in `shutdown_session`
   after record removal; add `shutdown_forgets_custom_label` lib test.
2. Daemon: debug-log `TrySendError::Full` in `broadcast_to_global_senders`
   with the `ServerMessage` kind.
3. Client: extract `_applySessionStarted` / `_applySessionTerminated` /
   `_applyCustomLabel` from the `_processWebSocketEvent` branches so push
   and reconcile share them; add a 60s `_railReconcileTimer` (mounted +
   connected only) that diffs ids and labels and applies the delta.
4. Dart tests for the reconcile diff/application over the extracted units.
5. Gates: fmt, clippy, `cargo test -p triaged --lib` (focused + full),
   `flutter analyze`, `flutter test`.
6. Commit, push with explicit refspec, PR stacked on #190 (7/7).
7. Release-build, install, reload, verify: label gone after shutdown;
   create/delete/label pushes observed; reconcile covered by tests.
