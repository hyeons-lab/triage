# 000111 — feat/rail-activity-grouping

**Agent:** Claude (claude-opus-5[1m]) @ triage branch feat/rail-activity-grouping

## Intent

On first load the session rail is ordered arbitrarily — `list_sessions` returns
`HashMap` iteration order, which Rust reseeds per process, so the order
reshuffles on every daemon restart. Group same-repo sessions adjacent, order
groups and rows by real activity (most recent first), and give the ordering a
deterministic floor so it never reshuffles for no reason.

Phase 1 (this branch) covers grouping + activity ordering. Pinning and a
reset-to-activity affordance are deferred to Phase 2 — see
`devlog/plans/000111-01-rail-activity-grouping.md`.

## Progress

- [x] Daemon: `last_activity_at` stamped on every output ingest
- [x] Daemon: carry activity across a handover
- [x] Daemon: persist/restore `last_activity_at`
- [x] Daemon: deterministic `list_sessions` order
- [x] Rust CI gate green (fmt, clippy, rustdoc, `cargo test --workspace`)
- [x] Protocol: context + activity on the session-list response (fixes first paint)
- [x] Client: group by `repoRoot`, "Other" bucket, activity ordering
- [x] Flutter tests (218 pass) + `flutter analyze` clean
- [x] Client: group headers in the rail
- [x] Group-aware drag + pins + reset
- [ ] `/review-fix-loop high`
- [x] Per-item unpin — the pin indicator is itself the release control
- [ ] Run the app against a live daemon (the binary transport is unproven end to end)

## What Changed

- 2026-07-28T20:12-0700 `crates/triaged/src/session.rs` — `SessionActor` and
  `ActorState` share a `last_activity_ms: Arc<AtomicU64>`, stamped on every
  output ingest in `handle_output`. Stamped before the cwd/event branches so it
  does not depend on the session having an event id or on the summarizer being
  wired up. Read lock-free by the manager rather than over the actor channel: the
  rail orders every session by activity, so an actor round-trip per session would
  land on the connect path, and the atomic stays readable while the actor is busy
  serving the long output burst that makes a round-trip slowest.
- 2026-07-28T20:12-0700 `crates/triaged/src/session.rs` — `now_unix_millis()`
  helper beside `unix_timestamp_secs()`. Infallible by design because it runs on
  the actor's hot path; a pre-1970 clock yields 0, which the rail already treats
  as "activity unknown".
- 2026-07-28T20:12-0700 `crates/triaged/src/session.rs` + `handover.rs` —
  `HandoverSession.last_activity_ms` (serde default) carries recency across a
  daemon swap. Populated from the actor at extract; on adoption a 0 (pre-field
  peer) falls back to "now" rather than epoch, so an adopted session sorts recent
  instead of being buried at the bottom of the rail.
- 2026-07-28T20:12-0700 `crates/triaged/src/session.rs` —
  `PersistedSession.last_activity_ms` (serde default). `ManagedSession::persisted`
  reads through to the live actor, so every existing manifest write carries the
  current stamp and the periodic flush is a plain re-persist, not a second write
  path. `restore_session` seeds the actor from the manifest value.
- 2026-07-28T20:12-0700 `crates/triaged/src/session.rs` +
  `crates/triaged/src/main.rs` — `run_activity_persistence_loop` /
  `start_activity_persistence`, a 60s flush that re-persists when a live
  session's stamp has advanced. Needed because the manifest is otherwise only
  rewritten on structural events (start, exit, `cd`): a session that only
  produces output — a build, a running agent — would persist no activity at all,
  and that is exactly the session the rail most needs to order correctly. Skips
  the write entirely when nothing advanced, so an idle daemon does no disk I/O.
- 2026-07-28T20:12-0700 `crates/triaged/src/session.rs` — `list_sessions` sorts by
  `session_sort_key` instead of returning `HashMap` key order. The key splits on
  the parsed `session-N` sequence so `session-10` sorts after `session-2`, with
  custom ids ordered lexicographically after generated ones.
- 2026-07-28T20:12-0700 `crates/triaged/src/session.rs` — five tests: numeric and
  custom-id ordering, `list_sessions` stability across repeated calls, a restored
  session keeping its persisted stamp, and a live session persisting a real one.

