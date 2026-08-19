# Plan: Judge Rules, Decision History, and Custom Rule Management in Settings UI

## Thinking

1. **Goal**:
   - Provide full transparency and interactivity in the **Approval Judge** Settings tab so users can see how the judge makes decisions, review actual decision history (recent `Deny` and `Ask` tool calls), and easily customize the allow/deny rules (e.g. promoting recent denied or asked commands to the allowlist with 1 click).

2. **Components to Build**:
   - **`triage-core`**:
     - `JudgeRecord`: data structure for decision history events (`timestamp`, `session_id`, `tool_name`, `command_line`, `decision`, `source`, `reason`).
     - `JudgeRulesInfo`: data structure reporting builtin allow rules, custom allow rules, builtin deny rules, and custom deny substrings.
   - **`triaged`**:
     - Record each judged tool call into an in-memory bounded ring buffer (last 50 decisions).
     - Provide IPC / WebSocket endpoints:
       - `GetJudgeHistory`: returns the recent decision history.
       - `GetJudgeRules`: returns builtin + custom allow/deny lists.
       - `AddJudgeAllowRule` / `RemoveJudgeAllowRule`: modifies in-memory `JudgeConfig` and updates `~/.config/triage/config.toml`.
       - `AddJudgeDenyRule` / `RemoveJudgeDenyRule`: modifies in-memory `JudgeConfig` and updates `~/.config/triage/config.toml`.
   - **`triage-transport-ws`**:
     - Handle `GetJudgeHistory`, `GetJudgeRules`, and rule modification requests in FlatBuffers & JSON wire handlers.
   - **`flutter/triage_client`**:
     - In `triage_websocket_client.dart`: add client methods and models (`getJudgeHistory`, `getJudgeRules`, `addJudgeAllowRule`, `removeJudgeAllowRule`, `addJudgeDenyRule`, `removeJudgeDenyRule`).
     - In `main.dart` `_buildJudgeTab`:
       - **Active Rules & Architecture Breakdown**: Display cards for Builtin Allow Commands, Hard Deny Rules, and Active Custom Rules.
       - **Recent Decision History / Live Activity**: Display feed of recent judge verdicts with status badges (`DENY` in red, `ASK` in amber, `ALLOW` in teal). Each row shows timestamp, tool, command, decision, and why it happened.
       - **1-Click Allow Promotion**: For any `DENY` or `ASK` row in the history, offer a `"+ Allow Rule"` button that pre-populates or adds the command prefix to the custom allow list.
       - **Custom Rule Editor**: Add/remove custom allow commands and custom deny substrings directly.

## Plan

1. **Extend `triage-core` Judge Models**:
   - Define `JudgeRecord` and `JudgeRulesInfo` in `crates/triage-core/src/judge.rs`.
2. **Implement History Buffer & Config Persistence in `triaged`**:
   - Add `JudgeDecisionHistory` circular buffer in `crates/triaged/src/judge.rs`.
   - Add methods in `SessionManager` / `judge.rs` to query history, query rules, and add/remove custom rules in `~/.config/triage/config.toml`.
3. **Wire WebSocket Protocol in `crates/triage-transport-ws` & `triaged`**:
   - Add RPC endpoints for `GetJudgeHistory`, `GetJudgeRules`, `AddJudgeAllowRule`, `RemoveJudgeAllowRule`, `AddJudgeDenyRule`, `RemoveJudgeDenyRule`.
4. **Implement Client Services & Multi-Section Settings UI in Flutter**:
   - Add models and methods to `TriageWebSocketClient`.
   - Build Decision History feed and Rule Editor sections in `_buildJudgeTab`.
5. **Verify with Tests**:
   - Rust unit tests in `triaged` and `triage-transport-ws`.
   - Flutter widget tests in `test/widget_test.dart`.
6. **Compile & Deploy**:
   - Build release daemon with fresh Flutter bundle, re-sign on macOS, and reload daemon with zero downtime.
