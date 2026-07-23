# 000108-01 — Reconcile a stale web-origin selection with the current page origin

## Thinking

Follow-up to #107 (GitHub issue #109). #107 fixed `defaultWebSocketUriForBase`
so the web client dials the *page origin* when served behind a reverse proxy on
a non-7777 port. That fix is correct but only helps users with **clean storage**.

The web client adopts its daemon from the page origin: `webOriginServer` builds a
`web-<host>-<port>` entry, persisted and selected on first load
(`initState`'s `kIsWeb` branch). Server selection then runs in this order:

```dart
} else if (_activeServer != null) {   // a persisted selection short-circuits here
  _connectWebSocket();
} else if (kIsWeb) {                    // only reached with no selection
  final origin = webOriginServer(_defaultWebSocketUri());
  ...
}
```

A user who loaded the app on the pre-#107 build has `ws://127.0.0.1:7777/ws`
persisted as `web-127.0.0.1-7777` and **selected**. After #107 ships, that entry
still exists, `_activeServer != null` fires, and the client keeps dialing the
dead loopback address forever — `defaultWebSocketUriForBase` is never re-consulted.
Recovery today means manually forgetting the daemon.

### The fix

Before the selection cascade, on web, reconcile the *selected* server against the
current origin. If the selection is a `web-`-prefixed entry whose id differs from
`webOriginServer(_defaultWebSocketUri()).id`, repoint it at the current origin.

Constraints from the issue, and how each is met:

- **Token must survive** — else every affected user is silently un-paired. Carry
  the stale entry's token onto the new origin id synchronously (localStorage /
  in-memory cache reads are synchronous), so the same-frame connect uses it.
- **Old entry cleaned up, not accumulated** — drop the stale entry from the list
  rather than leaving one dead `web-` entry per origin the daemon was served from.
- **Manual servers untouched** — only `web-`-prefixed (origin-derived) ids are
  reconciled. A user-added server owns a stable, editable-address id and must
  never be rewritten, even when it points at the same daemon.

Mirror the legacy migration's durability discipline: copy the token now, but
retire the stale copy only **after** the reconciled config is durably saved — a
failed save leaves the old copy for the next launch to retry from, never
orphaning the credential.

### Why a pure function

`initState`'s web branch can't be exercised in a widget test (`kIsWeb` is false on
the VM). So the decision logic goes in `server_store.dart` as a pure function,
`reconcileWebOriginSelection(config, origin) -> (ServerConfig, String?)`, unit-tested
alongside the existing migration. `main.dart` only wires it: apply the returned
config to `_servers`/`_selectedServerId`, persist, and clear the returned stale
token id once the save lands. The `String?` second element is the stale token id
to retire (null when nothing was reconciled or no token was carried).

## Plan

1. `lib/services/server_store.dart` — add `reconcileWebOriginSelection`. No-op
   unless the selection is a `web-` entry present in the list and differing from
   `origin`. Carry the token, drop the stale entry, return the new config plus the
   stale token id (or null).
2. `lib/main.dart` — in `initState`, before the selection cascade and only when
   `!isMockMode && widget.client == null && kIsWeb`, call it with the current
   `_servers`/`_selectedServerId` and `webOriginServer(_defaultWebSocketUri())`.
   If the selection changed, update state, persist, and clear the stale token
   after the save succeeds.
3. `test/server_store_test.dart` — cover: repoint + token carry + stale-id
   report; no-op when already the origin; manual server left alone; other servers
   preserved while the stale one is dropped; migrate-without-token reports no
   retirement; no-op when nothing is selected.
4. Validate: `dart format`, `flutter analyze`, `flutter test`. Then
   `/review-fix-loop max`, then PR (with confirmation).
