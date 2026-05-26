use std::collections::HashMap;
use std::sync::mpsc::TryRecvError;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use triage_core::session::{
    AttachSessionRequest, AttachSessionResponse, ClientId, CompletedSession, InputLeaseRequest,
    LeaseChange, ResizeSessionRequest, RestoreSessionRequest, SessionApi, SessionEventEnvelope,
    SessionEventReceiver, SessionId, SessionSnapshot, StartSessionRequest, StyledRowsRequest,
    StyledRowsResponse, SubscribeSessionEventsRequest, WriteInputRequest,
};

pub mod flatbuffers_proto;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolFormat {
    Json,
    Flatbuffers,
}

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

pub trait WebSocketAuthenticator {
    fn require_pairing(&self) -> bool;
    fn authenticate(&self, client_id: &ClientId, token: &str) -> Result<bool>;
    fn pair(&self, code: &str, client_id: &ClientId) -> Result<String>;
}

impl<T: WebSocketAuthenticator + ?Sized> WebSocketAuthenticator for std::sync::Arc<T> {
    fn require_pairing(&self) -> bool {
        (**self).require_pairing()
    }
    fn authenticate(&self, client_id: &ClientId, token: &str) -> Result<bool> {
        (**self).authenticate(client_id, token)
    }
    fn pair(&self, code: &str, client_id: &ClientId) -> Result<String> {
        (**self).pair(code, client_id)
    }
}
#[derive(Debug)]
pub enum TransportError {
    Unauthorized,
    RequestFailed(String),
}

impl std::fmt::Display for TransportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TransportError::Unauthorized => write!(f, "unauthorized"),
            TransportError::RequestFailed(msg) => write!(f, "{}", msg),
        }
    }
}

impl std::error::Error for TransportError {}

#[derive(Debug, Clone, Copy)]
pub struct NoopAuthenticator;

impl WebSocketAuthenticator for NoopAuthenticator {
    fn require_pairing(&self) -> bool {
        false
    }
    fn authenticate(&self, _client_id: &ClientId, _token: &str) -> Result<bool> {
        Ok(true)
    }
    fn pair(&self, _code: &str, _client_id: &ClientId) -> Result<String> {
        Ok("noop-token".to_string())
    }
}

#[derive(Debug)]
pub struct WebSocketSessionConnection<A, U = NoopAuthenticator> {
    api: A,
    authenticator: U,
    authenticated: bool,
    next_subscription_id: u64,
    subscriptions: HashMap<SubscriptionId, SessionEventReceiver>,
    pub format: ProtocolFormat,
}

impl<A: SessionApi> WebSocketSessionConnection<A, NoopAuthenticator> {
    pub fn new(api: A) -> Self {
        Self {
            api,
            authenticator: NoopAuthenticator,
            authenticated: false,
            next_subscription_id: 1,
            subscriptions: HashMap::new(),
            format: ProtocolFormat::Json,
        }
    }
}

impl<A: SessionApi, U: WebSocketAuthenticator> WebSocketSessionConnection<A, U> {
    pub fn with_authenticator(api: A, authenticator: U) -> Self {
        Self {
            api,
            authenticator,
            authenticated: false,
            next_subscription_id: 1,
            subscriptions: HashMap::new(),
            format: ProtocolFormat::Json,
        }
    }