- 2026-07-28T21:22-0700 `crates/triage-core/src/session.rs` — new
  `SessionContextRow { session_id, context, last_activity_ms }` replaces the
  `Vec<(SessionId, Option<SessionContext>)>` return of
  `SessionApi::list_session_contexts`. Carrying context and activity together is
  what lets a client build its whole list from one response; fetching them
  separately is what made the rail rearrange after first paint. Also drops two
  `#[allow(clippy::type_complexity)]` the tuple needed.
- 2026-07-28T21:22-0700 `crates/triaged/src/session.rs` — `list_session_contexts`
  fills in activity (live sessions from the actor, historical from the manifest)
  and sorts by `session_sort_key`, the same `HashMap`-iteration fix as
  `list_sessions`. A client building its list from this response now inherits a
  deterministic order even when every stamp is unknown.
- 2026-07-28T21:22-0700 `crates/triage-core/schema/triage.fbs` +
  `crates/triage-transport-ws/` — `last_activity_ms` on `SessionContextEntry`,
  appended last to stay wire-compatible, with `#[serde(default)]` on the JSON
  form so an older peer decodes as 0 ("unknown").
- 2026-07-28T21:22-0700 `flutter/triage_client/lib/session_grouping.dart` (new) —
  `groupSessionsByRepo` / `flattenGroups`, pure functions over
  `SessionOrderingInput`. Kept out of `main.dart` so the ordering rules are
  unit-testable against plain data: groups ordered by their *most recent* member
  (so one active worktree surfaces its whole repository), rows by activity, and
  every tie broken on the session's creation sequence so the order is total.
- 2026-07-28T21:22-0700 `flutter/triage_client/lib/main.dart` —
  `_loadDaemonSessions` fetches contexts *before* building rows and applies each
  session's context inline, so grouping, ordering, and "repo · worktree" titles
  all land on the first frame. `_seedSessionContexts` is gone; only the snippet
  seed remains after the rail is built.
- 2026-07-28T21:22-0700 `flutter/triage_client/test/session_grouping_test.dart`
  (new) — 12 tests: adjacency, group ordering by max member, within-group
  ordering, the "Other" bucket, trailing-slash normalization, numeric vs custom
  id tie-breaks, independence from input order, and unknown-activity handling.

- 2026-07-28T23:32-0700 `flutter/triage_client/lib/session_rail_layout.dart` (new)
  — flat rail layout plus the drag→pin mapping. One `ReorderableListView` with
  headers interleaved, not nested lists: nesting reads better but puts two
  reorderables in one gesture arena, where an inner row's drag gets captured by
  the outer list and a touch long-press on a header is ambiguous between levels.
  One list means one gesture space, at the cost of index arithmetic — which is
  why the arithmetic lives in pure functions instead of the widget.
- 2026-07-28T23:32-0700 `flutter/triage_client/lib/session_grouping.dart` —
  `SessionPins` (top-block) plus pin-aware ordering. A group's activity is
  computed from its sessions regardless of pinning, so unpinning restores its
  true position rather than stranding it. Pins naming an absent group or session
  are skipped, not dropped, so a repository with no live sessions keeps its slot
  for when one starts again.
- 2026-07-28T23:32-0700 `flutter/triage_client/lib/main.dart` — pins state,
  per-server persistence, `_applyPins` (re-groups and keeps the selection on the
  same *session*, not the same index), `_reorderRail`, `_resetRailOrder`, group
  headers as drag handles, pin indicators on headers and rows, and the reset
  action in the SESSIONS row shown only while something is pinned.
- 2026-07-28T23:32-0700 `flutter/triage_client/test/session_rail_layout_test.dart`
  (new, 19 tests) + widget tests for pinning-by-drag and for reset.

- 2026-07-28T23:40-0700 `flutter/triage_client/lib/main.dart` — `_UnpinButton`
  makes the pin indicator its own release control, for both group headers and
  rows. Chosen over a context menu because on touch the rail's long-press is
  already the drag trigger, so a menu would compete with it; the small tap target
  is acceptable for a purely corrective action whose row-tap neighbour (select)
  is far more common.

## Issues

