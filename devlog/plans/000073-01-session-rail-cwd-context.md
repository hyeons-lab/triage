# 000073-01 — Session rail: cwd fallback + live git-context updates

## Thinking

### Bug report
The side-rail meta line (the `repo · branch · worktree` glance under each session)
shows `main` even when a session is **not** in a git repo, and shows a stale /
wrong repo when the session is in a different repo than where it was attached.

### Root causes (confirmed)
1. **Flutter hardcodes `'main'`.** `main.dart` parses the snapshot context with
   `contextObj?['branch']?.toString() ?? 'main'` at three sites
   (`:1243` loading placeholder, `:1327` daemon load, `:1974` attach). With no
   git context the branch becomes the literal string `"main"`, so the rail
   always shows `main` for non-repo sessions.
2. **Git context is frozen at attach (Flutter).** `SessionVm.branch / repoRoot /
   worktreeRoot` are `final`, set only on attach (`:1335`, `:1982`). The daemon
   *does* re-resolve context on every OSC-7 cwd change
   (`session.rs:2352`) but never **pushes** it — there is a
   `session_snippet_updated` push event but no context equivalent. So `cd`-ing
   into another repo after attaching never updates the rail. → "wrong repo".
3. **No cwd fallback.** When there is genuinely no git context, nothing useful
   is shown. The snapshot already carries `current_working_directory` to the
   client; it just is not used by the rail.

### Desired behaviour (agreed with user)
- Not in a git repo → show the **cwd** in place of `repo · branch · worktree`.
- Path rendering: show the **absolute** path if it fits; else the **`~/`**
  home-abbreviated path if that fits; else a **scrolling marquee** (cycling
  ~every 15s) — marquee only for the **selected** session; others truncate.
- Apply fit→abbrev→marquee to **both** the git meta line and the cwd line.
- Hover popover shows the **full** path, wrapping to subsequent lines.
- Live freshness (Tier 2): rail updates as you `cd`, even while staying attached.

### Design decisions
- **New push event `session_context_updated`** mirrors `session_snippet_updated`
  exactly (schema union member → ws transport variant → daemon broadcast →
  flutter parse → flutter apply). Payload carries `current_working_directory`
  (always, even when not a repo) plus the optional `repository_root /
  worktree_root / branch`, so the client has everything for both the git line
  and the cwd fallback in one message.
- **Actor → broadcast plumbing.** `SessionActor` updates `self.context` in
  `handle_output` but has no access to `SessionManager::broadcast_global`. Pass a
  `Weak<SessionManager>` (or a dedicated `SyncSender<ServerMessage>`) into managed
  actors at spawn, alongside the existing `dirty_tx`. Broadcasting must NOT depend
  on the summarizer (which may be disabled), so it cannot route through
  `dirty_tx`/the debounce loop. Chosen: a `context_tx: SyncSender<ServerMessage>`
  clone of the same global broadcast mechanism, set on managed spawn.
- The daemon-side `std::env::current_dir()` fallback (`session.rs:1973`) is left
  as-is: when a session is launched without an explicit cwd it inherits the
  daemon's cwd, so resolving git there reflects the session's *real* inherited
  cwd. The fix is the missing client default + live push, not the daemon
  fallback.
- No new Flutter package for the marquee — a small custom widget driven by an
  `AnimationController` (Flutter has no built-in marquee; pubspec has none).

## Plan

### Tier 1 — display fix (Flutter only)
1. `SessionVm`: add `String? cwd`; change `branch` to `String?`; make
   `branch / repoRoot / worktreeRoot / cwd` **mutable** (drop `final`).
2. Remove the `?? 'main'` defaults at `:1243`, `:1327`, `:1974`; thread
   `snapshot['current_working_directory']` into `SessionVm.cwd` at both load and
   attach sites.
3. Generalise the rail meta line:
   - Build the git parts (`repo · branch · worktree`). If empty, fall back to the
     cwd path.
   - New `_PathFitText` widget: measures available width; renders absolute → `~/`
     → marquee. Marquee runs only when `selected == true`; otherwise ellipsis.
   - Home-dir abbreviation: derive `~` from the cwd vs `$HOME` (the client knows
     its own home via `Platform.environment['HOME']`; the daemon may be remote so
     pass the path as-is and abbreviate client-side only when it is under the
     local home — acceptable; remote paths just show absolute/marquee).
4. Popover (`_SessionGlanceCard`): render the full cwd path, wrapping (no
   ellipsis), when present.

### Tier 2 — live context updates (daemon + transport + flutter)
5. `crates/triage-core/schema/triage.fbs`: add
   `SessionContextUpdatedPayload { session_id; current_working_directory;
   repository_root; worktree_root; branch; }` and add it to the
   `ServerMessagePayload` union.
6. Regenerate bindings: Rust auto-regens via `build.rs`; Dart via
   `flatc --dart -o flutter/triage_client/lib/generated/ crates/triage-core/schema/triage.fbs`
   (reconcile the `*_generated.dart` filename with the checked-in
   `triage_triage.generated_generated.dart`).
7. `crates/triage-transport-ws/src/lib.rs`: add
   `ServerMessage::SessionContextUpdated { session_id, current_working_directory,
   repository_root, worktree_root, branch }`.
8. `crates/triage-transport-ws/src/flatbuffers_proto.rs`: add encode + borrowed
   decode arms mirroring `SessionSnippetUpdated`.
9. `crates/triaged/src/session.rs`:
   - Thread a global broadcast handle (`SyncSender<ServerMessage>` clone, or
     `Weak<SessionManager>`) into managed actors at spawn (next to `dirty_tx`).
   - In `handle_output`, when `output.ingest` yields a new cwd and context is
     re-resolved, broadcast `ServerMessage::SessionContextUpdated`.
10. Flutter `triage_websocket_client.dart`: parse the new payload type → emit
    `{'type':'session_context_updated', session_id, current_working_directory,
    repository_root, worktree_root, branch}`; forward it on `_eventController`.
11. Flutter `main.dart` `_processWebSocketEvent`: handle
    `session_context_updated` — find the session, update its mutable
    `branch / repoRoot / worktreeRoot / cwd`, `setState`.

### Validation
- `cargo test` (triage-core, triage-transport-ws, triaged) for the Rust changes
  and existing session-context tests.
- `flutter analyze` + `flutter test` for the client.
- Manual: launch app, start a session in a repo (shows repo·branch·worktree),
  `cd` to a non-repo dir (rail switches to cwd, live), `cd` into another repo
  (rail updates), select a long-path session (marquee), hover (full wrapped path).
