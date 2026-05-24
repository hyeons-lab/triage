# Fix Session Loading and Terminal Event Sync

## Thinking
The user reported that when opening a new session, the terminal output doesn't load and remains blank.
Upon investigation, the root cause is that:
1. In `main.dart`, `_createSession` and `_loadDaemonSessions` were updated to subscribe to events using `afterEventSeq: snapshot?['output_seq']`.
2. However, `after_event_seq` in the daemon's subscription logic expects the sequence number of the *events* in the actor's event log (`self.next_event_seq`), NOT the PTY output sequence (`self.output.output_seq`).
3. Because `output_seq` (e.g. 1) is completely different and typically higher than the starting `event_seq` (0) for new sessions, passing it as `after_event_seq` causes the subscriber's sequence number to be set to a future value (e.g. 2).
4. Consequently, the daemon filters out and drops all subsequent output events (which start from sequence 0) for this subscriber, resulting in a blank screen where no terminal output ever loads.

To solve this cleanly, robustly, and without any race conditions:
1. We will NOT pass `afterEventSeq` when subscribing to events. We will let it default to `None` (which subscribes to events starting from the current sequence in the daemon).
2. To avoid the race condition where PTY startup output (printed between subscribing and attaching) could be dropped or duplicated:
   - We will subscribe to session events *before* calling `attachSession`.
   - We will introduce a new `outputSeq` field on `SessionVm` initialized from the snapshot's `output_seq`.
   - We will extract `output_seq` from the incoming `SessionEvent::Output` websocket events.
   - If the event's `output_seq` is less than or equal to the session's current `outputSeq`, we will ignore the event since that output is already present in the snapshot.
   - If the event's `output_seq` is greater than the session's current `outputSeq`, we will write the output to the terminal and update the session's `outputSeq`.
3. To handle the brief window between calling `subscribeSessionEvents` and inserting the session into `_sessions`, we will introduce a thread-safe/event-loop-safe buffering map `_pendingEvents` in the home state.
   - Any event received for a session not yet present in `_sessions` will be stored in `_pendingEvents`.
   - Immediately after a session is successfully added to `_sessions`, we will drain and process its buffered pending events.

This design is 100% correct, avoids any data drops or duplications, and resolves the issue elegantly.

## Plan
1. Add `int outputSeq = 0;` field to `SessionVm` class in `flutter/triage_client/lib/main.dart`.
2. Introduce `final Map<String, List<Map<String, dynamic>>> _pendingEvents = {};` in `_TriageHomeState`.
3. Modify `_onWebSocketEvent` to:
   - Extract the `sessionId` from incoming `Output`, `Exited`, and `LeaseChanged` events.
   - If the session is not yet in `_sessions`, add the message to `_pendingEvents[sessionId]`.
   - If the session is in `_sessions`, verify that for `Output` events, the event's `output_seq` is strictly greater than `session.outputSeq`. If so, process it, write it to xterm.js, and update `session.outputSeq = eventSeq`. Otherwise, safely ignore it.
4. Update `_loadDaemonSessions` to:
   - Call `subscribeSessionEvents(sessionId: sid)` *first* (without passing `afterEventSeq`).
   - Call `attachSession` *second*.
   - Populate `SessionVm` with `outputSeq: snapshot?['output_seq'] as int? ?? 0`.
   - Add to `_sessions`.
   - Drain and replay any `_pendingEvents[sid]`.
5. Update `_createSession` to:
   - Call `subscribeSessionEvents(sessionId: sessionId)` *first* (without passing `afterEventSeq`).
   - Call `attachSession` *second*.
   - Populate `SessionVm` with `outputSeq: snapshot?['output_seq'] as int? ?? 0`.
   - Add to `_sessions`.
   - Drain and replay any `_pendingEvents[sessionId]`.
