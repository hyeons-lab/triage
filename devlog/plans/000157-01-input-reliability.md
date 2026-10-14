# 000157-01 — Input reliability: leases, parked input, heartbeat, indicator

## Thinking

Four mechanisms drop keystrokes or lie about connectivity:

1. **Handover wipes leases.** Adopt inserts `InputLeaseState::default()`
   and `HandoverSession` carries no lease, so after every reload the next
   write per typed session is denied. Fix: carry the lease through the
   handover state (`#[serde(default)]` for old blobs) and restore it on
   adopt. No LeaseChanged broadcast needed: clients resubscribe after the
   swap and refresh from attach responses, and nothing changed for them.
2. **Denied bytes are lost.** The client's lease-error path re-acquires
   but cannot retry what it never kept, and client-side retry is
   uncorrelatable without write acks. Fix server-side, where denial is
   known exactly: `write_input` parks denied bytes per (session, client)
   — cap 4KB, TTL 10s, lazy sweep — and still bails unchanged so the
   client re-acquires; the two acquire paths flush that client's parked
   bytes off-lock after a grant. Exactly-once by construction: denied
   means never written, flushed once, expired otherwise. Ordering holds:
   the daemon flushes during attach, the client's own pending flush
   arrives after the attach response.
3. **Disconnect windows drop input.** The `!isConnected` early return
   discards bytes; the buffer already survives reconnects and the lease
   flag already resets there, so route offline input into the buffer
   (same 4KB cap) and flush on re-acquire. Trigger the acquire
   proactively when a reconnect completes with pending bytes, instead of
   waiting for the next keystroke.
4. **No heartbeat; sticky indicator.** Add a 25s client heartbeat
   (`hello`, guarded like the stats poller plus a foreground guard):
   timeout/other-error tears the socket down through the existing close
   path, which drives reconnect and all status transitions. Auth errors
   mean alive-but-unpaired and must not tear down; skip while pairing.
   No daemon-side idle timeout: ghost leases self-heal via
   takeover-plus-park. Indicator: derive the displayed session status at
   render time — remote session + dead socket = 'disconnected' —
   instead of trusting the sticky string. No 'observing' state in v1:
   auto-acquire makes no-lease transient, and a flickering label would
   confuse more than it explains.

Open implementation details: hello's auth behavior pre-pairing, the
resubscribe-completed site for proactive flush, remaining
`session.status` render sites, handover/manager test harness shapes.

## Plan

1. D1: `lease` field on `HandoverSession` (serde default), thread through
   `serialize_active_sessions`, restore in adopt. Harness check first.
2. D2: `parked_input` map on `SessionManager` (precedent: `inboxes`);
   park on the two lease bails in `write_input`; take + flush in
   `attach_session` acquire and `acquire_input_lease`, off-lock via
   `request_write_input`, best-effort. Lock order sessions-then-parked
   everywhere, never inverted.
3. D1/D2 tests: handover round-trip preserves the holder; deny parks +
   acquire flushes (prove red pre-fix where runnable). Then `cargo fmt`,
   `cargo clippy -p triaged --all-targets -- -D warnings`, focused tests.
4. C1: buffer (don't drop) when offline in `_sendRemoteSessionInput`;
   proactive acquire-with-flush when a reconnect completes with pending
   bytes; per-session cleanup on session removal if a clean site exists.
5. C2: 25s heartbeat timer mirroring the stats poller's lifecycle;
   failure tears down through `_onWebSocketClosed`; auth errors and
   pairing state exempt. Check hello's signature/cost first.
6. C3: pure `effectiveSessionStatus` helper + unit test; apply at every
   `session.status` render site.
7. `flutter analyze`, affected `flutter test` files, devlog, commit, push
   with explicit refspec, open PR.
