# 000089 — feat/multi-server-switcher

**Agent:** Claude (claude-opus-4-8) @ triage branch feat/multi-server-switcher

## Intent

Let the client know about more than one daemon (a laptop at home, one at work),
switch between them, and remember what belongs to each — so switching is not
lossy.

## Research & Discoveries

- 2026-07-14T10:10-0700 The single-daemon assumption was baked into three
  independent places, not one: `daemon_address_v1` (shared_preferences),
  `triage_bearer_token` (Keychain), and `session_order_v1` (shared_preferences).
  Only the first is obviously about "which daemon"; the other two are what make
  switching *lossy*, and they are the reason this is more than a UI change.

- 2026-07-14T10:12-0700 The real pain was never that you *can't* switch — you
  could always retype the address. It is that retyping silently invalidated the
  stored token, because the token belongs to the daemon that issued it, not to
  the device. So a round trip between two daemons cost two re-pairs.

- 2026-07-14T10:15-0700 Session ids are daemon-local. A single global
  `session_order_v1` list therefore means switching to daemon B overwrites
  daemon A's rail order with ids A has never seen. Keyed the order by server id
  for the same reason as the token.

## Decisions

- 2026-07-14T10:14-0700 **Server ids are random, not derived from the address** —
  because a token is stored under the id. Deriving the id from the address would
  orphan a good token whenever the address is edited (a new DHCP lease, LAN →
  Tailscale) and force a re-pair for no reason. With a stable id the token
  follows the server across an address edit. Pointing an entry at a genuinely
  *different* daemon instead yields a rejected token, which already routes to
  pairing on its own — so a stable id costs nothing when it guesses wrong and
  saves a re-pair when it guesses right.

- 2026-07-14T10:16-0700 **The web client synthesizes a server from the page
  origin** (`webOriginServer`). The web app is served *by* a daemon, so its
  daemon is implied rather than configured. Synthesizing an entry keeps the
  invariant "a live connection always has an active server", so token keying,
  rail order, and the switcher need no web special case. Its id *is* derived from
  the origin — unlike a user-added server, the origin is the identity and is not
  editable, and deriving it stops two daemons that both serve a web client from
  colliding on one token.

