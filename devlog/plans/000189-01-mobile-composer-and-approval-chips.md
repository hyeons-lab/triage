# Plan 000189-01: Mobile Composer Bar and Tap-to-Answer Approval Chips

## Thinking

Two high-leverage mobile UX pieces complete the Triage phone workflow:
1. **Tap-to-Answer Approval Chips**: Daemon snapshots already expose `pending_approval` and `pending_approval_reason`, and visible terminal rows frequently show confirmation prompts (`[y/N]`, `(yes/no)`, numbered `1. Yes / 2. ... / 3. No`, `Do you want to proceed?`, etc.). On a phone, tapping small keyboard keys (`y`, `Enter`, or `2`) requires opening the soft keyboard just to send one confirmation byte. Showing contextual pill chips directly above the mobile accessory bar makes single-tap approval/denial/cancel effortless while keeping focus behavior non-intrusive.
2. **Toggleable Bottom Composer Bar**: Even with line-buffered IME, multi-line prompts, long paragraphs, or careful editing before submission are far easier in a visible scrollable multiline draft box (`TextField`) where the user sees the full draft and taps Send when ready.

To keep focus clean, toggling Composer open flushes any active raw IME composing text and shifts focus to the composer `FocusNode` (automatically closing the raw terminal `TextInputConnection` so Gboard attaches cleanly to the composer `TextField`), while collapsing Composer returns focus to the terminal `FocusNode` (preserving unsent draft text per session until sent).

## Plan

1. Update `flutter/triage_client/lib/services/triage_websocket_client.dart` (`_parseSessionSnapshot`) to expose `'parent_session_id'`, `'outlive_parent'`, `'pending_approval'`, and `'pending_approval_reason'`.
2. Add `parentSessionId`, `outliveParent`, `pendingApproval`, and `pendingApprovalReason` (plus a shared `applySnapshotMeta(Map<String, dynamic>?)` helper) to `SessionVm` in `flutter/triage_client/lib/main.dart`, call it on initial attach/create/refresh paths, and pass `pendingApproval` + `pendingApprovalReason` to `TerminalPane`.
3. Create `flutter/triage_client/lib/terminal/approval_prompt_parser.dart` to derive `ApprovalPromptState` (`reason` + ordered `ApprovalChoice` chips) from `(pendingApproval, pendingApprovalReason, visibleRows)`:
   - Parses numbered options (`1. ...`, `2. ...`, `3. ...`) into single-digit chips + `Esc` (`\x1b`).
   - Parses `[y/N]` / `(y/n)` / `(y/n/a)` style prompts into `Yes` (`y\r`), optional `Always` (`a\r`), `No` (`n\r`), and `Esc` (`\x1b`).
   - Falls back to `[Yes (y), Always (a), No (n), Esc]` when `pendingApproval` is true without explicit option tokens.
4. Create `flutter/triage_client/lib/widgets/approval_chips_bar.dart` and `flutter/triage_client/lib/widgets/terminal_composer_bar.dart`, add an optional `composeOpen` + `onToggleComposer` button to `TerminalAccessoryBar` (`terminal_accessory_bar.dart`), and wire both into `TerminalPane` (`_buildMobileBottomChrome()`) with clean focus handoff, per-session draft preservation, bracketed-paste-aware multiline send + `\r`, and tap-to-dismiss tracking until output changes.
5. Add unit and widget tests (`test/approval_prompt_parser_test.dart` and composer/chip tests in `test/terminal_pane_ime_test.dart` / `test/terminal_accessory_bar_test.dart`) covering snapshot propagation, prompt parsing, chip taps, and composer toggle/draft/multiline send.
6. Verify with `dart format`, `flutter analyze`, `flutter test`, full workspace `cargo fmt --all -- --check && cargo clippy --all-targets --all-features -- -D warnings && cargo test --workspace` (building the real Flutter web bundle too), rebuild `flutter build apk --release`, update the served scratch APK copy, update the devlog, and commit.
