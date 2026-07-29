# 000110 — feat/rail-activity-grouping

**Agent:** Claude (claude-opus-5[1m]) @ triage branch feat/rail-activity-grouping

## Intent

On first load the session rail is ordered arbitrarily — `list_sessions` returns
`HashMap` iteration order, which Rust reseeds per process, so the order
reshuffles on every daemon restart. Group same-repo sessions adjacent, order
groups and rows by real activity (most recent first), and give the ordering a
deterministic floor so it never reshuffles for no reason.

Phase 1 (this branch) covers grouping + activity ordering. Pinning and a
reset-to-activity affordance are deferred to Phase 2 — see
`devlog/plans/000110-01-rail-activity-grouping.md`.

## Progress

- [x] Daemon: `last_activity_at` stamped on every output ingest
- [x] Daemon: carry activity across a handover
- [x] Daemon: persist/restore `last_activity_at`
- [x] Daemon: deterministic `list_sessions` order
- [x] Rust CI gate green (fmt, clippy, rustdoc, `cargo test --workspace`)
- [ ] Protocol: context + activity on the session-list response (fixes first paint)
- [ ] Client: group by `repoRoot`, "Other" bucket, activity ordering
- [ ] Client: rail rendering — nested vs flat, decided by prototype
- [ ] Flutter tests + `flutter analyze` + `/review-fix-loop high`

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

## Issues

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
