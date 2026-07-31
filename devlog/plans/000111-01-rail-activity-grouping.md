# 000111-01, Rail activity grouping (Phase 1)

## Thinking

### The reported problem

"When the client first loads, the sessions are sorted by some random order (to
me)." The order is *literally* random, not merely unfamiliar:

```rust
// crates/triaged/src/session.rs:1553
fn list_sessions(&self) -> Result<Vec<SessionId>> {
    let sessions = self.sessions()?;      // Mutex<HashMap<SessionId, ManagedSession>>
    Ok(sessions.keys().cloned().collect())
}
```

`HashMap` iteration order is arbitrary and Rust seeds its hasher per process, so
the order reshuffles on every daemon restart. `list_session_contexts`
(`session.rs:2030`) iterates the same map with the same consequence.

### What already exists

- **Manual drag-reorder, persisted per server.** `_persistSessionOrder` /
  `_restoreSessionOrder` / `_applySavedOrder` (`main.dart:2691-2740`), applied at
  `main.dart:1903` before rows are built. It only covers sessions dragged at
  least once; anything new falls to the end in the daemon's random order. So the
  floor is random and manual dragging is the only thing holding it down.
- **Per-session git context.** `repoRoot` / `worktreeRoot` / `repoName` /
  `worktreeName` on `SessionVm`, bulk-seeded on connect by `_seedSessionContexts`
  (`main.dart:2033`) via a `listSessionContexts` control request.
- **A flat rail.** `ReorderableListView.builder` over `sessions`
  (`main.dart:3661-3708`), `buildDefaultDragHandles: false`, whole row is the
  drag handle (mouse: immediate; touch: long-press).

### Design decisions (from the design conversation)

1. **Auto-group by repo**, same-repo sessions adjacent.
2. **Manual drag within a group**, and **groups themselves reorderable**, so the
   relative order of repos can be changed too.
3. **Default order by last activity**, most recent first, surfaces what is hot.
4. **Repo-less sessions** collect into one "Other" group, which sorts by activity
   like any other group rather than being pinned last.
5. **Activity means output.** Explicit user call: "if something is being output,
   that's the most recent", a session emitting build logs *should* take the top
   slot. This closes the question of output-vs-interaction as the signal.

### Critical review findings that reshaped the plan

An initial plan was reviewed and several parts did not survive.

**Log mtime is a corrupted activity signal, rejected.** The first plan proposed
reading each session's log-file mtime as a free, durable activity proxy. Sampling
the newest 15 logs showed a healthy spread across days. Listing *all* 32 revealed
a tie cluster below that cut:

```
Jul 23 07:28  session-77, session-128, session-74, session-86,
              session-118, session-68, session-82     <- daemon start time
Jul 23 07:27  session-92
Jul 22 18:03  session-54                              <- real, untouched
```

The daemon started Jul 23 07:28. Restore rewrites the logs of live sessions,
stamping ~8 of 32 with an identical fabricated timestamp and destroying their
true recency. Those would sort as one indistinguishable block, tie-broken
arbitrarily, reintroducing exactly the randomness being fixed, and outranking
sessions with genuinely more recent activity. Re-corrupted on every restart.
Therefore: a real persisted `last_activity_at` is mandatory, not optional.

**First-paint reshuffle, must be fixed, not deferred.** The rail is built from
`listSessions()` (`main.dart:1903`); context arrives later via
`_seedSessionContexts` (`main.dart:2033`). Every load would paint ungrouped in
daemon order and then visibly regroup, trading "random at rest" for "jumps on
every load", the same class of complaint. Since the daemon must send activity
anyway, folding context into the same response is nearly free and fixes this.

**Pin-at-index is ill-defined, replaced by a top-block.** "Pinned holds its
slot, unpinned flows around it" has no well-defined answer when groups appear and
vanish (two groups pinned at 0 and 2 with five unpinned; a pinned repo's last
session closes; it reappears). Pins become a **top block** in pinned relative
order, unpinned below by activity. Deferred to Phase 2 regardless.

