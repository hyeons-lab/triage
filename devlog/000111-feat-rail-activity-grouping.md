# 000111 — feat/rail-activity-grouping

**Agent:** Claude (claude-opus-5[1m]) @ triage branch feat/rail-activity-grouping

## Intent

On first load the session rail is ordered arbitrarily — `list_sessions` returns
`HashMap` iteration order, which Rust reseeds per process, so the order
reshuffles on every daemon restart. Group same-repo sessions adjacent, order
groups and rows by real activity (most recent first), and give the ordering a
deterministic floor so it never reshuffles for no reason.

Pinning and a reset-to-activity affordance were planned as a separate Phase 2
(`devlog/plans/000111-01-rail-activity-grouping.md`) and then pulled into this
branch: landing group headers means the rail is no longer a flat list, which
breaks the existing flat-list drag, so the drag replacement is the other half of
the same change rather than a follow-up. See the Decisions entry for the
reversal, and `devlog/plans/000111-02-rail-pinning.md` for the pinning design.

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
- [x] `/review-fix-loop high` — five rounds
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

- 2026-07-29T14:20-0700 `flutter/triage_client/test/widget_test.dart` —
  `FakeTriageWebSocketClient` now answers `listSessionContexts` (empty by
  default, so the tests that predate grouping keep the ungrouped rail they
  assume), plus a `grouped rail` group of six widget tests: grouping and
  activity order at both levels, the repo-less "Other" group, a repository at
  `/`, header drags, group unpinning, and stored pins ordering the first paint.
  This was the gap round 4 called out, and it caught a real bug on its first run
  (below).
- 2026-07-29T14:20-0700 `flutter/triage_client/lib/main.dart` — carry
  `repoRoot`/`worktreeRoot` across the open-session swap; re-group when
  `_restorePins` lands after a load; stamp and re-group a newly created session;
  `_groupLabelFor` falls back to the key rather than "Other"; `_rowKeyFor`
  shared by the three places that spell a row's identity; the rail's `Builder`
  and the unreachable row-index guard removed.
- 2026-07-29T14:20-0700 `flutter/triage_client/lib/session_rail_layout.dart` —
  `_reorderWithinGroup` deleted; the flat pinned list now goes through
  `pinPrefixTo` directly. A drag inside a single-row group pins nothing.
- 2026-07-29T14:20-0700 `flutter/triage_client/lib/session_grouping.dart` —
  group tie-break index precomputed instead of recomputed per comparison.
- 2026-07-29T14:20-0700 `crates/triaged/src/session.rs` —
  `seed_last_activity_ms` keeps `store`, now with a comment saying why
  `fetch_max` is wrong here. (An earlier entry in this section claimed the
  `fetch_max` change; it was applied, found to be a bug, and reverted — see
  Issues.)

- 2026-07-29T14:50-0700 `flutter/triage_client/lib/main.dart` — round 5:
  `_regroupRail()` re-derives grouping wherever a session's repository can
  change after the rail was built (the `session_context_updated` push, and the
  open-session swap when the snapshot reports a different repo); `_closeSession`
  drops the closed session's pin; the new-session stamp is derived from the
  rail's own stamps rather than the local wall clock; the `onReorder`
  coordinate-space contract is recorded at the call site.
- 2026-07-29T14:50-0700 `crates/triaged/src/session.rs` +
  `crates/triage-transport-ws/src/lib.rs` — round 5 test repairs: the restore
  test now asserts equality (see Issues), `start_activity_persistence_is_idempotent`
  counts the loop's `Weak` instead of re-reading the flag it sets, and a new
  `flatbuffers_session_contexts_carry_activity` covers the binary encoder.
- 2026-07-29T14:50-0700 `flutter/triage_client/test/widget_test.dart` — three
  more widget tests: opening a session keeps its repository, rank and selection;
  a `cd` across repositories moves the row's group; closing a pinned session
  drops its pin.
