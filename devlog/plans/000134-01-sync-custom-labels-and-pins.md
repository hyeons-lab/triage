# Synchronize Custom Session Labels, Session Rail Ordering, and Pinning Across Clients

## Thinking

The triage client supports custom session labels (added in PR #154) and custom rail ordering via group/session pinning (`SessionPins`). However, both custom labels and pins currently exist only inside local client storage (`SharedPreferences`). If a user opens triage from another browser tab, another machine, or a mobile client, the custom labels and pinned session order are not visible.

The user wants:
1. Custom session labels to be synchronized across clients.
2. The order of sessions and pinning to be synchronized across clients.

### Architectural Analysis

1. **Pins and Rail Ordering Coupling**:
   In `flutter/triage_client/lib/session_grouping.dart`, rail order is governed by `SessionPins`:
   - `groupKeys`: ordered list of pinned repository roots / group identifiers.
   - `sessionIds`: ordered list of pinned session IDs within their respective groups.
   All unpinned groups and sessions sort dynamically based on `lastActivityMs`.
   Therefore, synchronizing `SessionPins` directly synchronizes the user-defined rail ordering and pinning across all connected clients.

2. **Custom Labels**:
   Custom labels map session IDs (with fallback `triage / <id>`) to custom user strings. Storing a dictionary of session ID to custom label on the daemon allows any client to display human-assigned names for sessions.

3. **Daemon Persistence and Handover**:
   - `crates/triaged/src/session.rs`: `SessionManifest` in `manifest.json` persists sessions across daemon restarts. Adding `pins: SessionPins` and `custom_labels: HashMap<String, String>` ensures that labels and pins persist across cold starts.
   - `crates/triaged/src/handover.rs`: `HandoverState` carries live state across zero-downtime process handovers (`triaged reload`). Adding `pins` and `custom_labels` with `#[serde(default)]` preserves this state seamlessly without dropping user layout during updates.

4. **Protocol Definitions (JSON and FlatBuffers)**:
   - `crates/triage-core/src/session.rs`:
     - Define `SessionPins` (`group_keys: Vec<String>`, `session_ids: Vec<String>`) and `RailLayout` (`group_keys: Vec<String>`, `session_ids: Vec<String>`, `custom_labels: HashMap<String, String>`).
     - Add `SessionApi` methods: `get_rail_layout`, `set_rail_pins`, `set_session_custom_label`.
   - `crates/triage-core/schema/triage.fbs`:
     - Add `GetRailLayoutRequest`, `SetRailPinsRequest`, `SetSessionCustomLabelRequest` to `ClientRequestPayload`.
     - Add `CustomLabelEntry` and `RailLayoutResult` to `ServerResultPayload`.
     - Add `RailPinsUpdatedPayload` and `SessionCustomLabelUpdatedPayload` to `ServerMessagePayload`.
     - Regenerate Dart bindings via `scripts/generate-dart-flatbuffers.sh`.
   - `crates/triage-transport-ws`:
     - Wire `ClientRequest` variants: `GetRailLayout`, `SetRailPins`, `SetSessionCustomLabel`.
     - Wire `ServerResult` variant: `RailLayout`.
     - Wire `ServerMessage` variants: `RailPinsUpdated`, `SessionCustomLabelUpdated`.
     - Handle parsing and serialization for both JSON and FlatBuffers.

5. **Client Integration (`flutter/triage_client`)**:
   - `services/triage_websocket_client.dart`:
     - Add `getRailLayout()`, `setRailPins()`, `setSessionCustomLabel()`.
     - Listen for `rail_pins_updated` and `session_custom_label_updated` server messages.
   - `main.dart`:
     - On connect/load: fetch daemon rail layout (`getRailLayout`). If daemon has stored pins or custom labels, adopt them and update local state and SharedPreferences cache. If daemon is empty but local SharedPreferences has existing pins/labels, seed the daemon with the local state (migration path).
     - On user edit of label: update locally, write to SharedPreferences, and send `setSessionCustomLabel` to daemon.
     - On user reorder/pin: update locally, write to SharedPreferences, and send `setRailPins` to daemon.
     - On incoming `rail_pins_updated`: apply pins if different from current `_pins` without re-persisting back to daemon.
     - On incoming `session_custom_label_updated`: update `_customLabels`, update target `SessionVm.customLabel`, and trigger re-render.

## Plan

1. **Core Models and Trait (`crates/triage-core`)**:
   - Add `SessionPins` and `RailLayout` structs in `crates/triage-core/src/session.rs`.
   - Add `get_rail_layout`, `set_rail_pins`, `set_session_custom_label` to `SessionApi`.
   - Update `crates/triage-core/schema/triage.fbs` with new tables and unions for requests, results, and push messages.
   - Regenerate Dart FlatBuffers bindings using `scripts/generate-dart-flatbuffers.sh`.

2. **Daemon Persistence and Handover (`crates/triaged`)**:
   - Extend `HandoverState` in `crates/triaged/src/handover.rs` to include `pins` and `custom_labels`.
   - Update `SessionManifest` in `crates/triaged/src/session.rs` to store and load `pins` and `custom_labels`.
   - Implement `get_rail_layout`, `set_rail_pins`, and `set_session_custom_label` in `SessionManager`.
   - When mutations occur, update in-memory state, persist to `manifest.json`, and broadcast `RailPinsUpdated` / `SessionCustomLabelUpdated` via `broadcast_global`.
   - Preserve pins and custom labels across `extract_handover_state`, `adopt_sessions`, and `queue_handover_adoptions`.

3. **WebSocket Transport (`crates/triage-transport-ws`)**:
   - Extend `ClientRequest`, `ServerResult`, and `ServerMessage` in `crates/triage-transport-ws/src/lib.rs`.
   - Update `flatbuffers_proto.rs` in `crates/triage-transport-ws` to serialize and parse new requests, results, and messages.

4. **Client-Side Sync (`flutter/triage_client`)**:
   - Update `TriageWebSocketClient` to handle FlatBuffers and JSON decoding for the new messages.
   - Add client API methods: `getRailLayout`, `setRailPins`, `setSessionCustomLabel`.
   - Update `main.dart` to fetch layout on connect, push edits on change, and apply inbound broadcasts in real time.

5. **Validation and Testing**:
   - Run unit tests in `crates/triaged` and `crates/triage-transport-ws`.
   - Run Flutter tests in `flutter/triage_client`.
   - Run `cargo fmt --all -- --check` and `cargo clippy --all-targets --all-features -- -D warnings`.