- 2026-07-14T10:18-0700 **Switching routes through `_connectWebSocket`** rather
  than growing a parallel path. A switch is exactly the teardown-and-reconnect
  that the old address change already did, and `_connectWebSocket` already has
  the generation guard and the `_reconnectRequested` replay flag from the
  reconnect-wedge fix (#101) — so a switch requested mid-connect is handled by
  machinery that already exists and is already tested.

## What Changed

- 2026-07-14T10:20-0700 `lib/models/daemon_server.dart` — new. `DaemonServer
  {id, label, address}`, JSON codec, `decodeList` that drops corrupt records
  rather than bricking startup, and `defaultLabelFor` to name an unnamed server
  after its host (keeping a bracketed IPv6 literal intact).

- 2026-07-14T10:22-0700 `lib/services/storage.dart`, `storage_native.dart`,
  `storage_web.dart` — the unkeyed token API becomes
  `persistTokenFor`/`retrieveTokenFor`/`clearTokenFor`, keyed by server id, plus
  `retrieveLegacyToken`/`clearLegacyToken` for the migration. Native hydrates all
  per-server tokens in one `readAll` (it cannot know the server list yet at
  hydration time). The client id stays a single global value — it identifies the
  *device*, which is the same device on every daemon.

- 2026-07-14T10:24-0700 `lib/services/server_store.dart` — new. Loads/saves the
  server list and the selection, and owns the one-shot migration from
  `daemon_address_v1` + the unkeyed token + the unkeyed rail order.

- 2026-07-14T10:28-0700 `lib/main.dart` — `_daemonUri`/`_daemonAddressRaw`
  replaced by `_servers` + `_selectedServerId`, with the active server, its URI,
  and its storage key derived from those. Added `_addServer`, `_selectServer`,
  `_updateServer`, `_removeServer`, `_teardownConnection`. Every token read/write
  now goes through the active server's id. The rail's status pill names the
  daemon and opens the manager; `ConnectionSettingsDialog` became
  `ServerManagerDialog` (list + add/edit/forget).

- 2026-07-15T06:30-0700 **Docs pass ahead of a crates.io publish.** The READMEs
  had drifted well past the switcher: `crates/triage-mcp/README.md` listed four
  tools (`create_session`, `write_session_input`, …) that do not exist — the
  server is read-only with `list_sessions`/`snapshot_session`/`styled_rows` — so
  rewrote it around the real surface and a working `claude mcp add` snippet.
  `crates/triage/README.md` claimed the TUI can "multiplex multiple panels and
  monitors"; it renders a sidebar plus one attached session, so that claim is
  gone and the real keymap + update banner are documented instead. Root
  `README.md` said "Early development. Not yet usable." — replaced with an honest
  working-today / not-there-yet split and a client table. Added an `[update]`
  config section to `crates/triaged/README.md` (it was undocumented). Extended
  `flutter/triage_client/README.md` with the multi-daemon section. Ticked the two
  design-doc roadmap items that have since shipped (MCP Claude-Code snippet;
  mobile touch UX + multi-daemon switching under Phase 7).

- 2026-07-15T06:30-0700 `VERSION` `0.1.6` → `0.2.0` via
  `scripts/bump-version.sh 0.2.0` (propagates to `Cargo.toml`, `Cargo.lock`, and
  `pubspec.yaml` → `0.2.0+1`). Next *minor*, since the switcher is a
  user-visible feature. `scripts/bump-version.sh --check` reports OK;
  `RUSTDOCFLAGS=-D warnings cargo doc --workspace` builds clean at 0.2.0.

- 2026-07-15T06:30-0700 Built `Triage.app` (`flutter build macos --release`) and
  replaced the running copy in `/Applications` (quit PID, swap bundle, relaunch)
  — verified running on the switcher build.

## Issues

- 2026-07-14T10:35-0700 **The migration could destroy a live pairing token.**
  `_migrateLegacyServer` called `clearLegacyToken()` unconditionally, after
  copying the token only `if` one was found. But `loadCredentials` *swallows* a
  failed Keychain read (locked before first unlock, plugin unavailable) and
  leaves the cache empty — which is indistinguishable, at that call site, from
  "never paired". So an upgrade launched while the Keychain was briefly
  unreadable would skip the copy and then delete the real credential anyway,
  permanently un-pairing the user. Fixed by deleting the legacy token only once
  it is safely copied: leaving it behind costs a re-pair at worst, deleting it
  guarantees one. Caught by the review loop, not by the original tests.

- 2026-07-14T14:10-0700 **The review loop found a whole class of bugs I had
  missed, and they all had one root cause: session ids and titles are
  daemon-local, but every per-connection cache was keyed by them globally.** Two
  daemons routinely both have a session called `main`. So on a switch:
  `_pendingEvents` would replay daemon A's bytes into daemon B's identically-named
  session; the cached `TerminalPane` for `triage / main` would be reattached,
  showing A's scrollback under B's session; a rail drag would file A's session ids
  under B's order key; and — worst — A's tiles stayed in the rail marked
  `attached` and wired to `_client`, which had already been repointed at B, so a
  keystroke or a resize in that window went *to B under A's session id*, landing
  on a real, unrelated session.

  Fixed at the root rather than per-symptom: a switch now tears the old socket
  down *first* (so it cannot keep delivering events into the buffers we are about
  to clear), then `_purgeDaemonLocalState()` drops everything keyed by a
  daemon-local identifier — including the tiles themselves. In-flight session
  loads are pinned to the connect generation, so one started against A cannot
  finish against B.

- 2026-07-14T14:12-0700 **The mid-connect switch could un-pair the daemon you
  switched *to*.** `_connectWebSocket` read the token before its
  `await _client.disconnect()` and the address after it, so the two could come
  from different servers; and `_showPairingChallenge` cleared
  `clearTokenFor(_activeServerId)` — "whatever is active now" — rather than the
  server the attempt belonged to. Switching while a connect was in flight to a
  daemon that rejected its token would therefore delete the *incoming* daemon's
  perfectly good credential. Both now pin a `serverId` captured at the commit
  point.

- 2026-07-14T14:14-0700 **Existing web users would all have been silently
  un-paired.** The migration keys off `daemon_address_v1`, but the web client is
  served *by* its daemon and never stored an address — so the migration never saw
  them, and their unkeyed token was orphaned. The synthesized origin server now
  calls `adoptLegacyToken` explicitly.

## Lessons Learned

- 2026-07-14T10:36-0700 A `catch (_) {}` that falls back to an empty cache makes
  "read failed" and "nothing stored" the same value to every caller downstream.
  That is fine for a read, and dangerous for anything that then *deletes* on the
  strength of it. Destructive steps need a positive signal, not the absence of a
  negative one. This bit twice: once on the legacy token (a failed Keychain read
  read as "never paired"), and once on the legacy address (`saveServers`
  swallowing its own failure, then the address being retired anyway — losing both
  copies). `saveServers` now returns whether the write landed.

- 2026-07-14T14:16-0700 When an identifier is only unique within a scope, every
  cache keyed by it inherits that scope — and *nothing in the type system says
  so*. `Map<String, ...>` keyed by a session id looks global and behaves global.
  The single-daemon assumption wasn't in one place to be deleted; it was in the
  keys, spread across five caches, a pane registry, and the rail itself. Adding a
  second daemon is what turned all of them into bugs at once.

- 2026-07-14T14:18-0700 A regression test that passes against the unfixed code is
  worse than no test. Three of mine did, for three different reasons: one only
  reverted half the fix; one raced (the switch hadn't landed before the assertion,
  so the window under test never opened); and one was made *impossible* by a
  better fix (once the stale tiles are retired, there is nothing left to drag).
  Every test here was checked by reverting the code it guards and confirming it
  fails first.

## Testing

- `flutter test` — 128 passing; `flutter analyze` clean.
- Three rounds of `/review-fix-loop max`. Each round found real defects in the
  previous round's fix, so the loop earned its keep.
- Every new regression test was checked by reverting the code it guards and
  confirming it fails first: the token carry-over, the legacy-key consumption,
  the "don't delete a token you failed to read" guard, the dangling-selection
  fallback, the legacy rail-order move, the per-server token keying, the token
  clear on forget, the rail naming the daemon, the mid-connect switch not
  un-pairing the incoming daemon, the phantom-daemon reconnect, and the retiring
  of the outgoing daemon's tiles.
- 2026-07-14T14:28-0700 Installed on the Pixel. It reconnected to the existing
  daemon **without a pairing prompt** — the migration found the pre-existing
  unkeyed token and carried it onto the migrated server entry, which is the whole
  point of the migration, verified against a real Keychain rather than a mock.

## Next Steps

- Switch between two live daemons on-device (only one is currently running).

## Commits

- HEAD — feat(triage_client): remember and switch between multiple daemons
