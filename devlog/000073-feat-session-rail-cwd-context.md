# 000073 — Session rail: cwd fallback + live git-context updates

**Agent:** Claude (claude-opus-4-8) @ triage branch feat/session-rail-cwd-context

## Intent
The side-rail meta line shows `main` even when a session is not in a git repo,
and shows a stale/wrong repo when the session moves to a different repo than
where it was attached. Replace the hardcoded `main` with a cwd fallback, render
long paths with fit→`~/`→marquee (marquee on the selected session only) plus a
full wrapping path in the hover popover, and push live git-context updates from
the daemon so the rail stays fresh as the user `cd`s.

## Decisions
- 2026-06-17T20:19-0700 New `session_context_updated` push event mirrors
  `session_snippet_updated` end-to-end — chosen over reusing the snippet event so
  context freshness is independent of the (optional) summarizer.
- 2026-06-17T20:19-0700 Context-update payload carries
  `current_working_directory` plus the optional git fields in one message, so the
  client has everything for both the git line and the cwd fallback.
- 2026-06-17T20:19-0700 Leave the daemon's `std::env::current_dir()` spawn
  fallback as-is — a no-cwd session genuinely inherits the daemon's cwd, so
  resolving git there reflects the session's real cwd. The bug is the client's
  hardcoded `main` default + the missing live push, not the daemon fallback.
- 2026-06-17T20:19-0700 Custom marquee widget, no new pubspec dependency.

## What Changed
- 2026-06-17T20:47-0700 `flutter/triage_client/lib/main.dart` — `SessionVm`
  gains a mutable `cwd` and its git fields (`branch`/`repoRoot`/`worktreeRoot`)
  become nullable + mutable so live context pushes update them in place. Removed
  the three `?? 'main'` defaults (load, attach, loading placeholder) that made
  non-repo sessions show `main`. New `_MetaLineText` widget renders the rail meta
  adaptively: absolute → `~/…` → marquee (selected row only, via `_MarqueeText`)
  → static ellipsis; falls back to the cwd when there is no git context. Added
  `_homeAbbreviatedPath` and `_marqueeAnimationsEnabled` (the latter disables the
  perpetual marquee under `flutter test`, where it would hang `pumpAndSettle`).
  Popover (`_SessionGlanceCard`/`_GlanceRow`) shows the full cwd, wrapping. The
  workspace header subtitle falls back to the cwd when branchless.
- 2026-06-17T20:47-0700 `crates/triage-core/schema/triage.fbs` — new
  `SessionContextUpdatedPayload` table + `ServerMessagePayload` union member.
- 2026-06-17T20:47-0700 `flutter/.../generated/triage_triage.generated_generated.dart`
  — regenerated Dart bindings (`flatc --dart`).
- 2026-06-17T20:47-0700 `crates/triage-transport-ws/src/{lib,flatbuffers_proto}.rs`
  — `ServerMessage::SessionContextUpdated` variant + flatbuffers encode/borrowed
  decode arms; added `flatbuffers_session_context_updated_roundtrip` test.
- 2026-06-17T20:47-0700 `crates/triaged/src/session.rs` — `global_senders`
  hoisted to a shared `Arc<Mutex<…>>` (`GlobalSenders`) with a free
  `broadcast_to_global_senders`; managed `SessionActor`s receive a clone and
  broadcast `SessionContextUpdated` from `handle_output` when the cwd/git context
  actually changes (re-resolved each prompt, broadcast only on change).
- 2026-06-17T20:47-0700 `flutter/.../services/triage_websocket_client.dart` —
  parse + forward the `session_context_updated` push; `main.dart`
  `_processWebSocketEvent` applies it to the live `SessionVm`.

## Progress
- [x] Tier 1: SessionVm cwd field + nullable/mutable context, remove `?? 'main'`
- [x] Tier 1: fit→`~/`→marquee path rendering (selected-only marquee)
- [x] Tier 1: wrapping full path in popover
- [x] Tier 2: fbs schema + regenerate Rust/Dart bindings
- [x] Tier 2: ws transport ServerMessage variant + encode/decode
- [x] Tier 2: daemon actor broadcast on context change
- [x] Tier 2: flutter parse + live apply
- [x] cargo test + flutter analyze/test

## Issues
- 2026-06-17T20:47-0700 The marquee's `AnimationController.repeat()` runs
  perpetually; under `flutter test` the fake-async clock fast-forwards
  `pumpAndSettle` to its timeout while frames stay scheduled, hanging ~20 shell
  tests. Resolved by gating the marquee on `_marqueeAnimationsEnabled()`
  (`!FLUTTER_TEST`), so tests render static text. Production keeps the marquee.
- 2026-06-17T20:47-0700 The widget test "closes a session over WebSocket and
  removes it from the list" fails — confirmed PRE-EXISTING on origin/main (same
  `+95 -1` with this branch's changes stashed), unrelated to this work.

## Lessons Learned
- Flutter sets the `FLUTTER_TEST` env var during `flutter test`; reading it via
  `Platform.environment` is a clean way to disable perpetual animations that
  would otherwise hang `pumpAndSettle`.
- `flatc --dart` derives the output filename from the schema namespace, matching
  the checked-in `triage_triage.generated_generated.dart`; the Rust bindings
  regenerate automatically via `crates/triage-core/build.rs` on `cargo build`.

## Commits
- HEAD — feat(rail): show cwd when outside a repo + live git-context updates
