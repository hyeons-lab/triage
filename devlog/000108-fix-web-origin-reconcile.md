# 000108 — fix/web-origin-reconcile

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch fix/web-origin-reconcile

## Intent

GitHub issue #109 (follow-up to #107). #107 made the web client dial the page
origin behind a reverse proxy, but it never runs for users who already loaded the
app: a `web-<host>-<port>` server entry persisted on the pre-#107 build stays
selected, so `_activeServer != null` short-circuits selection and the client
keeps dialing the dead `ws://127.0.0.1:7777/ws` forever. Reconcile a stale
web-origin selection with the current page origin so the same-origin default
reaches already-loaded users, not just clean installs.

## What Changed

- 2026-07-22T22:14-0700 `flutter/triage_client/lib/services/server_store.dart` —
  added `reconcileWebOriginSelection(config, origin)`, a pure function returning
  the reconciled `ServerConfig` plus the stale server id to retire once saved. It
  repoints a selected `web-`-prefixed entry that differs from the current origin
  onto the origin's id, carries the token across, and drops the stale entry.
  No-op for a manual (non-`web-`) selection, an already-current origin, or no
  selection.
- 2026-07-22T22:14-0700 `flutter/triage_client/lib/main.dart` — in `initState`,
  before the selection cascade and only on web (not mock, no injected client),
  call the reconciler with the current servers and
  `webOriginServer(_defaultWebSocketUri())`. When the selection changes, update
  `_servers`/`_selectedServerId`, persist, and clear the stale token only after
  the save lands (a failed save leaves it for the next launch to retry).
- 2026-07-22T22:14-0700 `flutter/triage_client/test/server_store_test.dart` —
  added a `reconcileWebOriginSelection` group covering token carry + stale-id
  report, the three no-op cases (already origin, manual server, nothing
  selected), other-servers-preserved, and migrate-without-token.
- 2026-07-22T22:37-0700 `server_store.dart` + `main.dart` + tests — review-loop
  follow-up. Added `migrateSessionOrder(fromId, toId)` (best-effort, mirrors
  `adoptLegacySessionOrder`) so a repointed origin carries its per-server rail
  order rather than resetting and orphaning the old key; the reconcile wiring
  now calls it after a durable save, then re-restores order for this session.
  `reconcileWebOriginSelection` now returns the *stale server id* (non-null on
  any reconcile, for cleaning both token and rail order) instead of only the
  token id, `.trim()`s the carried token to match `copyLegacyTokenTo`, and
  defensively drops any pre-existing `origin.id` entry. New tests: `.trim()`,
  the dangling-`web-`-selection no-op, the pre-existing-origin de-dup, and three
  `migrateSessionOrder` cases.

## Decisions

- 2026-07-22T22:14-0700 Pure function in `server_store.dart`, wired from
  `initState` — the web selection branch can't be reached in a widget test
  (`kIsWeb` is false on the VM), so the decision logic is unit-testable in
  isolation and `main.dart` only does the state/persist wiring.
- 2026-07-22T22:14-0700 Reconcile only the *selected* `web-` entry — the reported
  bug is the auto-selected origin entry going stale. Touching only `web-`-prefixed
  ids keeps a user's manually added server (stable, user-owned id) safe, and
  dropping the stale entry keeps origins from accumulating one dead entry each.
- 2026-07-22T22:14-0700 Token retired only after a durable save — mirrors the
  legacy migration: the copy rides onto the new id synchronously so the same-frame
  connect stays paired, but the old copy survives a failed save so nothing is
  orphaned.

## Verification

`flutter analyze` clean for the change (only the pre-existing `onReorder` /
`verificationUri!` warnings, both in `origin/main`); `flutter test` — 200 pass;
`dart format` clean. `/review-fix-loop max` ran two rounds (4 reviewers then 2):
no correctness/logic bugs survived; the actionable finding (rail order not
carried, flagged by 3 reviewers) drove the `migrateSessionOrder` addition above,
and the round-2 nitpick (de-dup branch untested) added the pre-existing-origin
test. Skipped: converting the record return to a named-field type (cosmetic).

## Review Comments

- 2026-07-23T00:10-0700 Copilot (PR #127) flagged a real edge case:
  `reconcileWebOriginSelection` unconditionally overwrote any token already stored
  under `origin.id` when carrying the stale entry's token across, so an origin
  that was already paired (e.g. from a prior sync) could be downgraded to the
  stale credential. Guarded the carry to skip when the origin already holds a
  non-empty token, and added a `never clobbers an existing origin credential`
  test. Also corrected the "stale token id" wording in the devlog and plan to
  "stale server id" (the second return value is the server id used to clean up
  both token and rail order), per three doc-nit comments.

## Commits

- HEAD — fix(triage_client): preserve an existing origin credential when reconciling
- ec2098d — fix(triage_client): reconcile a stale web-origin selection with the page origin