    pub fn with_format(mut self, format: ProtocolFormat) -> Self {
        self.format = format;
        self
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

    pub fn handle_binary_message(&mut self, message: &[u8]) -> Vec<u8> {
        let response = match ::flatbuffers::root::<triage_core::generated::triage::generated::ClientMessage>(message) {
            Ok(fb_msg) => {
                let parsed = flatbuffers_proto::parse_client_message(fb_msg);
                self.handle_message(parsed)
            }
            Err(error) => ServerMessage::Error {
                id: None,
                error: ProtocolError::new("invalid_flatbuffer", error.to_string()),
            },
        };

        flatbuffers_proto::serialize_server_message(&response)
    }

    pub fn handle_message(&mut self, message: ClientMessage) -> ServerMessage {
        let id = message.id;
        match self.handle_request(message.request) {
            Ok(result) => ServerMessage::Response { id, result },
            Err(error) => {
                let code = if error
                    .downcast_ref::<TransportError>()
                    .is_some_and(|e| matches!(e, TransportError::Unauthorized))
                {
                    "unauthorized"
                } else {
                    "request_failed"
                };
                ServerMessage::Error {
                    id,
                    error: ProtocolError::new(code, error.to_string()),
                }
            }
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
        if self.authenticator.require_pairing() && !self.authenticated {
            match &request {
                ClientRequest::Hello { .. } | ClientRequest::Pair { .. } => {}
                _ => bail!(TransportError::Unauthorized),
            }
        }

        match request {
            ClientRequest::Hello { client_id, token } => {
                let authenticated = if self.authenticator.require_pairing() {
                    if let (Some(client_id), Some(token)) = (client_id, token) {
                        let ok = self.authenticator.authenticate(&client_id, &token)?;
                        self.authenticated = ok;
                        ok
                    } else {
                        self.authenticated = false;
                        false
                    }
                } else {
                    self.authenticated = true;
                    true
                };

                Ok(ServerResult::Hello {
                    protocol_version: PROTOCOL_VERSION.to_string(),
                    authenticated,
                })
            }
            ClientRequest::Pair { code, client_id } => {
                let token = self.authenticator.pair(&code, &client_id)?;
                self.authenticated = true;
                Ok(ServerResult::Paired { token })
            }
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
    Hello {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        client_id: Option<ClientId>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        token: Option<String>,
    },
    Pair {
        code: String,
        client_id: ClientId,
    },
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
    Hello {
        protocol_version: String,
        authenticated: bool,
    },
    Paired {
        token: String,
    },
    SessionIds {
        session_ids: Vec<SessionId>,
    },
    SessionId {
        session_id: SessionId,
    },
    AttachSession {
        response: AttachSessionResponse,
    },
    Subscribed {
        subscription_id: SubscriptionId,
    },
    LeaseChange {
        change: LeaseChange,
    },
    SessionSnapshot {
        snapshot: SessionSnapshot,
    },
    StyledRows {
        response: StyledRowsResponse,
    },
    CompletedSession {
        completed: CompletedSession,
    },
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
    use serde_json::json;
    use triage_core::session::{
        AttachMode, InputLeaseState, SessionEvent, SessionSize, StyledRow, TerminalCursor,
    };

    use super::*;

    #[test]
    fn hello_reports_protocol_version() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());

        let response = connection.handle_message(ClientMessage {
            id: Some(json!(1)),
            request: ClientRequest::Hello {
                client_id: None,
                token: None,
            },
        });

        assert_eq!(
            response,
            ServerMessage::Response {
                id: Some(json!(1)),
                result: ServerResult::Hello {
                    protocol_version: PROTOCOL_VERSION.to_string(),
                    authenticated: true,
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
                triage_core::session::InputControllerKind::Interactive,
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

    struct FakeAuthenticator {
        require_pairing: bool,
        pairing_code: String,
        paired_token: String,
        client_id: ClientId,
    }

    impl WebSocketAuthenticator for FakeAuthenticator {
        fn require_pairing(&self) -> bool {
            self.require_pairing
        }
        fn authenticate(&self, client_id: &ClientId, token: &str) -> Result<bool> {
            Ok(client_id == &self.client_id && token == self.paired_token)
        }
        fn pair(&self, code: &str, client_id: &ClientId) -> Result<String> {
            if code == self.pairing_code && client_id == &self.client_id {
                Ok(self.paired_token.clone())
            } else {
                anyhow::bail!("invalid_pairing_code")
            }
        }
    }

    #[test]
    fn unauthenticated_connection_blocks_session_requests() {
        let auth = FakeAuthenticator {
            require_pairing: true,
            pairing_code: "123456".to_string(),
            paired_token: "secret-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
        };
        let mut connection =
            WebSocketSessionConnection::with_authenticator(FakeSessionApi::default(), auth);

        let response = connection.handle_message(ClientMessage {
            id: Some(json!("1")),
            request: ClientRequest::ListSessions,
        });

        match response {
            ServerMessage::Error { id, error } => {
                assert_eq!(id, Some(json!("1")));
                assert_eq!(error.code, "unauthorized");
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn pairing_request_with_correct_pin_grants_access() {
        let auth = FakeAuthenticator {
            require_pairing: true,
            pairing_code: "123456".to_string(),
            paired_token: "secret-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
        };
        let mut connection =
            WebSocketSessionConnection::with_authenticator(FakeSessionApi::default(), auth);

        // 1. Send pair request
        let response = connection.handle_message(ClientMessage {
            id: Some(json!("pair-req")),
            request: ClientRequest::Pair {
                code: "123456".to_string(),
                client_id: ClientId::new("phone").unwrap(),
            },
        });

        match response {
            ServerMessage::Response { id, result } => {
                assert_eq!(id, Some(json!("pair-req")));
                assert_eq!(
                    result,
                    ServerResult::Paired {
                        token: "secret-token".to_string()
                    }
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }

        // 2. Verified that list sessions now succeeds
        let list_response = connection.handle_message(ClientMessage {
            id: Some(json!("list-req")),
            request: ClientRequest::ListSessions,
        });
        assert!(matches!(list_response, ServerMessage::Response { .. }));
    }

    #[test]
    fn hello_request_with_valid_token_grants_access() {
        let auth = FakeAuthenticator {
            require_pairing: true,
            pairing_code: "123456".to_string(),
            paired_token: "secret-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
        };
        let mut connection =
            WebSocketSessionConnection::with_authenticator(FakeSessionApi::default(), auth);

        // 1. Hello request with valid token
        let response = connection.handle_message(ClientMessage {
            id: Some(json!("hello-req")),
            request: ClientRequest::Hello {
                client_id: Some(ClientId::new("phone").unwrap()),
                token: Some("secret-token".to_string()),
            },
        });

        match response {
            ServerMessage::Response { id, result } => {
                assert_eq!(id, Some(json!("hello-req")));
                assert_eq!(
                    result,
                    ServerResult::Hello {
                        protocol_version: PROTOCOL_VERSION.to_string(),
                        authenticated: true,
                    }
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }

        // 2. List sessions now succeeds
        let list_response = connection.handle_message(ClientMessage {
            id: Some(json!("list-req")),
            request: ClientRequest::ListSessions,
        });
        assert!(matches!(list_response, ServerMessage::Response { .. }));
    }

    #[test]
    fn hello_request_with_invalid_token_returns_unauthenticated() {
        let auth = FakeAuthenticator {
            require_pairing: true,
            pairing_code: "123456".to_string(),
            paired_token: "secret-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
        };
        let mut connection =
            WebSocketSessionConnection::with_authenticator(FakeSessionApi::default(), auth);

        // 1. Hello request with invalid token
        let response = connection.handle_message(ClientMessage {
            id: Some(json!("hello-req")),
            request: ClientRequest::Hello {
                client_id: Some(ClientId::new("phone").unwrap()),
                token: Some("wrong-token".to_string()),
            },
        });

        match response {
            ServerMessage::Response { id, result } => {
                assert_eq!(id, Some(json!("hello-req")));
                assert_eq!(
                    result,
                    ServerResult::Hello {
                        protocol_version: PROTOCOL_VERSION.to_string(),
                        authenticated: false,
                    }
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }

        // 2. Verified that list sessions fails with unauthorized error
        let list_response = connection.handle_message(ClientMessage {
            id: Some(json!("list-req")),
            request: ClientRequest::ListSessions,
        });
        match list_response {
            ServerMessage::Error { id, error } => {
                assert_eq!(id, Some(json!("list-req")));
                assert_eq!(error.code, "unauthorized");
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }
}
