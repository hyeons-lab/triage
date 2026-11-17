# Devlog 000189: feat/mobile-composer-and-chips

**Agent:** Gemini @ triage branch `feat/mobile-composer-and-chips`

## Intent

1. Surface the new daemon snapshot metadata (`parentSessionId`, `outliveParent`, `pendingApproval`, `pendingApprovalReason`) in the Flutter WebSocket client, `SessionVm`, and `TerminalPane`.
2. Add **Tap-to-Answer Approval Chips** above the mobile accessory bar whenever a session is awaiting approval/confirmation (`pendingApproval` or visible confirmation prompt).
3. Add a **Toggleable Bottom Composer Bar** in the mobile bottom controls so users can switch cleanly between direct line-buffered terminal IME and a visible multiline draft box with full Android swipe/autocorrect/editing and one-tap Send.
4. Run full workspace verification (including embedded Flutter web build) and rebuild the Android release APK served for download.

## Progress

- [x] Create stacked worktree `feat/mobile-composer-and-chips` on `feat/mobile-line-buffered-ime`
- [x] Write branch devlog and plan (`devlog/plans/000189-01-mobile-composer-and-approval-chips.md`)
- [x] Decode and wire `parentSessionId`, `outliveParent`, `pendingApproval`, and `pendingApprovalReason` into `SessionVm` and `TerminalPane`
- [x] Add approval prompt parser + `ApprovalChipsBar` widget above the mobile accessory/composer bar
- [x] Add `TerminalComposerBar` widget + `compose` toggle in `TerminalAccessoryBar` and `TerminalPane`
- [x] Add Flutter widget/unit tests and run `dart format`, `flutter analyze`, `flutter test`
- [x] Run full Rust + embedded web verification (without `TRIAGE_SKIP_FLUTTER_BUILD`) and rebuild release Android APK

## What Changed

- `2026-11-15T15:37-0800 flutter/triage_client/lib/services/triage_websocket_client.dart`: Updated `_parseSessionSnapshot` to include `parent_session_id`, `outlive_parent`, `pending_approval`, and `pending_approval_reason` from FlatBuffer snapshots.
- `2026-11-15T15:37-0800 flutter/triage_client/lib/main.dart`: Added `parentSessionId`, `outliveParent`, `pendingApproval`, `pendingApprovalReason`, and `applySnapshotMeta` to `SessionVm` and forwarded pending approval flags to `TerminalPane`.
- `2026-11-15T15:37-0800 flutter/triage_client/lib/terminal/approval_prompt_parser.dart`, `lib/widgets/approval_chips_bar.dart`: Added confirmation/menu prompt parser (`[y/N]`, `(y/n/a)`, numbered choices `1. ...`, `press enter to confirm`, and daemon-reported `pendingApproval` fallback) plus single-tap `ApprovalChipsBar`.
- `2026-11-15T15:37-0800 flutter/triage_client/lib/widgets/terminal_composer_bar.dart`, `lib/widgets/terminal_accessory_bar.dart`, `lib/widgets/terminal_pane.dart`: Added toggleable multiline `TerminalComposerBar` with per-session draft preservation, clean focus handoff away from raw IME, bracketed-paste-aware multiline submit + CR, and live/snapshot approval chip rendering above the accessory bar.
- `2026-11-15T15:37-0800 flutter/triage_client/test/approval_prompt_parser_test.dart`, `test/mobile_composer_and_chips_test.dart`: Added unit and Android widget tests for prompt parsing, chip dispatch/dismissal, and composer toggle/draft/multiline sending.

## Decisions

- `2026-11-15T15:37-0800 Decision`: Combine daemon `pendingApproval` state with live bottom-row pattern matching in `TerminalPane` so confirmation chips appear immediately when TUI agents prompt, and dismiss the tapped prompt signature locally until output changes so stale chips vanish right away.

## Commits

- `HEAD`: `feat(client): add mobile composer bar and tap-to-answer approval chips`