**Nested `ReorderableListView` was oversold.** It was recommended as "two clean
onReorder callbacks, no index math". Nested reorderables fight over the gesture
arena (an inner row's drag captured by the outer list), long-press on a header is
ambiguous between levels, inner lists need `shrinkWrap` +
`NeverScrollableScrollPhysics`, and reorder animation over variable-height group
children is janky. The flat-list-with-index-mapping alternative may well be more
robust, one gesture space, one list. Prototype before committing.

**Scope was too large for the complaint.** Root cause is one line of `HashMap`
iteration; the first plan answered it with a daemon change, a schema change plus
Dart codegen, a rail rewrite, a new persistence model, and three new UI
affordances. Pinning is the most expensive piece and the least certainly needed.
Staged so Phase 1 alone resolves the complaint.

**Confirmed sound:** grouping by `repoRoot`. `git_repository_root` resolves via
`rev-parse --git-common-dir` (`session.rs:4894-4904`), so linked worktrees map
back to their parent repo, `triage` and `triage/worktrees/foo` land in one
group, which is what is wanted.

### Held-still vs live re-sort

The rail re-sorts on **load, reconnect, and reset**, not live. With output as
the signal a build would drag its group top-ward continuously and the rail would
churn under the cursor (32 sessions here). Visibility is not lost: rows already
surface live activity in place via status color, snippet, and the relative-time
label (`activityAt`, `main.dart:3688`). Recorded as an assumption the user may
override.

### Implementation hook for `last_activity_at`

No new output plumbing is needed. A debounce loop already observes per-session
output for the summarizer (`PendingDirty { last_output_seq, last_tick_at }`,
`session.rs:2169`). Stamp activity in memory on that existing tick.

Persistence follows the established coalescing pattern of
`run_cwd_persistence_loop` (`session.rs:2185`, `CWD_PERSIST_SETTLE` 500ms) but
with a much wider window: output is far noisier than `cd`, ordering needs only
~30s accuracy, and the manifest write matters solely for surviving restart. A
narrow window would let a build loop hammer the manifest.

## Plan

### Phase 1, ordering (this plan)

1. **Daemon: track activity.**
   - Add `last_activity_at` to the in-memory session state; stamp on the existing
     summarizer output tick.
   - Add `last_activity_at` to `PersistedSession` (`session.rs:374`) as
     `#[serde(default)]` so pre-existing manifests deserialize.
   - Persist via a coalescing loop modeled on `run_cwd_persistence_loop`, with a
     wide settle window (~30s), plus a flush on shutdown and on handover so a
     daemon swap does not lose it.
   - Restore into memory on startup.

2. **Daemon: deterministic list order.** Replace the `HashMap`-iteration order in
   `list_sessions` (`session.rs:1553`) with a stable sort. This is the
   correctness floor and the fallback whenever activity is absent.

3. **Protocol: one response carrying context + activity.** Extend the session
   listing so first paint is already grouped and ordered, removing the
   two-phase reshuffle. Additive schema fields at the end of the table;
   regenerate the checked-in Dart (`lib/generated/`). Old daemon → field absent →
   client falls back to the deterministic daemon order with grouping still
   applied.

4. **Client: group and sort.**
   - Group sessions by `repoRoot`; repo-less into a single "Other" group.
   - Order groups by their most recent member activity; order rows within a group
     by activity. Stable tie-break (session id) so equal timestamps never
     reshuffle.
   - Compute at load/reconnect only; hold still during a session.

5. **Client: rail rendering.** Prototype nested vs flat-with-index-mapping and
   pick on the evidence. Headers move groups; rows move within a group.
   Preserve the existing mouse/touch drag-start distinction
   (`main.dart:3696-3707`).

6. **Tests + validation.** Unit coverage for the grouping/sort comparator
   (including the tie-break and the null-activity fallback), daemon coverage for
   activity persist/restore across a simulated restart, and widget coverage for
   the rail. Full local CI gate before push: `cargo fmt --all --check`,
   `cargo clippy --workspace --all-targets --all-features -- -D warnings`,
   `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps
   --locked`, `cargo test --workspace`, plus `flutter test` and `flutter analyze`
   for the client. Then `/review-fix-loop high` until clean.

### Phase 2, pinning (deferred, separate branch)

Top-block pins, reset-to-activity action, per-item unpin, pin indicators. Seeds
initial pins from the existing saved drag order (`sessionOrderPrefKeyFor`) so the
current layout survives the upgrade rather than being silently discarded. Only
worth building if Phase 1's automatic order proves insufficient in practice.

### Migration note

Phase 1 stops applying the saved flat drag order (`_applySavedOrder`,
`main.dart:2722`) because grouping supersedes it. The stored key is left in place
rather than deleted so Phase 2 can seed pins from it.