- 2026-07-30T10:59-0700 Round 7. `session_rail_layout.dart` — the no-op test
  moved from the flat index to the *resolved* group/session position.
  `main.dart` — re-groups defer while a rail drag is in flight and run at the
  drop; a drag is ignored entirely while grouping is degraded
  (`_railGroupingDegraded`); a drag that resolves to no change skips `_applyPins`
  altogether. `crates/triaged/src/session.rs` — the restore stamp is handed to
  `spawn_restored` instead of stored after it, so the reader thread cannot win a
  race against it; `seed_last_activity_ms` is gone.
- 2026-07-30T10:59-0700 Round 7 tests, all mutation-checked: the actor's
  per-output stamp (`session_activity_advances_when_output_arrives` — nothing
  covered the core mechanism), the manifest read-through compared against the
  actor rather than `> 0`, the demote carry (asserted against the manifest on
  disk, since the revived shell's prompt re-stamps activity), a pre-field
  manifest keeping the spawn-time default, `migrateRailPins` with only one key
  set, and four widget tests: a repository that moved between connect and open,
  a created session landing in its group, a drag under degraded grouping, and a
  re-group arriving mid-drag.
- 2026-07-29T18:16-0700 `flutter/triage_client/lib/session_rail_layout.dart` —
  `resolveRailReorder` returns unchanged when the drag ends where it started.
  `flutter/triage_client/lib/main.dart` — the web-origin adopt path re-reads pins
  under the id it just adopted. `crates/triaged/src/session.rs` — the
  activity-loop comment no longer claims a quiet daemon does *no* disk I/O; the
  first tick after startup always writes once.
- 2026-07-29T18:16-0700 Round 6: the rail passes its own `RailItem` list to the
  reorder callback instead of `_reorderRail` rebuilding an identical one — drag
  indices only mean anything against the list they were measured on.
  `_fetchSessionContexts` drops a connect-generation guard that earned nothing
  (its caller re-checks the same condition on the next line; the guard was
  needed by the `setState`-ing seeder it replaced). `_createSession` re-groups
  through `_regroupRail` like the other sites. `SessionGroup.isOther` removed —
  only its own tests used it. Two Rust tests that could not fail their own names
  fixed (`list_sessions_returns_ids_in_creation_order` no longer derives its
  expectation from the function under test), and the handover fixture now
  asserts activity survives serialize→adopt.

## Issues

- 2026-07-30T10:59-0700 Round 7: the round-6 fix was incomplete, and both
  reviewers found it independently. Guarding on `landing == oldIndex` only
  catches a *flat-index* no-op, but the clamping that keeps a drag from feeling
  dead maps plenty of real drags back onto themselves — a header dragged over its
  own rows, a header dragged up but not past the header above, a group's first
  row dragged onto its own header. Each still pinned, and for headers that means
  pinning every group above too. The test written in round 6 only ever drove
  `oldIndex + 1`. The check now compares the *resolved* group or within-group
  position, which subsumes both the flat case and the single-row case. Known
  cost, documented at the function: the top group can no longer be pinned by
  dragging it onto itself — drag the group below it up past it, which pins both.
- 2026-07-30T10:59-0700 A re-group during a drag could corrupt it.
  `SliverReorderableList` re-syncs a live drag only when the item *count*
  changes, so a session moving between repositories — same row count, same group
  count — left the drag holding an index into a list that had been reordered
  underneath it, and the drop pinned whichever row inherited the slot. Re-groups
  now defer to the drop.
- 2026-07-30T10:59-0700 The adversarial test audit was worth more than any
  review lens this branch has had. It mutated the production code each test
  names and reported every mutation that survived: deleting the actor's
  per-output activity stamp — the mechanism the whole feature rests on — left all
  272 tests green, because every other test is satisfied by the spawn-time seed.
  So did deleting the demote carry, the create-session stamp, the create-session
  re-group, and the attach re-group. Six of those are now covered and each was
  re-verified by re-applying the mutation.

- 2026-07-29T18:16-0700 Round 6 found the last real bug, and a test was actively
  covering for it. `ReorderableListView` reports a row dragged down past its
  neighbour's midpoint and released back on its own slot as
  `newIndex == oldIndex + 1`, which converts to `target == oldIndex` — a null
  gesture. `resolveRailReorder` pinned the whole prefix through the row anyway,
  putting pin badges on rows the user never moved and offering a reset for a
  layout they never made. The existing test drove exactly that index pair, with
  the comment "no visible move", but only asserted that an *unrelated* pin
  survived — so it green-lit the behaviour it was closest to catching. Fixed with
  an explicit no-move return; the old test now drives a real downward move, and a
  new one covers the null gesture for both rows and headers.

- 2026-07-29T14:50-0700 Round 5 caught a bug I had just introduced. Round 4 left
  a nitpick suggesting `fetch_max` in `seed_last_activity_ms`; I applied it, and
  it is wrong — the actor seeds that field with *spawn time*, so a max against a
  restored (older) stamp is a no-op and every restored session comes back as
  "just now", the exact collapse the seed exists to prevent. The test that
  should have caught it asserted `restored >= persisted`, which an unseeded
  actor satisfies trivially, and its own comment admitted as much. Reverted to
  `store`, documented why, and made the test assert equality — verified by
  re-applying `fetch_max` and watching it fail. A nitpick is still a change to
  the code, and a test that cannot fail is not protection.
- 2026-07-29T14:50-0700 Running `dart format lib test` reformatted two things it
  had no business touching: four files unrelated to this branch, and
  `lib/generated/`, which CI's drift gate compares byte-for-byte against fresh
  `flatc` output — a 2,100-line diff that would have failed the gate. Reverted
  both. Format the files the change actually touches.
- 2026-07-29T14:50-0700 Undoing a temporary debug patch with
  `git checkout HEAD -- lib/main.dart` discarded every uncommitted edit in that
  file, not just the patch — about an hour of round-4 and round-5 fixes.
  Reconstructed them, then verified each was back before moving on. For a
  scratch edit to a file with unsaved work, copy the file aside and restore from
  the copy.

- 2026-07-29T14:20-0700 The new grouped-rail widget tests failed on their first
  run, and the failure was a real bug rather than a bad test: after any
  re-group, the *selected* session had moved out of its repository into "Other".
  `_loadDaemonSessionInto` builds a replacement `SessionVm` from the attach
  snapshot, and a snapshot without `repository_root` nulls the field — the exact
  shape of the `lastActivityMs` bug round 4 fixed, one field over. Carried both
  grouping fields forward, filled in only when the snapshot says nothing so a
  genuine change still wins. Worth stating plainly: four review rounds over pure
  functions did not find this, and the first widget test through the real path
  did.
- 2026-07-29T14:20-0700 The first attempt at the absent-session-pin fix wove the
  reordered group entries back into the slots they held. It worked, but the test
  written for it failed — and the failure was right: the weave was a *second*
  implementation of "a pin naming something absent keeps the index it held",
  which `pinPrefixTo` already had, and the two disagreed on which entry got
  displaced. Passing the whole flat list to `pinPrefixTo` gives the same answer
  with one rule instead of two, so `_reorderWithinGroup` is gone. The original
  bug stands: the old split-and-rejoin collected untouched pins in *front*,
  which promoted a pinned-but-not-running session to the top of its own group
  the moment it came back.

- 2026-07-29T12:15-0700 Round 4 found two more bugs, both regressions of the
  branch's own promises rather than edge cases:
  - `_loadDaemonSessionInto` swaps a freshly built `SessionVm` into the list,
    and a fresh one has `lastActivityMs` 0. So **opening a session erased its
    activity stamp** — and since a group is as recent as its most recent member,
    the next re-group sank that session's whole repository to the bottom as
    "unknown". Sorting by activity demoted precisely the sessions being used.
  - The `migrateRailPins` call lost the `_restorePins()` that used to follow it,
    so after a server-id change the session ran with empty pins and the first
    drag persisted a one-entry list over everything just migrated. This is the
    exact failure `c329d75` was written to fix, reintroduced by the rename; the
    comment above it still claimed the layout "is re-restored so this session
    keeps it".
  Neither was caught by a test. The widget suite's fake client never overrides
  `listSessionContexts`, so every widget test renders the *ungrouped* fallback —
  the grouped rail has no widget coverage at all, only pure-function coverage.
  That gap is what let both through and is the most valuable thing round 4
  surfaced.
- 2026-07-29T12:15-0700 Extracting `activity_advanced` in round 3 moved the loop
  body but not the comment boundary, leaving the loop's doc block attached to
  the predicate and `run_activity_persistence_loop` — the function
  `start_activity_persistence` points readers at — with no doc at all. Same
  class of slip in `_hoistPinned`, which ended up with both merged doc blocks
  stacked and a `[ordered]` reference to a parameter that no longer exists.

- 2026-07-29T11:40-0700 Round 3 cleared the duplication the earlier rounds had
  only recorded. The three trailing-slash/leaf helpers had already drifted —
  only `_normalizeRepoRoot` kept `/` intact, so a repo root of `/` grouped and
  labelled inconsistently. Now one `trimTrailingSlash` / `leafOf` pair in
  `session_grouping.dart`. `_applyPinnedOrder` and `_applyPinnedGroupOrder`
  became one generic `_hoistPinned`, which matters because the "a pin naming an
  absent entry is skipped, not dropped" rule had to hold in both and was stated
  twice. `session_sort_key` and `next_session_sequence` now share
  `generated_session_sequence`.
- 2026-07-29T11:40-0700 `run_activity_persistence_loop` had no test at all — the
  only thing making activity survive an ungraceful kill. Its advance predicate
  was inlined in the loop body and so untestable without a 60s sleep; extracted
  as `activity_advanced` and covered four ways, including that a *disappearing*
  session deliberately does not trigger a write (shutdown and demotion persist
  the manifest themselves, so firing here would double every shutdown's I/O).

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
- 83a668c — fix(triage_client): stop drags from silently releasing pins
- 17bdbc8 — refactor: collapse the rail's duplicated helpers and cover the activity loop
- e752c04 — fix(triage_client): keep a session's activity stamp when it is opened
- c3b9cde — fix(triage_client): keep a session in its repository and its rank
- 238c5b0 — fix(triage_client): stop a drag that goes nowhere from pinning
- HEAD — fix(triage_client): pin only when a drag actually reorders something

## Next Steps

- Run the app against a live daemon: the binary transport is verified at the
  handshake level and under fakes, but no full request/response round-trip has
  been exercised against a real daemon.
- Known untested branches, all named by round 7's test audit and left as
  deliberate gaps rather than oversights:
  - the handover zero-fallback (`session.rs:1399`, adopting from a daemon that
    predates `last_activity_ms`) — covering it needs a second full handover
    fixture with real PTY fds for one assertion;
  - `run_activity_persistence_loop` itself (only its `activity_advanced` helper
    and the spawn guard are covered) — it is a 60s loop;
  - the load path's session-anchored selection re-anchor, and `_restorePins`
    landing *after* a load (the widget fixture always completes the prefs read
    first), both of which need a driveable reconnect in the fake;
  - `_applyPins`'s local-session preservation, `_persistPins`'s cross-server
    guard, and the forget-a-daemon pin cleanup — reachable only through
    multi-daemon widget setups.
- The rail re-sorts only on structural events — load, reconnect, drag, session
  created or closed, repository change. `lastActivityMs` is never updated from
  live output, so "ordered by activity" is a snapshot rather than a live ranking.
  Deliberate (a rail re-sorting under the cursor mid-stream would be hostile),
  but worth revisiting with an explicit debounce if it reads as stale.
- `ReorderableListView.onReorder` is deprecated in favour of `onReorderItem`,
  which reports `newIndex` already adjusted for the removed item. Migrating means
  deleting the pre-removal conversion in `resolveRailReorder`, not just renaming
  the callback — noted at both sites.
