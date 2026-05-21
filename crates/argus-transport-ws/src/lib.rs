use std::collections::HashMap;
use std::sync::mpsc::TryRecvError;

use anyhow::{Result, bail};
use argus_core::session::{
    AttachSessionRequest, AttachSessionResponse, ClientId, CompletedSession, InputLeaseRequest,
    LeaseChange, ResizeSessionRequest, RestoreSessionRequest, SessionApi, SessionEventEnvelope,
    SessionEventReceiver, SessionId, SessionSnapshot, StartSessionRequest, StyledRowsRequest,
    StyledRowsResponse, SubscribeSessionEventsRequest, WriteInputRequest,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: &str = "2026-05-20";
const MAX_EVENTS_PER_SUBSCRIPTION_DRAIN: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SubscriptionId(String);

impl SubscriptionId {
    pub fn new(id: impl Into<String>) -> Result<Self> {
        let id = id.into();
        if id.trim().is_empty() {
            bail!("subscription id must be set");
        }
        Ok(Self(id))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug)]
pub struct WebSocketSessionConnection<A> {
    api: A,
    next_subscription_id: u64,
    subscriptions: HashMap<SubscriptionId, SessionEventReceiver>,
}

impl<A: SessionApi> WebSocketSessionConnection<A> {
    pub fn new(api: A) -> Self {
        Self {
            api,
            next_subscription_id: 1,
            subscriptions: HashMap::new(),
        }
    }

    pub fn handle_text_message(&mut self, message: &str) -> String {
        let response = match serde_json::from_str::<Value>(message) {
            Ok(value) => {
                let id = request_id_from_value(&value);
                match serde_json::from_value::<ClientMessage>(value) {
                    Ok(message) => self.handle_message(message),
                    Err(error) => ServerMessage::Error {
                        id,
                        error: ProtocolError::new("invalid_request", error.to_string()),
                    },
                }
            }
            Err(error) => ServerMessage::Error {
                id: None,
                error: ProtocolError::new("invalid_json", error.to_string()),
            },
        };

        serialize_server_message(&response)
    }

    pub fn handle_message(&mut self, message: ClientMessage) -> ServerMessage {
        let id = message.id;
        match self.handle_request(message.request) {
            Ok(result) => ServerMessage::Response { id, result },
            Err(error) => ServerMessage::Error {
                id,
                error: ProtocolError::new("request_failed", error.to_string()),
            },
        }
    }

    pub fn drain_events(&mut self) -> Vec<ServerMessage> {
        let mut messages = Vec::new();
        let mut closed_subscriptions = Vec::new();

        for (subscription_id, receiver) in &self.subscriptions {
            for _ in 0..MAX_EVENTS_PER_SUBSCRIPTION_DRAIN {
                match receiver.try_recv() {
                    Ok(envelope) => messages.push(ServerMessage::Event {
                        subscription_id: subscription_id.clone(),
                        envelope,
                    }),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        closed_subscriptions.push(subscription_id.clone());
                        break;
                    }
                }
            }
        }

        for subscription_id in closed_subscriptions {
            self.subscriptions.remove(&subscription_id);
            messages.push(ServerMessage::SubscriptionClosed { subscription_id });
        }

        messages
    }

    fn handle_request(&mut self, request: ClientRequest) -> Result<ServerResult> {
        match request {
            ClientRequest::Hello => Ok(ServerResult::Hello {
                protocol_version: PROTOCOL_VERSION.to_string(),
            }),
            ClientRequest::ListSessions => {
                let session_ids = self.api.list_sessions()?;
                Ok(ServerResult::SessionIds { session_ids })
            }
            ClientRequest::StartSession { request } => {
                let session_id = self.api.start_session(request)?;
                Ok(ServerResult::SessionId { session_id })
            }
            ClientRequest::AttachSession { request } => {
                let response = self.api.attach_session(request)?;
                Ok(ServerResult::AttachSession { response })
            }
            ClientRequest::SubscribeSessionEvents { request } => {
                let subscription_id = self.subscribe_session_events(request)?;
                Ok(ServerResult::Subscribed { subscription_id })
            }
            ClientRequest::AcquireInputLease { request } => {
                let change = self.api.acquire_input_lease(request)?;
                Ok(ServerResult::LeaseChange { change })
            }
            ClientRequest::ReleaseInputLease {
                session_id,
                client_id,
            } => {
                let change = self.api.release_input_lease(session_id, client_id)?;
                Ok(ServerResult::LeaseChange { change })
            }
            ClientRequest::WriteInput { request } => {
                self.api.write_input(request)?;
                Ok(ServerResult::Unit)
            }
            ClientRequest::ResizeSession { request } => {
                let snapshot = self.api.resize_session(request)?;
                Ok(ServerResult::SessionSnapshot { snapshot })
            }
            ClientRequest::RestoreSession { request } => {
                let snapshot = self.api.restore_session(request)?;
                Ok(ServerResult::SessionSnapshot { snapshot })
            }
            ClientRequest::SnapshotSession { session_id } => {
                let snapshot = self.api.snapshot_session(session_id)?;
                Ok(ServerResult::SessionSnapshot { snapshot })
            }
            ClientRequest::StyledRows { request } => {
                let response = self.api.styled_rows(request)?;
                Ok(ServerResult::StyledRows { response })
            }
            ClientRequest::ShutdownSession { session_id } => {
                let completed = self.api.shutdown_session(session_id)?;
                Ok(ServerResult::CompletedSession { completed })
            }
        }
    }

    fn subscribe_session_events(
        &mut self,
        request: SubscribeSessionEventsRequest,
    ) -> Result<SubscriptionId> {
        let receiver = self.api.subscribe_session_events_from(request)?;
        let subscription_id = self.next_subscription_id();
        self.subscriptions.insert(subscription_id.clone(), receiver);
        Ok(subscription_id)
    }

    fn next_subscription_id(&mut self) -> SubscriptionId {
        let subscription_id = SubscriptionId::new(format!("sub-{}", self.next_subscription_id))
            .expect("generated subscription id must be valid");
        self.next_subscription_id += 1;
        subscription_id
    }
}

