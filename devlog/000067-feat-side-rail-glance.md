# 000067 — feat/side-rail-glance

**Agent:** Claude (claude-opus-4-8) @ triage branch feat/side-rail-glance

## Intent

Follow-up to feat/session-snippets (#74). Enrich the Flutter client's session
side rail into a glance surface: show branch/repo/worktree per session, a hover
popover with a more comprehensive (second-LLM-generated) summary, and
drag-and-drop reorder persisted client-local. The detail summary also seeds a
future fuzzy session search.

## Decisions

2026-06-15T22:05-0700 Detail summary via a *second* LLM generation (new
`snippet_detail` protocol field), not assembled-from-metadata — user wants a
real narrative usable for future search; accepted ~2x inference per debounce.

2026-06-15T22:05-0700 Reorder persisted client-local via `shared_preferences`
(per-device), not daemon-side — keeps it simple, no protocol/manifest change.

2026-06-15T22:05-0700 Single branch covers display + popover + reorder + detail.

2026-06-15T22:05-0700 Branch/repo/worktree display needs no protocol change —
`SessionSnapshot.context` already carries all three and every session is
snapshotted+attached on load, so the client already has the data.

## Progress

- [x] Phase 1 — daemon + protocol (detail summary)
- [x] Phase 2 — client display + hover popover
- [x] Phase 3 — drag-drop reorder (client-local)
- [ ] Phase 4 — verify, build, ship

## What Changed

2026-06-15T22:25-0700 crates/triage-core/schema/triage.fbs — append-only:
`SessionSnapshot.snippet_detail`, `SessionSnippetEntry.detail`,
`SessionSnippetUpdatedPayload.detail`. Rust bindings auto-regen via build.rs;
Dart bindings regenerated with `flatc --dart` and committed.

2026-06-15T22:25-0700 crates/triaged/src/summarizer.rs — `DETAIL_SYSTEM_PROMPT`,
`generate_detail()` (multi-line `DetailSink`, `sanitize_detail` collapses
whitespace + caps at 280 chars with ellipsis), `SnippetResult.detail`,
`SummarizerConfig.detail_max_tokens`. Worker runs both inferences back-to-back
per job on the one loaded engine; detail failure is non-fatal (emits one-liner
with `detail: None`).

2026-06-15T22:25-0700 crates/triaged/src/session.rs — `SessionSnippet.detail`;
`snippet_for` returns `(one-liner, detail)`; `overlay_snippet` fills
`snapshot.snippet_detail`; `apply_snippet` caches + broadcasts detail;
`list_session_snippets` returns the 3-tuple `(id, snippet, detail)`.

2026-06-15T22:25-0700 crates/triage-core/src/{session.rs,config.rs} —
`SessionSnapshot.snippet_detail` field; `SessionApi::list_session_snippets`
3-tuple (trait + Arc blanket impl); `SummarizerConfig.detail_max_tokens`
(serde default 110, validated > 0).

2026-06-15T22:25-0700 crates/triage-transport-ws/src/{lib.rs,flatbuffers_proto.rs}
— `SessionSnippetEntry.detail`, `ServerMessage::SessionSnippetUpdated.detail`,
borrowed `SessionSnippetUpdated.detail`; encode/decode wired; tests + bench
literals updated.

## Issues

2026-06-15T22:25-0700 `cargo clippy --all-targets` failed: two `SessionSnapshot`
literals in `protocol_bench.rs` missing `snippet_detail`. Fixed. All affected
crates: clippy clean, 86+18+17 tests pass, full workspace builds.

2026-06-15T22:55-0700 flutter/triage_client/lib/services/triage_websocket_client.dart
— `listSessionSnippets` returns `Map<String, ({String? snippet, String? detail})>`;
`detail`/`snippet_detail` threaded through the snippet-list decode, the
`session_snippet_updated` push, and the snapshot decode.

2026-06-15T22:55-0700 flutter/triage_client/lib/main.dart — `SessionVm` gains
`repoRoot`/`worktreeRoot` (+ `repoName`/`worktreeName` leaf getters) and
`snippetDetail`; both daemon-load paths capture them from snapshot `context` +
`snippet_detail`; seed + push handlers carry detail. `SessionListTile` rewritten
as a stateful hover widget: a git-context glance row (repo · branch · worktree)
plus an `OverlayPortal` popover (`_SessionGlanceCard`) showing full context + the
LLM detail summary (falls back to the one-liner). Drag-drop reorder via
`ReorderableListView` (`onReorderSession` → `_reorderSessions`, selection kept by
identity); per-device order persisted in `shared_preferences`
(`session_order_v1`), cached at startup (`_restoreSessionOrder`) and read
synchronously in `_loadDaemonSessions` so the load path never awaits prefs.

2026-06-15T22:55-0700 flutter/triage_client/pubspec.yaml — add
`shared_preferences: ^2.3.2`.

2026-06-15T22:55-0700 flutter/triage_client/test/widget_test.dart — new tests:
hover popover reveals/dismisses the detail summary; drag-reorder persists a
per-device order. Updated the select-session test's `find.text('main')` to
`findsAtLeastNWidgets(1)` (branch now renders in both the rail and the header).

## Issues (cont.)

2026-06-15T22:50-0700 First reorder attempt awaited `SharedPreferences` inside
`_loadDaemonSessions`; the extra async hop on the session-load critical path
failed 13 widget tests (sessions not populated by assertion time). Verified
against the stashed baseline (86/86 pass). Fixed by caching the saved order at
startup and reading it synchronously on the load path. One remaining failure —
`find.text('main')` matched two widgets once the rail shows the branch — was a
genuine UI change; updated the assertion.

## Research & Discoveries

- FlatBuffers: Rust regenerates via `crates/triage-core/build.rs` (flatc at
  build). Dart generated file is committed at
  `flutter/triage_client/lib/generated/triage_triage.generated_generated.dart`
  and must be regenerated with flatc.
- Snippet wiring lives in `crates/triage-transport-ws/src/lib.rs`
  (SessionSnapshot struct ~472, SessionSnippetUpdated ~500, list mapping 371-375)
  and `flatbuffers_proto.rs` (encode/decode ~837, ~1018, ~1294).
- Summarizer one inference/job today (`summarizer.rs::generate_one_line`); detail
  adds a second back-to-back inference in the same job (same loaded engine).
- `shared_preferences` is NOT yet a Flutter dependency.

## Commits

HEAD — feat: side-rail glance (branch/repo/worktree, hover detail popover, drag reorder)