- 2026-07-29T11:05-0700 Review round 2 (`/review-fix-loop high`, 2 reviewers)
  found three more bugs in the pin model, all reproduced before fixing:
  - `pinPrefixTo` sized the pinned block `max(index + 1, alreadyPinned)`, one
    short whenever the dragged key was not already pinned. Dropping a third
    entry into a block of two pushed the bottom one out and **silently released
    it** — the exact side effect the function's own doc promised never happened.
  - A pin naming a group or session with no live session right now is invisible
    to `displayOrder`, so the next drag anywhere in the rail dropped it. A
    repository whose last session exited lost its slot the moment the user
    touched anything, against the stated "keeps its place for when one starts
    again".
  - `_loadDaemonSessions` clamped `_selectedIndex` whenever the session list
    shrank, overriding the session-anchored reselection computed just above it.
    The rail highlighted one session while the terminal attached another.
  None of the three had direct coverage: `pinPrefixTo` had no unit tests at all,
  only indirect ones through the layout. Added five.
- 2026-07-29T11:05-0700 `buildRailItems` compared each row's group against only
  the immediately preceding one, so an ungrouped row between two rows of one
  group would emit that header twice — duplicate `ValueKey` inside a
  `ReorderableListView`, which throws. Not reachable today because new sessions
  are always inserted at the head, but one insertion-point change away. Tracks a
  set of emitted keys now.

- 2026-07-28T23:55-0700 Review round 1 (`/review-fix-loop high`, 2 reviewers)
  found a real bug: **every downward drag was a no-op**. Pins are a leading
  block, so an entry can only hold a position if everything above it is pinned
  too — but the drag inserted only the moved key into the pinned list, which with
  nothing yet pinned clamped every target to 0 and sprang the row back to the
  top. Replaced `pinAt` with `pinPrefixTo`, which pins the whole prefix through
  the drop point (never releasing pins already held). Half the rail's primary
  gesture silently did nothing, and no test caught it because every test dragged
  *upward* — the one downward assertion the old suite had
  (`expect(order!.last, isNot('main'))`) was deleted when those tests were
  migrated to pins. Migrating a test is where coverage quietly goes missing.
- 2026-07-28T20:12-0700 `cargo check -p triaged` fails outright because the build
  script builds the Flutter client. `TRIAGE_SKIP_FLUTTER_BUILD=1` skips it and
  embeds the placeholder bundle — needed for any Rust-only check in this repo.
- 2026-07-28T20:12-0700 The script that added `last_activity_ms` to the test
  fixtures matched on `last_known_cwd:` and also hit the `ManagedSession::Live`
  *destructuring pattern* in the handover path, which is not an initializer.
  Caught by the compiler (E0026) and reverted by hand.
- 2026-07-28T20:12-0700 `cargo doc -D warnings` rejected the public
  `start_activity_persistence` doc linking to the private
  `run_activity_persistence_loop` (`rustdoc::private_intra_doc_links`) — the
  exact trap called out in the global instructions. Switched the intra-doc link
  to a plain code span. `cargo clippy` and `cargo test` both passed before this,
  so only the doc gate catches it.
- 2026-07-28T21:22-0700 Regenerating the checked-in Dart flatbuffers bindings
  (`flatc --dart`) produced a far larger diff than the one added field: the
  checked-in file was **stale**, missing `ListSessionContextsRequest` and
  `SessionContextsResult` entirely. Reverted the regeneration at the time on the
  grounds that "the client sends control requests as JSON, so that path is not
  used" — which was **wrong**. `_send` is negotiation-aware and does use
  FlatBuffers whenever the subprotocol is selected; the client simply never
  offered it. The breakage was latent, not absent. Split out and fixed
  separately in #129, which also made FlatBuffers the default.
- 2026-07-29T10:05-0700 Rebasing onto #129 left the schema's new
  `last_activity_ms` with no regenerated bindings — that work lived in the two
  commits the rebase dropped. CI's new drift gate would have caught it; running
  `scripts/generate-dart-flatbuffers.sh` locally caught it first. The
  regenerated field routes through the dart2js compat layer automatically
  (`fbjs.readUint64` / `fbjs.addUint64`), so a new `ulong` is web-safe by
  construction rather than by remembering.
