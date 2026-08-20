# Plan: Settings Panel with Approval Judge Guide & Configuration

## Thinking

The user asked how someone discovers how to configure the tool-call approval judge and requested expanding the gear icon from just a daemon IP switcher into a full Settings panel with multiple categories.

Key requirements:
1. **Tabs/Sections in Settings Modal**:
   - **Daemons** (`Icons.dns_outlined`): The existing multi-server connection manager (select, add, edit, forget).
   - **Approval Judge** (`Icons.auto_awesome`):
     - Architecture explanation (Layer 1 Deny, Layer 2 Allow, Layer 3 Local Model).
     - Hook setup instructions (`triage-hook` installation, `TRIAGE_SESSION_ID` session inheritance).
     - One-click copyable `.agents/hooks.json` code block.
     - Configuration guide (`~/.config/triage/config.toml` `[judge]` settings).
   - **Terminal & Appearance** (`Icons.tune`):
     - Terminal font size options.
     - Appearance / client info (Client ID, version).
2. **Design & UX**:
   - Follow project aesthetic rules: neutral dark palette, curated typography, no cliché glows or borders, responsive dialog width (up to 560px on desktop/web, fluid on mobile).
   - Smooth tab switching with active indicator.
   - One-click copy with feedback ("Copied to clipboard!").
3. **Tests**:
   - Unit and widget tests verifying tab switching, content rendering, copy actions, and daemon management within the new Settings dialog.

## Direct Hook Modification via Daemon RPC

The user asked: "can we make the settings dialog actually modify the json? why would the user need to copy and paste it?"
Instead of requiring manual file edits or copy-pasting, the Settings panel should provide a 1-click toggle / configure button that directly reads, enables, or creates `.agents/hooks.json` in the active workspace on the daemon machine.

1. **Protocol & Core**:
   - Add `JudgeHookStatus` in `crates/triage-core/src/judge.rs`.
   - Add `GetJudgeHookStatus` and `ConfigureJudgeHook` to `crates/triage-core/schema/triage.fbs`, `crates/triage-transport-ws`, and `SessionApi`.
   - Regenerate FlatBuffers with `scripts/generate-dart-flatbuffers.sh`.
2. **Daemon (`triaged`)**:
   - Implement `get_judge_hook_status` and `configure_judge_hook` in `triaged::judge` / `triaged::session`.
   - Resolves workspace root from active session cwd, reads `.agents/hooks.json`, inserts/updates `"triage-approval-judge"`, writes cleanly formatted JSON.
3. **Flutter Client**:
   - Add `getJudgeHookStatus` and `configureJudgeHook` methods to `TriageWebSocketClient`.
   - In `SettingsDialog` (`Approval Judge` tab), show an interactive toggle switch: "Workspace Hook Integration" with live status and path.
   - Toggling the switch immediately writes `.agents/hooks.json` on the host with instant UI feedback.
4. **Validation**:
   - Unit tests in Rust and widget tests in Flutter.
   - Rebuild release bundle and verify live on port 7777.