fn request_id_from_value(value: &Value) -> Option<Value> {
    value.get("id").filter(|id| !id.is_null()).cloned()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientMessage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    #[serde(flatten)]
    pub request: ClientRequest,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientRequest {
    Hello,
    ListSessions,
    StartSession {
        request: StartSessionRequest,
    },
    AttachSession {
        request: AttachSessionRequest,
    },
    SubscribeSessionEvents {
        request: SubscribeSessionEventsRequest,
    },
    AcquireInputLease {
        request: InputLeaseRequest,
    },
    ReleaseInputLease {
        session_id: SessionId,
        client_id: ClientId,
    },
    WriteInput {
        request: WriteInputRequest,
    },
    ResizeSession {
        request: ResizeSessionRequest,
    },
    RestoreSession {
        request: RestoreSessionRequest,
    },
    SnapshotSession {
        session_id: SessionId,
    },
    StyledRows {
        request: StyledRowsRequest,
    },
    ShutdownSession {
        session_id: SessionId,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Response {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<Value>,
        result: ServerResult,
    },
    Error {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<Value>,
        error: ProtocolError,
    },
    Event {
        subscription_id: SubscriptionId,
        envelope: SessionEventEnvelope,
    },
    SubscriptionClosed {
        subscription_id: SubscriptionId,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum ServerResult {
    Unit,
    Hello { protocol_version: String },
    SessionIds { session_ids: Vec<SessionId> },
    SessionId { session_id: SessionId },
    AttachSession { response: AttachSessionResponse },
    Subscribed { subscription_id: SubscriptionId },
    LeaseChange { change: LeaseChange },
    SessionSnapshot { snapshot: SessionSnapshot },
    StyledRows { response: StyledRowsResponse },
    CompletedSession { completed: CompletedSession },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
}

impl ProtocolError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

fn serialize_server_message(message: &ServerMessage) -> String {
    serde_json::to_string(message).unwrap_or_else(|error| {
        serialize_fallback_error(format!("serializing WebSocket response: {error}"))
    })
}

fn serialize_fallback_error(message: String) -> String {
    let escaped =
        serde_json::to_string(&message).unwrap_or_else(|_| "\"serialization failed\"".to_string());
    format!(
        "{{\"type\":\"error\",\"error\":{{\"code\":\"serialization_failed\",\"message\":{escaped}}}}}"
    )
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};

    use anyhow::{Result, bail};
    use argus_core::session::{
        AttachMode, InputLeaseState, SessionEvent, SessionSize, StyledRow, TerminalCursor,
    };
    use serde_json::json;

    use super::*;

    #[test]
    fn hello_reports_protocol_version() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());

        let response = connection.handle_message(ClientMessage {
            id: Some(json!(1)),
            request: ClientRequest::Hello,
        });

        assert_eq!(
            response,
            ServerMessage::Response {
                id: Some(json!(1)),
                result: ServerResult::Hello {
                    protocol_version: PROTOCOL_VERSION.to_string(),
                },
            }
        );
    }

    #[test]
    fn list_sessions_routes_to_session_api() {
        let api = FakeSessionApi::default();
        api.sessions
            .lock()
            .unwrap()
            .push(SessionId::new("session-1").unwrap());
        let mut connection = WebSocketSessionConnection::new(api);

        let response = connection.handle_text_message(r#"{"id":"req-1","type":"list_sessions"}"#);

        let decoded: ServerMessage = serde_json::from_str(&response).unwrap();
        assert_eq!(
            decoded,
            ServerMessage::Response {
                id: Some(json!("req-1")),
                result: ServerResult::SessionIds {
                    session_ids: vec![SessionId::new("session-1").unwrap()],
                },
            }
        );
    }

    #[test]
    fn write_input_preserves_client_bytes() {
        let api = FakeSessionApi::default();
        let written = api.written.clone();
        let mut connection = WebSocketSessionConnection::new(api);
        let request = WriteInputRequest {
            session_id: SessionId::new("session-1").unwrap(),
            client_id: ClientId::new("client-1").unwrap(),
            bytes: b"echo hi\n".to_vec(),
        };

        let response = connection.handle_message(ClientMessage {
            id: Some(json!(2)),
            request: ClientRequest::WriteInput {
                request: request.clone(),
            },
        });

        assert_eq!(
            response,
            ServerMessage::Response {
                id: Some(json!(2)),
                result: ServerResult::Unit,
            }
        );
        assert_eq!(*written.lock().unwrap(), vec![request]);
    }

    #[test]
    fn subscribe_drains_events_and_reports_closed_subscription() {
        let api = FakeSessionApi::default();
        let (tx, rx) = mpsc::channel();
        api.next_subscription.lock().unwrap().replace(rx);
        let mut connection = WebSocketSessionConnection::new(api);

        let response = connection.handle_message(ClientMessage {
            id: Some(json!("subscribe")),
            request: ClientRequest::SubscribeSessionEvents {
                request: SubscribeSessionEventsRequest {
                    session_id: SessionId::new("session-1").unwrap(),
                    after_event_seq: Some(4),
                },
            },
        });

        assert_eq!(
            response,
            ServerMessage::Response {
                id: Some(json!("subscribe")),
                result: ServerResult::Subscribed {
                    subscription_id: SubscriptionId::new("sub-1").unwrap(),
                },
            }
        );

        let envelope = SessionEventEnvelope {
            event_seq: 5,
            event: SessionEvent::Output {
                session_id: SessionId::new("session-1").unwrap(),
                output_seq: 10,
                bytes: b"data".to_vec(),
            },
        };
        tx.send(envelope.clone()).unwrap();
        drop(tx);

        assert_eq!(
            connection.drain_events(),
            vec![
                ServerMessage::Event {
                    subscription_id: SubscriptionId::new("sub-1").unwrap(),
                    envelope,
                },
                ServerMessage::SubscriptionClosed {
                    subscription_id: SubscriptionId::new("sub-1").unwrap(),
                },
            ]
        );
        assert!(connection.drain_events().is_empty());
    }

    #[test]
    fn drain_events_caps_each_subscription_per_call() {
        let api = FakeSessionApi::default();
        let (tx, rx) = mpsc::channel();
        api.next_subscription.lock().unwrap().replace(rx);
        let mut connection = WebSocketSessionConnection::new(api);

        let response = connection.handle_message(ClientMessage {
            id: None,
            request: ClientRequest::SubscribeSessionEvents {
                request: SubscribeSessionEventsRequest {
                    session_id: SessionId::new("session-1").unwrap(),
                    after_event_seq: None,
                },
            },
        });
        assert!(matches!(response, ServerMessage::Response { .. }));

        for event_seq in 1..=MAX_EVENTS_PER_SUBSCRIPTION_DRAIN + 1 {
            tx.send(test_output_event(event_seq as u64)).unwrap();
        }
        drop(tx);

        let first_drain = connection.drain_events();
        assert_eq!(first_drain.len(), MAX_EVENTS_PER_SUBSCRIPTION_DRAIN);
        assert!(first_drain.iter().all(|message| {
            matches!(
                message,
                ServerMessage::Event {
                    subscription_id,
                    ..
                } if subscription_id == &SubscriptionId::new("sub-1").unwrap()
            )
        }));

        let second_drain = connection.drain_events();
        assert_eq!(
            second_drain,
            vec![
                ServerMessage::Event {
                    subscription_id: SubscriptionId::new("sub-1").unwrap(),
                    envelope: test_output_event((MAX_EVENTS_PER_SUBSCRIPTION_DRAIN + 1) as u64),
                },
                ServerMessage::SubscriptionClosed {
                    subscription_id: SubscriptionId::new("sub-1").unwrap(),
                },
            ]
        );
    }

    #[test]
    fn invalid_json_returns_protocol_error() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());

        let response = connection.handle_text_message("{");

        let decoded: ServerMessage = serde_json::from_str(&response).unwrap();
        match decoded {
            ServerMessage::Error { id: None, error } => {
                assert_eq!(error.code, "invalid_json");
                assert!(error.message.contains("EOF"));
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn invalid_request_preserves_request_id() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());

        let response = connection.handle_text_message(r#"{"id":"req-1","type":"unknown_request"}"#);

        let decoded: ServerMessage = serde_json::from_str(&response).unwrap();
        match decoded {
            ServerMessage::Error {
                id: Some(id),
                error,
            } => {
                assert_eq!(id, json!("req-1"));
                assert_eq!(error.code, "invalid_request");
                assert!(error.message.contains("unknown_request"));
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[derive(Default)]
    struct FakeSessionApi {
        sessions: Mutex<Vec<SessionId>>,
        written: Arc<Mutex<Vec<WriteInputRequest>>>,
        next_subscription: Arc<Mutex<Option<SessionEventReceiver>>>,
    }

    impl SessionApi for FakeSessionApi {
        fn list_sessions(&self) -> Result<Vec<SessionId>> {
            Ok(self.sessions.lock().unwrap().clone())
        }

        fn start_session(&self, _request: StartSessionRequest) -> Result<SessionId> {
            Ok(SessionId::new("started").unwrap())
        }

        fn attach_session(&self, _request: AttachSessionRequest) -> Result<AttachSessionResponse> {
            Ok(AttachSessionResponse {
                snapshot: test_snapshot(),
                lease: InputLeaseState::default(),
            })
        }

        fn subscribe_session_events(&self, session_id: SessionId) -> Result<SessionEventReceiver> {
            self.subscribe_session_events_from(SubscribeSessionEventsRequest {
                session_id,
                after_event_seq: None,
            })
        }

        fn subscribe_session_events_from(
            &self,
            _request: SubscribeSessionEventsRequest,
        ) -> Result<SessionEventReceiver> {
            self.next_subscription
                .lock()
                .unwrap()
                .take()
                .ok_or_else(|| anyhow::anyhow!("no subscription receiver configured"))
        }

        fn acquire_input_lease(&self, request: InputLeaseRequest) -> Result<LeaseChange> {
            let mut lease = InputLeaseState::default();
            Ok(lease.acquire(request.client_id, request.kind))
        }

        fn release_input_lease(
            &self,
            session_id: SessionId,
            client_id: ClientId,
        ) -> Result<LeaseChange> {
            let _ = session_id;
            let mut lease = InputLeaseState::default();
            lease.acquire(
                client_id.clone(),
                argus_core::session::InputControllerKind::Interactive,
            );
            lease
                .release(&client_id)
                .ok_or_else(|| anyhow::anyhow!("lease was not held"))
        }

        fn write_input(&self, request: WriteInputRequest) -> Result<()> {
            self.written.lock().unwrap().push(request);
            Ok(())
        }

        fn resize_session(&self, _request: ResizeSessionRequest) -> Result<SessionSnapshot> {
            Ok(test_snapshot())
        }

        fn restore_session(&self, _request: RestoreSessionRequest) -> Result<SessionSnapshot> {
            Ok(test_snapshot())
        }

        fn snapshot_session(&self, _session_id: SessionId) -> Result<SessionSnapshot> {
            Ok(test_snapshot())
        }

        fn styled_rows(&self, request: StyledRowsRequest) -> Result<StyledRowsResponse> {
            if request.end < request.start {
                bail!("invalid styled row range");
            }
            Ok(StyledRowsResponse {
                output_seq: 1,
                start: request.start,
                rows: Vec::new(),
            })
        }

        fn shutdown_session(&self, _session_id: SessionId) -> Result<CompletedSession> {
            Ok(CompletedSession {
                output_seq: 1,
                bytes_logged: 0,
                visible_rows: Vec::new(),
            })
        }
    }

    fn test_snapshot() -> SessionSnapshot {
        SessionSnapshot {
            output_seq: 1,
            bytes_logged: 0,
            size: SessionSize::default(),
            visible_rows: Vec::new(),
            styled_rows_start: 0,
            styled_rows: Vec::<StyledRow>::new(),
            cursor: TerminalCursor {
                row: 0,
                col: 0,
                visible: false,
            },
            current_working_directory: None,
            context: None,
            bracketed_paste_enabled: false,
            exited: false,
        }
    }

    fn test_output_event(event_seq: u64) -> SessionEventEnvelope {
        SessionEventEnvelope {
            event_seq,
            event: SessionEvent::Output {
                session_id: SessionId::new("session-1").unwrap(),
                output_seq: event_seq,
                bytes: vec![b'x'],
            },
        }
    }

    #[test]
    fn attach_request_can_use_interactive_controller_mode() {
        let request = ClientRequest::AttachSession {
            request: AttachSessionRequest {
                session_id: SessionId::new("session-1").unwrap(),
                client_id: ClientId::new("client-1").unwrap(),
                mode: AttachMode::InteractiveController,
            },
        };

        let encoded = serde_json::to_value(request).unwrap();

        assert_eq!(
            encoded,
            json!({
                "type": "attach_session",
                "request": {
                    "session_id": "session-1",
                    "client_id": "client-1",
                    "mode": "InteractiveController",
                },
            })
        );
    }
}