- 2026-07-29T10:05-0700 The binary decoder for `SessionContextsResult` omitted
  `last_activity_ms`, since it was written in #129 before the field existed.
  Nothing would have failed: `listSessionContexts` defaults it to 0, so every
  session would report "unknown activity" and the rail would quietly fall back
  to id order — this branch's entire feature, silently inert, on the transport
  that is now the default. The same shape as the bug #129 was opened to fix,
  found the same way: by diffing the decoder against the JSON form field by
  field rather than trusting that a passing suite means parity.
- 2026-07-28T21:22-0700 Building the header-segmented rail broke two widget
  tests, both tracing to the removal of drag (one asserts drag persistence, the
  other uses a drag as setup for a cross-daemon isolation check). Not a hidden
  bug — but it is what made clear that headers cannot land before their drag
  replacement. Backed the rendering change out; see Decisions.
- 2026-07-28T21:22-0700 A script inserting `last_activity_ms` into the test
  fixtures matched on indentation and also hit the `ManagedSession::Live`
  destructuring pattern; caught by E0026. Indentation is a poor discriminator for
  "initializer vs pattern" — the compiler was the real check.
- 2026-07-28T23:32-0700 Wiring pins into the load path broke ten-plus widget
  tests: the selected session stopped blocking on its snapshot, so the rail
  finished loading when it should still have been pending. Two hypotheses were
  wrong before instrumentation found it — `_restorePins` awaited
  `SharedPreferences.getInstance()`, which never completes in tests that don't
  call `setMockInitialValues`, stalling the whole load behind it. Reasoning about
  the diff got nowhere; a `print` either side of each await found it immediately.
  **The constraint was already documented** in the code this replaced: *"read
  synchronously from the cache when sessions load so the load path never awaits
  prefs."* Restored that shape — pins are primed in the background when the
  server resolves, and the load path reads `_pins` synchronously. Worth
  remembering that a comment explaining why something is structured oddly is
  usually load-bearing.

## Decisions

- 2026-07-28T20:00-0700 Activity means *output*, not interaction — user's explicit
  call ("if something is being output, that's the most recent"). A session
  emitting build logs is intended to take the top slot, so no attempt is made to
  distinguish user-driven from machine-driven output.
- 2026-07-28T20:00-0700 Rejected log-file mtime as the activity source. It looked
  viable (newest 15 logs spread across days) but listing all 32 showed ~8 stamped
  identically at daemon start (Jul 23 07:28) — restore rewrites live sessions'
  logs, destroying their true recency and tie-breaking them arbitrarily. That
  would have reintroduced the exact randomness being fixed. A persisted
  `last_activity_at` is therefore mandatory rather than a nice-to-have.
- 2026-07-28T20:00-0700 Fold context + activity into the session-list response
  instead of leaving `_seedSessionContexts` as a second phase. Otherwise every
  load paints ungrouped in daemon order and then visibly regroups — trading
  "random at rest" for "jumps on every load". The daemon must send activity
  anyway, so this is nearly free.
- 2026-07-28T20:00-0700 Rail holds still during a session; re-sorts on load,
  reconnect, and reset. With output as the signal a build would drag its group
  top-ward continuously. Live activity stays visible in place via status color,
  snippet, and the `activityAt` relative-time label.
- 2026-07-28T20:00-0700 Pins (Phase 2) will be a top block, not absolute indices.
  Index-pinning has no well-defined behavior when groups appear and vanish.
- 2026-07-28T20:00-0700 Deferred pinning to Phase 2 rather than building it now.
  Root cause is one line of `HashMap` iteration; automatic grouping plus a sane
  order may make manual override unnecessary, and that is only knowable from use.
- 2026-07-28T20:00-0700 Leave the saved flat drag order key in place (unused by
  Phase 1) rather than deleting it, so Phase 2 can seed pins from it and the
  user's existing hand-built layout is not silently discarded on upgrade.

- 2026-07-28T21:22-0700 Deferred group headers and group-aware drag to Phase 2,
  after building them and backing them out. Headers require replacing the rail's
  `ReorderableListView` with a header-segmented list, which removes drag — and
  drag is a real, tested feature (`widget_test.dart` covers both its persistence
  and its per-daemon isolation). Landing headers without a drag replacement would
  have been a silent regression, and the replacement is the full pinning model,
  not a small addition. Phase 1 therefore ships the ordering with the rail's
  existing rendering: same-repo sessions come back adjacent because grouping
  decides the load order, just without a labelled header.
