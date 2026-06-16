# Side-rail glance: branch/repo/worktree, hover popover (detailed LLM summary), drag-drop reorder

## Thinking

Follow-up to feat/session-snippets (#74). The Flutter side rail currently shows
per session: title, status dot + status text, and the one-line LLM snippet. We
want to make it a richer "glance" surface:

1. **Branch / repo / worktree** rows in each tile, so you can identify a session
   at a glance.
2. **Hover popover** showing a more comprehensive summary (a *second*, longer
   LLM-generated detail summary + the metadata). The detail summary will also
   feed a future fuzzy search over sessions.
3. **Drag-and-drop reorder** of sessions in the rail, persisted client-local.

### Decisions (settled with user)

- **Detail summary** → a *second* LLM generation (`generate_detail()`), carried
  in a new `snippet_detail` protocol field. Accepted ~2x inference per debounce.
- **Reorder persistence** → client-local via `shared_preferences` (per-device,
  not shared with TUI or other clients). No daemon/protocol change for ordering.
- **Scope** → everything in one branch.

### What already exists (no work needed)

- `SessionSnapshot.context` already carries `repository_root`, `worktree_root`,
  `branch` (triage.fbs:62-66). Every session is snapshotted+attached on load
  (`_loadDaemonSession`, main.dart:1060), so the client already has context per
  session. **Display is pure client work — no protocol change for metadata.**
- One-liner snippet pipeline: `summarizer.rs::generate_one_line` → debounce loop
  (`session.rs::run_debounce_loop`) → `apply_snippet` caches + broadcasts
  `SessionSnippetUpdated` → client seed (`list_session_snippets`) + push.

### Detail-summary design

The summarizer worker already loads one heavy `cera` engine on a dedicated
thread and processes coalesced jobs. For each job we currently run one inference
(`generate_one_line`). We add a second inference `generate_detail` in the same
job — same engine, same prompt text, different system prompt and a multi-line
sink with a larger char cap (~280 chars, ~3 sentences). Running both back-to-back
in one job keeps it on the worker thread and reuses the loaded model. Both
results travel together so the cache/broadcast stay single-writer.

`SnippetResult { text, detail, generated_at_output_seq }`. `SessionSnippet`
gains `detail: String`. `apply_snippet` caches+broadcasts both. The snapshot
builder fills `snippet_detail`. `list_session_snippets` returns
`(SessionId, Option<String> snippet, Option<String> detail)`.

Protocol additions (append-only, backward compatible):
- `SessionSnapshot.snippet_detail: string;`
- `SessionSnippetEntry.detail: string;`
- `SessionSnippetUpdatedPayload.detail: string;`

FlatBuffers: Rust regenerates via `crates/triage-core/build.rs` (flatc at build).
Dart generated file `flutter/triage_client/lib/generated/triage_triage.generated_generated.dart`
must be regenerated with flatc and committed.

### Reorder design (client-local)

- Add `shared_preferences` dependency.
- Persist an ordered list of `remoteSessionId`s under a key
  (`session_order_v1`). On reorder, write the current order. On daemon load,
  stable-sort `_sessions` by saved order (unknown ids → appended in existing
  order; new sessions still insert at index 0 then participate in saved order on
  next load).
- Replace the rail's `Column` of tiles with a `ReorderableListView` (expanded
  rail). Keep `selectedIndex` semantics correct across reorders (track by
  session identity, not raw index, when persisting selection).

### Popover design

- `MouseRegion` over each `SessionListTile` → on hover show an `OverlayPortal`
  / `Tooltip`-like rich popover anchored to the tile. Content assembled from
  what we have: repo · branch · worktree · cwd · status · the detail summary.
- The detail summary is the LLM `snippet_detail`; falls back to the one-liner
  (or "No summary yet") when absent.

## Plan

### Phase 1 — Daemon + protocol (detail summary)

1. `triage.fbs`: add `snippet_detail` (SessionSnapshot), `detail`
   (SessionSnippetEntry), `detail` (SessionSnippetUpdatedPayload).
2. Regenerate Dart fbs (`flatc --dart`), confirm Rust regenerates via build.rs.
3. `summarizer.rs`: `DETAIL_SYSTEM_PROMPT`, `generate_detail()` (multi-line sink,
   ~280 char cap), `SnippetResult.detail`, worker runs both inferences per job.
4. `session.rs`: `SessionSnippet.detail`; `apply_snippet` caches+broadcasts both;
   `list_session_snippets` returns detail; snapshot builder fills `snippet_detail`.
5. `transport-ws` (`lib.rs` + `flatbuffers_proto.rs`): thread `detail` through the
   `SessionSnapshot` struct, `SessionSnippetUpdated` message, `SessionSnippetEntry`,
   encode/decode. Update existing tests' literals.
6. `cargo fmt` + `cargo clippy` + `cargo test -p triaged -p triage-transport-ws`.

### Phase 2 — Client display + popover

7. `SessionVm`: add `repoRoot`, `worktreeRoot` (String?), `snippetDetail`
   (String?). Capture from snapshot `context` at load (main.dart:1134) and from
   seed/push.
8. `SessionListTile`: render repo · branch (and worktree leaf) rows; wrap in
   `MouseRegion` + popover overlay showing the assembled detail.
9. Seed/push handlers: capture `detail` alongside `snippet`.

### Phase 3 — Reorder

10. Add `shared_preferences`; load saved order on daemon load; stable-sort.
11. `ReorderableListView` in expanded rail; persist on reorder; keep selection by
    identity.

### Phase 4 — Verify + ship

12. `flutter analyze`; build macOS Release; manual smoke (rail shows metadata,
    hover popover, reorder persists across restart, snippets still update).
13. Devlog, commit, push, open PR (draft until smoke-tested).

## Open follow-ups (out of scope)

- Fuzzy search over `snippet_detail` (the detail field is the search corpus).
- Daemon-side shared ordering, if per-device proves insufficient.
