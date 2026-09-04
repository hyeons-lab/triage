# Plan: Side Rail Session Custom Labels and Cera Bump

## Thinking

The user requested two things:
1. Right-click a session in the side rail to assign a custom label to differentiate sessions more easily.
2. Update the version of `cera` used to the latest published version (`0.5.2`).

### Requirements & Design Decisions
1. **Custom Session Labels**:
   - `SessionVm`: Add `customLabel` field.
   - `displayTitle` and `railTitle`: Return `customLabel` when set and non-empty.
   - `glanceTitle`: Return `customLabel` when set and non-empty.
   - `SessionSearchInput`: Include `customLabel` in search indexing and matching.
   - `SessionListTile`:
     - Support secondary click (right-click on desktop/web) and long press (touch/mobile) to open a context menu.
     - Context menu options: "Assign Label..." / "Edit Label..." and "Clear Label" (when assigned).
     - Custom label dialog: Dark-themed modal with text field, autofocus, pre-selected text, Enter-key submission, Save, Clear, and Cancel buttons.
     - Meta line rendering: When a custom label is set on a repo session, show the repo and branch/worktree on the meta line beneath the label.
     - Glance card (hover popover): Display custom label clearly.
   - Persistence:
     - Store labels in `SharedPreferences` keyed by server (`session_custom_labels_v1_$serverId`) as a JSON map of session ID to custom label string.
     - Hydrate on session load/connect, persist on assign/edit/clear.
2. **Cera Dependency Bump**:
   - Update `Cargo.toml` from git main to `cera = { version = "0.5.2", features = ["remote"] }`.
   - Update `cera::EngineConfig` initialization to include `draft_model: None`.
   - Update `cera::manifest::GenerationDefaults::Audio` struct initializer in tests to match `0.5.2` fields.

## Plan

1. **Devlog & Plan files**:
   - Create `devlog/plans/000133-01-siderail-custom-label.md` and `devlog/000133-feat-siderail-custom-label.md`.
2. **Cera Bump**:
   - Update `Cargo.toml`, `crates/triaged/src/summarizer.rs`.
   - Validate with `cargo check --workspace` and `cargo test --workspace`.
3. **Session Custom Labels (Dart & Flutter UI)**:
   - Update `flutter/triage_client/lib/session_rail_layout.dart` (`SessionSearchInput`).
   - Update `flutter/triage_client/lib/services/server_store.dart` (custom labels pref key, migration helpers).
   - Update `flutter/triage_client/lib/main.dart` (`SessionVm`, `SessionListTile`, context menu, dialog, persistence).
4. **Testing & Verification**:
   - Add unit and widget tests for custom labels in `session_rail_identity_test.dart`, `session_rail_layout_test.dart`, and `widget_test.dart`.
   - Run `flutter test` and workspace `cargo test`.
   - Run formatting check (`cargo fmt --all -- --check`, `dart format --output=none --set-exit-if-changed .`).
   - Run `cargo clippy --all-targets --all-features -- -D warnings`.
5. **Update Devlog & Commit**:
   - Update devlog with all changes, decisions, and commits.