- 2026-07-28T21:22-0700 Retired the saved flat drag order as the *load* order
  rather than deleting the feature. Dragging still works and still persists to
  `sessionOrderPrefKeyFor`; what changed is that a reload now re-derives the
  order from grouping + activity instead of replaying the saved list. Phase 2
  turns that stored list into seed pins, so the hand-built layout is not lost.

- 2026-07-28T23:32-0700 Reversed the earlier deferral of headers and group-aware
  drag. They were deferred because landing headers meant removing drag; building
  the pinning model *is* the replacement, so both ship together and no capability
  is lost.

- 2026-07-29T11:05-0700 Retired the `session_order_v1*` preferences rather than
  seeding pins from them. Phase 1 kept the key on the promise that Phase 2 would
  turn a saved order into pins; shipping Phase 2 made clear why that is the
  wrong trade. The saved list is an order over *every* session, so honouring it
  means pinning every session — which freezes the rail against the activity
  ordering that is the whole point of the branch. Deleted once on load instead,
  so upgrading users land on activity order with nothing pinned and pin what
  they actually want. `migrateSessionOrder` moved only pin keys after this, so
  it is now `migrateRailPins`.

## Research & Discoveries

- 2026-07-28T20:00-0700 `git_repository_root` (`session.rs:4894-4904`) resolves via
  `rev-parse --git-common-dir`, so a linked worktree's `repository_root` is its
  *parent* repo. Grouping by `repoRoot` therefore folds `triage/worktrees/foo` in
  with `triage` automatically — no special-casing needed.
- 2026-07-28T20:00-0700 No wall-clock timestamp exists anywhere in the protocol
  (`crates/triage-core/schema/triage.fbs`) — only per-session `output_seq`
  counters, which are not comparable across sessions. Activity ordering needs new
  wire plumbing regardless of source.
- 2026-07-28T20:00-0700 A debounce loop already observes per-session output for
  the summarizer (`PendingDirty { last_output_seq, last_tick_at }`,
  `session.rs:2169`) — the natural stamp point, so no new output plumbing.
  `run_cwd_persistence_loop` (`session.rs:2185`) is the coalesced-manifest-write
  pattern to follow, but its 500ms window is far too narrow for output.
- 2026-07-28T20:00-0700 `snippetUpdatedAt` (`main.dart:2399`) is stamped
  client-side with `DateTime.now()` on arrival, so it is null at first load — it
  cannot serve as the activity source for the very moment that matters.
- 2026-07-28T20:00-0700 `triage.fbs` has copies in each worktree; schema edits
  must target `crates/triage-core/schema/triage.fbs` in this worktree and the
  checked-in Dart under `lib/generated/` must be regenerated.

## Commits

Rebased onto `main` after #129 merged, which dropped the two FlatBuffers commits
this branch carried (`9d37b89`, `6ef6c1b`) — that work landed in #129 instead.
Hashes below are post-rebase.

- 0e636b1 — feat(triaged): track per-session activity and order sessions deterministically
- d028d45 — feat(triage_client): group the session rail by repository, ordered by activity
- d8bc94f — feat(triage_client): pin rail groups and sessions by dragging, with a reset
- e4ba7a0 — feat(triage_client): release a single pin by tapping its indicator
- d593a08 — fix(triage_client): make downward rail drags actually move the item
- c329d75 — fix(triage_client): carry pins across a server-id change
- 8840974 — fix(triage_client): decode last_activity_ms over the binary transport
- HEAD — fix(triage_client): stop drags from silently releasing pins

## Next Steps

- Run `/review-fix-loop high` to convergence — round 2 applied its actionable
  findings; round 3 has not run, so the loop has not converged.
- Run the app against a live daemon: the binary transport is verified at the
  handshake level and under fakes, but no full request/response round-trip has
  been exercised against a real daemon.
- Deferred review findings, none blocking (round 2 re-confirmed each): fold the three trailing-slash/leaf
  helpers into one, merge the two hoist-pinned-to-front functions, hoist `earliestInput`
  out of the group-sort comparator, drop the unreachable row-index guard, share one
  `session-N` parser between `session_sort_key` and `next_session_sequence`, and
  add coverage for `run_activity_persistence_loop`.
