# Plan 000089-01 — Multi-daemon server switcher

## Thinking

Today the client knows exactly one daemon. That fact is baked into three separate
places, each of which assumes singularity:

- `daemon_address_v1` in shared_preferences — one raw address string.
- `triage_bearer_token` in secure storage — one unkeyed token.
- `session_order_v1` in shared_preferences — one flat list of session ids.

The user runs more than one daemon (a laptop at home, one at work). Today
switching between them means retyping the address in the settings dialog, which
also silently invalidates the stored token — because the token belongs to the
daemon that issued it, not to the device. So the switch costs a re-pair every
time, in both directions. That is the actual pain: not that you *can't* switch,
but that switching is lossy.

So the feature is really "remember N daemons, and remember what belongs to
each" — the switcher UI is the small part.

### What is per-server and what is per-device

This is the crux, and getting it backwards causes the re-pair loop:

- **Per-device:** the client id. It identifies *this phone*, and it is the same
  phone no matter which daemon it talks to. Stays a single global value.
- **Per-server:** the pairing token. Each daemon runs its own pairing challenge
  and issues its own bearer token. Two daemons never honor each other's tokens.
  Keyed by server id.
- **Per-server:** the session rail order. Session ids are daemon-local, so a
  single global order list means switching to server B overwrites server A's
  order with ids A has never heard of. Keyed by server id.

### Server identity

A server's id is random and stable, *not* derived from its address. If it were
derived, editing the address (the host moved to a new IP, or you switched from
LAN to Tailscale) would orphan a perfectly good token and force a re-pair for no
reason. With a stable id the token follows the server across an address edit.

The opposite case — pointing a server entry at a genuinely *different* daemon —
means the carried-over token is rejected, which surfaces as `authenticated:
false` and routes to pairing. That is already the correct behavior and needs no
special handling. So a stable id is right in both directions: it costs nothing
when we're wrong and saves a re-pair when we're right.

### Migration

Anyone already using the app has a `daemon_address_v1` and an unkeyed token, and
must not be forced to re-pair by this change. On first launch after the upgrade,
if there is no server list but there is a legacy address, mint one server from
it and move the unkeyed token onto that server's id.

Both legacy keys are deleted once consumed, so migration is one-shot. This
matters: if the legacy address survived, a user who later deletes every server
would find the old one silently resurrected on next launch.

### Web

The web client is served *by* the daemon, so its daemon is implied by the page
origin rather than configured. Rather than thread a null server through every
call site, synthesize a server entry from the page origin at startup. Then the
invariant is uniform — whenever we are connected, there is an active server —
and the token keying, session order, and switcher all work without a special
case.

### Switching

A switch is not a new mechanism; it is exactly what `_applyDaemonAddress`
already does — bump the connect generation, tear down the old client, connect
with a different address and token. The existing generation guards and the
`_reconnectRequested` replay flag (from the reconnect-wedge fix) already make a
switch requested mid-connect safe. So switching should route through the same
path rather than growing a parallel one.

## Plan

1. **`models/daemon_server.dart`** (already drafted) — `DaemonServer {id, label,
   address}`, JSON codec, tolerant `decodeList`, `defaultLabelFor` to name an
   unnamed server after its host.

2. **`services/storage.dart` + native/web impls** (already drafted) — replace the
   unkeyed token API with `persistTokenFor`/`retrieveTokenFor`/`clearTokenFor`,
   keyed by server id. Add `retrieveLegacyToken`/`clearLegacyToken` for the
   migration. Native hydrates all per-server tokens in one `readAll`.

3. **`services/server_store.dart`** (new) — load/save the server list and the
   selected server id in shared_preferences (`daemon_servers_v1`,
   `daemon_selected_server_v1`). Owns the one-shot migration from
   `daemon_address_v1` + the unkeyed token, and deletes both once consumed.

4. **`main.dart` state** — replace `_daemonUri` / `_daemonAddressRaw` with
   `_servers` + `_selectedServerId`, and derive the active server, its URI, and
   its token key from those. Route every existing token read/write through the
   active server's id.

5. **Per-server session order** — key `session_order_v1` by server id so
   switching doesn't clobber the other server's rail order.

6. **Switcher UI** — the rail's connection-status row becomes a server chip
   (status dot + label + status text). Tapping it opens a menu: the servers, with
   the active one checked; "Add server…"; "Manage servers…". The gear keeps
   opening manage.

7. **Manage-servers dialog** — list with rename/edit-address/remove, plus add.
   Removing a server clears its token. Removing the active one falls back to the
   first remaining server, or the connection screen when none are left.

8. **Tests** — migration (legacy address + token → one server, keys consumed,
   no re-pair); token isolation (pairing server B leaves A's token intact);
   switching servers reconnects to the new address with the new token; a switch
   requested mid-connect is replayed, not dropped; removing a server clears its
   token; per-server session order survives a round trip. Every regression test
   verified by reverting its fix and confirming it fails.

9. `/review-fix-loop max` until clean, then commit + PR.
