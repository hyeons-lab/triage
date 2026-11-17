use std::collections::{HashMap, VecDeque};
use std::net::SocketAddr;
use std::path::Path;
use std::sync::mpsc::{Receiver, TryRecvError};

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use triage_core::judge::SessionJudgePolicy;
use triage_core::session::{
    AttachSessionRequest, AttachSessionResponse, ClientId, CompletedSession,
    FetchTerminalRowsRequest, FetchTerminalRowsResponse, InputLeaseRequest, LeaseChange,
    PollTerminalSyncOutcome, ResizeSessionRequest, RestoreSessionRequest, SessionApi, SessionEvent,
    SessionEventEnvelope, SessionEventReceiver, SessionId, SessionSnapshot, StartSessionRequest,
    StyledRowsRequest, StyledRowsResponse, SubscribeSessionEventsRequest, SyncTerminalRequest,
    SyncTerminalResponse, TerminalSyncCursor, WriteInputRequest,
};

pub mod flatbuffers_proto;
pub use flatbuffers_proto::{
    ProtocolErrorBorrowed, ServerMessageBorrowed, ServerResultBorrowed, SessionEventBorrowed,
    parse_fb_server_message_borrowed,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolFormat {
    Json,
    Flatbuffers,
}

pub const PROTOCOL_VERSION: &str = "2026-05-20";
const MAX_EVENTS_PER_SUBSCRIPTION_DRAIN: usize = 256;
const MAX_IN_FLIGHT_SYNC_FRAMES: u64 = 2;

#[derive(Debug)]
struct TerminalSyncSubState {
    session_id: SessionId,
    cursor: TerminalSyncCursor,
    last_acked_frame_seq: u64,
    dirty: bool,
    retried_poll_err: bool,
    next_synth_event_seq: u64,
}

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
    fn pairing_challenge(&self, client_id: &ClientId) -> Result<PairingChallenge>;
    fn pair(&self, code: &str, client_id: &ClientId) -> Result<String>;
    /// Whether this daemon offers Tailscale-identity pairing (allowlist
    /// configured). Default denies.
    fn tailscale_pairing_available(&self) -> bool {
        false
    }
    /// Mint a pairing token for the peer at `peer` after verifying its
    /// tailnet identity. Default denies (fail closed).
    fn pair_via_tailscale(&self, _client_id: &ClientId, _peer: SocketAddr) -> Result<String> {
        bail!("Tailscale pairing is not configured on this daemon")
    }
}

impl<T: WebSocketAuthenticator + ?Sized> WebSocketAuthenticator for std::sync::Arc<T> {
    fn require_pairing(&self) -> bool {
        (**self).require_pairing()
    }
    fn authenticate(&self, client_id: &ClientId, token: &str) -> Result<bool> {
        (**self).authenticate(client_id, token)
    }
    fn pairing_challenge(&self, client_id: &ClientId) -> Result<PairingChallenge> {
        (**self).pairing_challenge(client_id)
    }
    fn pair(&self, code: &str, client_id: &ClientId) -> Result<String> {
        (**self).pair(code, client_id)
    }
    fn tailscale_pairing_available(&self) -> bool {
        (**self).tailscale_pairing_available()
    }
    fn pair_via_tailscale(&self, client_id: &ClientId, peer: SocketAddr) -> Result<String> {
        (**self).pair_via_tailscale(client_id, peer)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairingChallenge {
    pub device_code: String,
    pub expires_at: u64,
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
    fn pairing_challenge(&self, _client_id: &ClientId) -> Result<PairingChallenge> {
        Ok(PairingChallenge {
            device_code: "NOOPPAIR".to_string(),
            expires_at: 0,
        })
    }
    fn pair(&self, _code: &str, _client_id: &ClientId) -> Result<String> {
        Ok("noop-token".to_string())
    }
}

/// Live disk probe as `(free_bytes, total_bytes)`, defaulting to `(0, 0)`
/// when the platform cannot probe. One helper for every response carrying
/// disk stats so the defaulting rule cannot drift between handlers.
fn current_disk_bytes() -> (u64, u64) {
    match triage_core::disk::daemon_disk_stats() {
        Some(stats) => (stats.free_bytes, stats.total_bytes),
        None => (0, 0),
    }
}

/// Live host probe as `(cpu_percent, battery_percent, battery_state)`,
/// defaulting an absent battery to [`triage_core::host::BatteryState::Unknown`]
/// so `Hello` and `GetDaemonStats` share one mapping.
fn current_host_stats() -> (Option<u8>, Option<u8>, triage_core::host::BatteryState) {
    let host = triage_core::host::daemon_host_stats();
    (
        host.cpu_percent,
        host.battery.map(|battery| battery.percent),
        host.battery
            .map_or(triage_core::host::BatteryState::Unknown, |battery| {
                battery.state
            }),
    )
}

#[derive(Debug)]
pub struct WebSocketSessionConnection<A, U = NoopAuthenticator> {
    api: A,
    authenticator: U,
    authenticated: bool,
    next_subscription_id: u64,
    subscriptions: HashMap<SubscriptionId, SessionEventReceiver>,
    terminal_sync_subs: HashMap<SubscriptionId, TerminalSyncSubState>,
    session_to_sync_sub: HashMap<SessionId, SubscriptionId>,
    pending_events: VecDeque<ServerMessage>,
    /// Connection-wide push channel, independent of session subscriptions. The
    /// daemon broadcasts `ServerMessage`s (e.g. snippet updates) here so the
    /// client learns about sessions it never attached to.
    global_rx: Option<Receiver<ServerMessage>>,
    pub format: ProtocolFormat,
    /// Remote peer of this connection, set by the accept loop. Required for
    /// Tailscale-identity pairing (the daemon whoises the caller); absent in
    /// contexts without a real peer (unit tests), which fail closed.
    peer_addr: Option<SocketAddr>,
}

impl<A: SessionApi> WebSocketSessionConnection<A, NoopAuthenticator> {
    pub fn new(api: A) -> Self {
        Self {
            api,
            authenticator: NoopAuthenticator,
            authenticated: false,
            next_subscription_id: 1,
            subscriptions: HashMap::new(),
            terminal_sync_subs: HashMap::new(),
            session_to_sync_sub: HashMap::new(),
            pending_events: VecDeque::new(),
            global_rx: None,
            format: ProtocolFormat::Flatbuffers,
            peer_addr: None,
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
            terminal_sync_subs: HashMap::new(),
            session_to_sync_sub: HashMap::new(),
            pending_events: VecDeque::new(),
            global_rx: None,
            format: ProtocolFormat::Flatbuffers,
            peer_addr: None,
        }
    }

    /// Records the connection's remote peer for Tailscale-identity pairing.
    pub fn with_peer_addr(mut self, peer_addr: SocketAddr) -> Self {
        self.peer_addr = Some(peer_addr);
        self
    }

    pub fn with_format(mut self, format: ProtocolFormat) -> Self {
        self.format = format;
        self
    }

    /// Attaches a connection-wide push receiver. Messages sent here are drained
    /// alongside subscription events and forwarded to the client.
    pub fn with_global_receiver(mut self, rx: Receiver<ServerMessage>) -> Self {
        self.global_rx = Some(rx);
        self
    }

    /// Sets the connection-wide push receiver after authentication completes.
    pub fn set_global_receiver(&mut self, rx: Receiver<ServerMessage>) {
        self.global_rx = Some(rx);
    }

    pub fn has_global_receiver(&self) -> bool {
        self.global_rx.is_some()
    }

    pub fn is_authenticated(&self) -> bool {
        !self.authenticator.require_pairing() || self.authenticated
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

    /// Handles a JSON text message, returning `None` for fire-and-forget
    /// `AckTerminalSync` frames that omit `id` and succeed cleanly.
    pub fn handle_text_message_optional(&mut self, message: &str) -> Option<String> {
        let response = match serde_json::from_str::<Value>(message) {
            Ok(value) => {
                let id = request_id_from_value(&value);
                match serde_json::from_value::<ClientMessage>(value) {
                    Ok(parsed) => {
                        let is_fire_and_forget_ack = is_absent_id(&parsed.id)
                            && matches!(parsed.request, ClientRequest::AckTerminalSync { .. });
                        let resp = self.handle_message(parsed);
                        if is_fire_and_forget_ack && matches!(resp, ServerMessage::Response { .. })
                        {
                            return None;
                        }
                        resp
                    }
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

        Some(serialize_server_message(&response))
    }

    pub fn handle_binary_message(&mut self, message: &[u8]) -> Vec<u8> {
        let response = match ::flatbuffers::root::<
            triage_core::generated::triage::generated::ClientMessage,
        >(message)
        {
            Ok(fb_msg) => {
                let id = fb_msg
                    .id()
                    .filter(|s| !s.is_empty())
                    .map(|s| Value::String(s.to_string()));
                match flatbuffers_proto::parse_client_message(fb_msg) {
                    Ok(parsed) => self.handle_message(parsed),
                    Err(error) => ServerMessage::Error { id, error },
                }
            }
            Err(error) => ServerMessage::Error {
                id: None,
                error: ProtocolError::new("invalid_flatbuffer", error.to_string()),
            },
        };

        flatbuffers_proto::serialize_server_message(&response)
    }

    /// Handles a FlatBuffers binary message, returning `None` for fire-and-forget
    /// `AckTerminalSync` frames that omit `id` and succeed cleanly.
    pub fn handle_binary_message_optional(&mut self, message: &[u8]) -> Option<Vec<u8>> {
        let response = match ::flatbuffers::root::<
            triage_core::generated::triage::generated::ClientMessage,
        >(message)
        {
            Ok(fb_msg) => {
                let id = fb_msg
                    .id()
                    .filter(|s| !s.is_empty())
                    .map(|s| Value::String(s.to_string()));
                match flatbuffers_proto::parse_client_message(fb_msg) {
                    Ok(parsed) => {
                        let is_fire_and_forget_ack = is_absent_id(&parsed.id)
                            && matches!(parsed.request, ClientRequest::AckTerminalSync { .. });
                        let resp = self.handle_message(parsed);
                        if is_fire_and_forget_ack && matches!(resp, ServerMessage::Response { .. })
                        {
                            return None;
                        }
                        resp
                    }
                    Err(error) => ServerMessage::Error { id, error },
                }
            }
            Err(error) => ServerMessage::Error {
                id: None,
                error: ProtocolError::new("invalid_flatbuffer", error.to_string()),
            },
        };

        Some(flatbuffers_proto::serialize_server_message(&response))
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
        if !self.is_authenticated() {
            return Vec::new();
        }
        let mut messages = Vec::new();
        while let Some(msg) = self.pending_events.pop_front() {
            messages.push(msg);
        }
        let mut closed_subscriptions = Vec::new();

        {
            let Self {
                api,
                subscriptions,
                terminal_sync_subs,
                ..
            } = self;

            for (subscription_id, receiver) in subscriptions.iter() {
                if let Some(sync_state) = terminal_sync_subs.get_mut(subscription_id) {
                    let mut saw_disconnect = false;
                    for _ in 0..MAX_EVENTS_PER_SUBSCRIPTION_DRAIN {
                        match receiver.try_recv() {
                            Ok(mut envelope) => match envelope.event {
                                SessionEvent::Output { .. } => {
                                    sync_state.dirty = true;
                                    sync_state.retried_poll_err = false;
                                    sync_state.next_synth_event_seq =
                                        sync_state.next_synth_event_seq.max(envelope.event_seq);
                                }
                                SessionEvent::ResyncRequired {
                                    session_id,
                                    mut snapshot,
                                    ..
                                } => {
                                    sync_state.dirty = true;
                                    sync_state.retried_poll_err = false;
                                    let resync_exited = snapshot.exited;
                                    let resync_output_seq = snapshot.output_seq;
                                    let resync_bytes_logged = snapshot.bytes_logged;
                                    snapshot.visible_rows.clear();
                                    snapshot.styled_rows.clear();
                                    snapshot.raw_output.clear();
                                    snapshot.raw_output_prefix.clear();
                                    if resync_exited {
                                        if let Ok(PollTerminalSyncOutcome::Frame(frame)) = api
                                            .poll_terminal_sync(
                                                sync_state.session_id.clone(),
                                                &mut sync_state.cursor,
                                                false,
                                            )
                                        {
                                            let seq = alloc_sync_event_seq(
                                                &mut sync_state.next_synth_event_seq,
                                                envelope.event_seq,
                                            );
                                            messages.push(ServerMessage::Event {
                                                subscription_id: subscription_id.clone(),
                                                envelope: SessionEventEnvelope {
                                                    event_seq: seq,
                                                    event: SessionEvent::TerminalSync {
                                                        session_id: sync_state.session_id.clone(),
                                                        frame,
                                                    },
                                                },
                                            });
                                        }
                                        sync_state.dirty = false;
                                    }
                                    let snap_seq = alloc_sync_event_seq(
                                        &mut sync_state.next_synth_event_seq,
                                        envelope.event_seq,
                                    );
                                    messages.push(ServerMessage::Event {
                                        subscription_id: subscription_id.clone(),
                                        envelope: SessionEventEnvelope {
                                            event_seq: snap_seq,
                                            event: SessionEvent::Snapshot {
                                                session_id: session_id.clone(),
                                                snapshot,
                                            },
                                        },
                                    });
                                    if resync_exited {
                                        let exit_seq = alloc_sync_event_seq(
                                            &mut sync_state.next_synth_event_seq,
                                            envelope.event_seq,
                                        );
                                        messages.push(ServerMessage::Event {
                                            subscription_id: subscription_id.clone(),
                                            envelope: SessionEventEnvelope {
                                                event_seq: exit_seq,
                                                event: SessionEvent::Exited {
                                                    session_id,
                                                    completed: CompletedSession {
                                                        output_seq: resync_output_seq,
                                                        bytes_logged: resync_bytes_logged,
                                                        visible_rows: Vec::new(),
                                                    },
                                                },
                                            },
                                        });
                                    }
                                }
                                SessionEvent::Snapshot {
                                    session_id,
                                    mut snapshot,
                                } => {
                                    sync_state.dirty = true;
                                    sync_state.retried_poll_err = false;
                                    snapshot.visible_rows.clear();
                                    snapshot.styled_rows.clear();
                                    snapshot.raw_output.clear();
                                    snapshot.raw_output_prefix.clear();
                                    let snap_seq = alloc_sync_event_seq(
                                        &mut sync_state.next_synth_event_seq,
                                        envelope.event_seq,
                                    );
                                    messages.push(ServerMessage::Event {
                                        subscription_id: subscription_id.clone(),
                                        envelope: SessionEventEnvelope {
                                            event_seq: snap_seq,
                                            event: SessionEvent::Snapshot {
                                                session_id,
                                                snapshot,
                                            },
                                        },
                                    });
                                }
                                SessionEvent::Exited { .. } => {
                                    if sync_state.dirty {
                                        if let Ok(PollTerminalSyncOutcome::Frame(frame)) = api
                                            .poll_terminal_sync(
                                                sync_state.session_id.clone(),
                                                &mut sync_state.cursor,
                                                false,
                                            )
                                        {
                                            let seq = alloc_sync_event_seq(
                                                &mut sync_state.next_synth_event_seq,
                                                envelope.event_seq,
                                            );
                                            messages.push(ServerMessage::Event {
                                                subscription_id: subscription_id.clone(),
                                                envelope: SessionEventEnvelope {
                                                    event_seq: seq,
                                                    event: SessionEvent::TerminalSync {
                                                        session_id: sync_state.session_id.clone(),
                                                        frame,
                                                    },
                                                },
                                            });
                                        }
                                        sync_state.dirty = false;
                                    }
                                    envelope.event_seq = alloc_sync_event_seq(
                                        &mut sync_state.next_synth_event_seq,
                                        envelope.event_seq,
                                    );
                                    messages.push(ServerMessage::Event {
                                        subscription_id: subscription_id.clone(),
                                        envelope,
                                    });
                                }
                                SessionEvent::LeaseChanged { .. }
                                | SessionEvent::TerminalSync { .. } => {
                                    envelope.event_seq = alloc_sync_event_seq(
                                        &mut sync_state.next_synth_event_seq,
                                        envelope.event_seq,
                                    );
                                    messages.push(ServerMessage::Event {
                                        subscription_id: subscription_id.clone(),
                                        envelope,
                                    });
                                }
                            },
                            Err(TryRecvError::Empty) => break,
                            Err(TryRecvError::Disconnected) => {
                                saw_disconnect = true;
                                closed_subscriptions.push(subscription_id.clone());
                                break;
                            }
                        }
                    }

                    let in_flight = sync_state
                        .cursor
                        .next_frame_seq
                        .saturating_sub(sync_state.last_acked_frame_seq);
                    if sync_state.dirty && (saw_disconnect || in_flight < MAX_IN_FLIGHT_SYNC_FRAMES)
                    {
                        match api.poll_terminal_sync(
                            sync_state.session_id.clone(),
                            &mut sync_state.cursor,
                            false,
                        ) {
                            Ok(PollTerminalSyncOutcome::Frame(frame)) => {
                                sync_state.dirty = false;
                                sync_state.retried_poll_err = false;
                                let seq =
                                    alloc_sync_event_seq(&mut sync_state.next_synth_event_seq, 1);
                                messages.push(ServerMessage::Event {
                                    subscription_id: subscription_id.clone(),
                                    envelope: SessionEventEnvelope {
                                        event_seq: seq,
                                        event: SessionEvent::TerminalSync {
                                            session_id: sync_state.session_id.clone(),
                                            frame,
                                        },
                                    },
                                });
                            }
                            Ok(PollTerminalSyncOutcome::Idle) => {
                                sync_state.dirty = false;
                                sync_state.retried_poll_err = false;
                            }
                            Err(_) => {
                                if !saw_disconnect && !sync_state.retried_poll_err {
                                    sync_state.retried_poll_err = true;
                                } else {
                                    sync_state.dirty = false;
                                    sync_state.retried_poll_err = false;
                                }
                            }
                            Ok(PollTerminalSyncOutcome::HoldForSynchronizedUpdate) => {}
                        }
                    }
                } else {
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
            }
        }

        for subscription_id in closed_subscriptions {
            self.subscriptions.remove(&subscription_id);
            if let Some(removed) = self.terminal_sync_subs.remove(&subscription_id)
                && self.session_to_sync_sub.get(&removed.session_id) == Some(&subscription_id)
            {
                self.session_to_sync_sub.remove(&removed.session_id);
            }
            messages.push(ServerMessage::SubscriptionClosed { subscription_id });
        }

        // Connection-wide pushes (snippet updates, etc.). A disconnected sender
        // just means the daemon dropped this connection's slot; drop the channel.
        // Snippets derive from session output, so an unauthenticated client must
        // not receive them when pairing is required — gate draining behind auth.
        let may_receive_global = !self.authenticator.require_pairing() || self.authenticated;
        if let (true, Some(rx)) = (may_receive_global, &self.global_rx) {
            let mut disconnected = false;
            for _ in 0..MAX_EVENTS_PER_SUBSCRIPTION_DRAIN {
                match rx.try_recv() {
                    Ok(message) => messages.push(message),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        disconnected = true;
                        break;
                    }
                }
            }
            if disconnected {
                self.global_rx = None;
            }
        }

        messages
    }

    fn handle_request(&mut self, request: ClientRequest) -> Result<ServerResult> {
        if self.authenticator.require_pairing() && !self.authenticated {
            match &request {
                ClientRequest::Hello { .. }
                | ClientRequest::PairingChallenge { .. }
                | ClientRequest::Pair { .. }
                | ClientRequest::PairViaTailscale { .. } => {}
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
                if !authenticated {
                    self.subscriptions.clear();
                    self.terminal_sync_subs.clear();
                    self.session_to_sync_sub.clear();
                    self.pending_events.clear();
                }

                let update = self.api.server_update_info();
                let (disk_free_bytes, disk_total_bytes) = current_disk_bytes();
                let (cpu_percent, battery_percent, battery_state) = current_host_stats();
                Ok(ServerResult::Hello {
                    protocol_version: PROTOCOL_VERSION.to_string(),
                    authenticated,
                    server_version: update.server_version,
                    update_available: update.update_available,
                    latest_version: update.latest_version,
                    disk_free_bytes,
                    disk_total_bytes,
                    tailscale_pairing_available: self.authenticator.tailscale_pairing_available(),
                    cpu_percent,
                    battery_percent,
                    battery_state,
                })
            }
            ClientRequest::PairingChallenge { client_id } => {
                let challenge = self.authenticator.pairing_challenge(&client_id)?;
                Ok(ServerResult::PairingChallenge {
                    device_code: challenge.device_code,
                    expires_at: challenge.expires_at,
                })
            }
            ClientRequest::Pair { code, client_id } => {
                let token = self.authenticator.pair(&code, &client_id)?;
                self.authenticated = true;
                Ok(ServerResult::Paired { token })
            }
            ClientRequest::PairViaTailscale { client_id } => {
                let Some(peer) = self.peer_addr else {
                    bail!("Tailscale pairing requires a peer address");
                };
                let token = self.authenticator.pair_via_tailscale(&client_id, peer)?;
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
            ClientRequest::ListSessionSnippets => {
                let entries = self
                    .api
                    .list_session_snippets()?
                    .into_iter()
                    .map(|(session_id, snippet, detail)| SessionSnippetEntry {
                        session_id,
                        snippet,
                        detail,
                    })
                    .collect();
                Ok(ServerResult::SessionSnippets { entries })
            }
            ClientRequest::ListSessionContexts => {
                let entries = self
                    .api
                    .list_session_contexts()?
                    .into_iter()
                    .map(|row| {
                        let to_string = |path: &Path| path.to_string_lossy().into_owned();
                        // Convert the cached `SessionContext` paths to strings the
                        // same way the `SessionContextUpdated` push does; the bulk
                        // fetch carries no live cwd (the cached context holds only
                        // the git fields), so `current_working_directory` is None.
                        let (repository_root, worktree_root, branch) = match &row.context {
                            Some(context) => (
                                context.repository_root.as_deref().map(to_string),
                                context.worktree_root.as_deref().map(to_string),
                                context.branch_name().map(str::to_string),
                            ),
                            None => (None, None, None),
                        };
                        SessionContextEntry {
                            session_id: row.session_id,
                            current_working_directory: None,
                            repository_root,
                            worktree_root,
                            branch,
                            last_activity_ms: row.last_activity_ms,
                            last_input_ms: row.last_input_ms,
                        }
                    })
                    .collect();
                Ok(ServerResult::SessionContexts { entries })
            }
            ClientRequest::GetSessionJudgePolicy { session_id } => {
                let policy = self.api.session_judge_policy(session_id.clone())?;
                Ok(ServerResult::SessionJudgePolicy { session_id, policy })
            }
            ClientRequest::SetSessionJudgePolicy {
                session_id,
                enabled,
            } => {
                let policy = self
                    .api
                    .set_session_judge_policy(session_id.clone(), enabled)?;
                Ok(ServerResult::SessionJudgePolicy { session_id, policy })
            }
            ClientRequest::ListSessionJudgePolicies => {
                let entries = self
                    .api
                    .list_session_judge_policies()?
                    .into_iter()
                    .map(|entry| SessionJudgePolicyEntry {
                        session_id: entry.session_id,
                        policy: entry.policy,
                    })
                    .collect();
                Ok(ServerResult::SessionJudgePolicies { entries })
            }
            ClientRequest::GetJudgeHookStatus { workspace_path } => {
                let status = self.api.get_judge_hook_status(workspace_path)?;
                Ok(ServerResult::JudgeHookStatus { status })
            }
            ClientRequest::ConfigureJudgeHook {
                workspace_path,
                enabled,
            } => {
                let status = self.api.configure_judge_hook(workspace_path, enabled)?;
                Ok(ServerResult::JudgeHookStatus { status })
            }
            ClientRequest::GetJudgeHistory => {
                let records = self.api.get_judge_history()?;
                Ok(ServerResult::JudgeHistory { records })
            }
            ClientRequest::GetJudgeRules => {
                let rules = self.api.get_judge_rules()?;
                Ok(ServerResult::JudgeRules { rules })
            }
            ClientRequest::AddJudgeAllowCommand { command } => {
                let rules = self.api.add_judge_allow_command(command)?;
                Ok(ServerResult::JudgeRules { rules })
            }
            ClientRequest::RemoveJudgeAllowCommand { command } => {
                let rules = self.api.remove_judge_allow_command(command)?;
                Ok(ServerResult::JudgeRules { rules })
            }
            ClientRequest::AddJudgeDenySubstring { substring } => {
                let rules = self.api.add_judge_deny_substring(substring)?;
                Ok(ServerResult::JudgeRules { rules })
            }
            ClientRequest::RemoveJudgeDenySubstring { substring } => {
                let rules = self.api.remove_judge_deny_substring(substring)?;
                Ok(ServerResult::JudgeRules { rules })
            }
            ClientRequest::GetRailLayout => {
                let layout = self.api.get_rail_layout()?;
                Ok(ServerResult::RailLayout {
                    group_keys: layout.group_keys,
                    session_ids: layout.session_ids,
                    custom_labels: layout.custom_labels,
                })
            }
            ClientRequest::GetDaemonStats => {
                let (disk_free_bytes, disk_total_bytes) = current_disk_bytes();
                let (cpu_percent, battery_percent, battery_state) = current_host_stats();
                Ok(ServerResult::DaemonStats {
                    disk_free_bytes,
                    disk_total_bytes,
                    cpu_percent,
                    battery_percent,
                    battery_state,
                })
            }
            ClientRequest::SetRailPins {
                group_keys,
                session_ids,
            } => {
                self.api.set_rail_pins(group_keys, session_ids)?;
                Ok(ServerResult::Unit)
            }
            ClientRequest::SetSessionCustomLabel { session_id, label } => {
                self.api.set_session_custom_label(session_id, label)?;
                Ok(ServerResult::Unit)
            }
            ClientRequest::SyncTerminal { request } => {
                let session_id = request.session_id.clone();
                let want_subscribe = request.subscribe;
                if let Some(existing_sub_id) = self.session_to_sync_sub.get(&session_id).cloned()
                    && self.subscriptions.contains_key(&existing_sub_id)
                    && self.terminal_sync_subs.contains_key(&existing_sub_id)
                {
                    let (mut working_cursor, mut next_synth_event_seq) = {
                        let sub = self
                            .terminal_sync_subs
                            .get(&existing_sub_id)
                            .expect("checked contains_key");
                        (sub.cursor.clone(), sub.next_synth_event_seq)
                    };
                    let pre_sync_next_frame_seq = working_cursor.next_frame_seq;
                    let req_client_id = request.client_id.clone();
                    let req_size = request.size.clone();
                    if request.known_frame_seq == 0
                        || request.known_frame_seq != working_cursor.next_frame_seq
                    {
                        working_cursor.reset_viewport_keep_generations();
                    }
                    let (mut snapshot, mut lease, mut frame) = self
                        .api
                        .sync_terminal_session(request, &mut working_cursor)?;

                    // Drain queued events on the existing receiver into a staging
                    // buffer so dead-actor notifications are discarded if the
                    // session exited or was replaced by `restore_if_exited`.
                    let mut rx_disconnected = false;
                    let mut saw_output_or_snapshot = false;
                    let mut staged_events = Vec::new();
                    if let Some(existing_rx) = self.subscriptions.get(&existing_sub_id) {
                        loop {
                            match existing_rx.try_recv() {
                                Ok(envelope) => stage_sync_channel_envelope(
                                    &existing_sub_id,
                                    envelope,
                                    &mut staged_events,
                                    &mut saw_output_or_snapshot,
                                    &mut next_synth_event_seq,
                                ),
                                Err(TryRecvError::Empty) => break,
                                Err(TryRecvError::Disconnected) => {
                                    rx_disconnected = true;
                                    break;
                                }
                            }
                        }
                    }

                    if snapshot.exited {
                        self.subscriptions.remove(&existing_sub_id);
                        self.terminal_sync_subs.remove(&existing_sub_id);
                        self.session_to_sync_sub.remove(&session_id);
                        self.pending_events
                            .push_back(ServerMessage::SubscriptionClosed {
                                subscription_id: existing_sub_id,
                            });
                        return Ok(ServerResult::SyncTerminal {
                            response: Box::new(SyncTerminalResponse {
                                subscription_id: None,
                                snapshot,
                                lease,
                                frame,
                            }),
                        });
                    }

                    if rx_disconnected {
                        staged_events.clear();
                        saw_output_or_snapshot = false;
                        next_synth_event_seq = 1;
                        let fresh_rx = self.api.subscribe_session_events(session_id.clone()).ok();
                        working_cursor = TerminalSyncCursor::default();
                        working_cursor.next_frame_seq = pre_sync_next_frame_seq;
                        (snapshot, lease, frame) = self.api.sync_terminal_session(
                            SyncTerminalRequest {
                                session_id: session_id.clone(),
                                client_id: req_client_id,
                                mode: triage_core::session::AttachMode::Observer,
                                size: req_size,
                                resize_pty: false,
                                restore_if_exited: false,
                                subscribe: false,
                                known_frame_seq: 0,
                            },
                            &mut working_cursor,
                        )?;
                        if snapshot.exited {
                            self.subscriptions.remove(&existing_sub_id);
                            self.terminal_sync_subs.remove(&existing_sub_id);
                            self.session_to_sync_sub.remove(&session_id);
                            self.pending_events
                                .push_back(ServerMessage::SubscriptionClosed {
                                    subscription_id: existing_sub_id,
                                });
                            return Ok(ServerResult::SyncTerminal {
                                response: Box::new(SyncTerminalResponse {
                                    subscription_id: None,
                                    snapshot,
                                    lease,
                                    frame,
                                }),
                            });
                        }
                        let receiver = match fresh_rx {
                            Some(rx) => {
                                let mut fresh_disconnected = false;
                                loop {
                                    match rx.try_recv() {
                                        Ok(envelope) => stage_sync_channel_envelope(
                                            &existing_sub_id,
                                            envelope,
                                            &mut staged_events,
                                            &mut saw_output_or_snapshot,
                                            &mut next_synth_event_seq,
                                        ),
                                        Err(TryRecvError::Empty) => break,
                                        Err(TryRecvError::Disconnected) => {
                                            fresh_disconnected = true;
                                            break;
                                        }
                                    }
                                }
                                if fresh_disconnected {
                                    staged_events.clear();
                                    saw_output_or_snapshot = true;
                                    next_synth_event_seq = 1;
                                    self.api.subscribe_session_events_from(
                                        SubscribeSessionEventsRequest {
                                            session_id: session_id.clone(),
                                            after_event_seq: Some(0),
                                        },
                                    )?
                                } else {
                                    rx
                                }
                            }
                            None => {
                                saw_output_or_snapshot = true;
                                self.api.subscribe_session_events_from(
                                    SubscribeSessionEventsRequest {
                                        session_id: session_id.clone(),
                                        after_event_seq: Some(0),
                                    },
                                )?
                            }
                        };
                        self.subscriptions.insert(existing_sub_id.clone(), receiver);
                    }
                    self.pending_events.extend(staged_events);
                    if let Some(sub_state) = self.terminal_sync_subs.get_mut(&existing_sub_id) {
                        sub_state.cursor = working_cursor;
                        sub_state.last_acked_frame_seq = frame.frame_seq;
                        sub_state.dirty = saw_output_or_snapshot;
                        sub_state.retried_poll_err = false;
                        sub_state.next_synth_event_seq = next_synth_event_seq;
                    }
                    return Ok(ServerResult::SyncTerminal {
                        response: Box::new(SyncTerminalResponse {
                            subscription_id: Some(existing_sub_id.as_str().to_string()),
                            snapshot,
                            lease,
                            frame,
                        }),
                    });
                }

                self.session_to_sync_sub.remove(&session_id);
                let pre_rx = if want_subscribe {
                    self.api.subscribe_session_events(session_id.clone()).ok()
                } else {
                    None
                };
                let mut cursor = TerminalSyncCursor::default();
                let (snapshot, lease, frame) =
                    self.api.sync_terminal_session(request, &mut cursor)?;
                let mut subscription_id_out = None;
                if want_subscribe && !snapshot.exited {
                    let subscription_id = self.next_subscription_id();
                    let mut initial_dirty = false;
                    let mut staged_initial = Vec::new();
                    let mut pre_rx_disconnected = false;
                    let mut next_synth_event_seq = 1u64;
                    let receiver = match pre_rx {
                        Some(rx) => {
                            loop {
                                match rx.try_recv() {
                                    Ok(envelope) => stage_sync_channel_envelope(
                                        &subscription_id,
                                        envelope,
                                        &mut staged_initial,
                                        &mut initial_dirty,
                                        &mut next_synth_event_seq,
                                    ),
                                    Err(TryRecvError::Empty) => break,
                                    Err(TryRecvError::Disconnected) => {
                                        pre_rx_disconnected = true;
                                        break;
                                    }
                                }
                            }
                            if pre_rx_disconnected {
                                staged_initial.clear();
                                initial_dirty = true;
                                next_synth_event_seq = 1;
                                self.api.subscribe_session_events_from(
                                    SubscribeSessionEventsRequest {
                                        session_id: session_id.clone(),
                                        after_event_seq: Some(0),
                                    },
                                )?
                            } else {
                                rx
                            }
                        }
                        None => {
                            initial_dirty = true;
                            self.api.subscribe_session_events_from(
                                SubscribeSessionEventsRequest {
                                    session_id: session_id.clone(),
                                    after_event_seq: Some(0),
                                },
                            )?
                        }
                    };
                    self.pending_events.extend(staged_initial);
                    let frame_seq = frame.frame_seq;
                    subscription_id_out = Some(subscription_id.as_str().to_string());
                    self.subscriptions.insert(subscription_id.clone(), receiver);
                    self.terminal_sync_subs.insert(
                        subscription_id.clone(),
                        TerminalSyncSubState {
                            session_id: session_id.clone(),
                            cursor,
                            last_acked_frame_seq: frame_seq,
                            dirty: initial_dirty,
                            retried_poll_err: false,
                            next_synth_event_seq,
                        },
                    );
                    self.session_to_sync_sub.insert(session_id, subscription_id);
                }
                Ok(ServerResult::SyncTerminal {
                    response: Box::new(SyncTerminalResponse {
                        subscription_id: subscription_id_out,
                        snapshot,
                        lease,
                        frame,
                    }),
                })
            }
            ClientRequest::FetchTerminalRows { request } => {
                let response = self.api.fetch_terminal_rows(request)?;
                Ok(ServerResult::FetchTerminalRows { response })
            }
            ClientRequest::AckTerminalSync {
                subscription_id,
                frame_seq,
            } => {
                if let Some(sub_state) = self.terminal_sync_subs.get_mut(&subscription_id) {
                    let clamped = frame_seq.min(sub_state.cursor.next_frame_seq);
                    sub_state.last_acked_frame_seq = sub_state.last_acked_frame_seq.max(clamped);
                }
                Ok(ServerResult::Unit)
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

fn alloc_sync_event_seq(next_seq: &mut u64, floor: u64) -> u64 {
    let seq = (*next_seq).max(floor);
    *next_seq = seq.saturating_add(1);
    seq
}

fn stage_sync_channel_envelope(
    subscription_id: &SubscriptionId,
    mut envelope: SessionEventEnvelope,
    staged: &mut Vec<ServerMessage>,
    saw_output_or_snapshot: &mut bool,
    next_synth_event_seq: &mut u64,
) {
    match envelope.event {
        SessionEvent::Output { .. } => {
            *saw_output_or_snapshot = true;
            *next_synth_event_seq = (*next_synth_event_seq).max(envelope.event_seq);
        }
        SessionEvent::ResyncRequired {
            session_id: snap_sid,
            mut snapshot,
            ..
        } => {
            *saw_output_or_snapshot = true;
            let resync_exited = snapshot.exited;
            let resync_output_seq = snapshot.output_seq;
            let resync_bytes_logged = snapshot.bytes_logged;
            if resync_exited || staged.len() < MAX_EVENTS_PER_SUBSCRIPTION_DRAIN {
                snapshot.visible_rows.clear();
                snapshot.styled_rows.clear();
                snapshot.raw_output.clear();
                snapshot.raw_output_prefix.clear();
                let snap_seq = alloc_sync_event_seq(next_synth_event_seq, envelope.event_seq);
                staged.push(ServerMessage::Event {
                    subscription_id: subscription_id.clone(),
                    envelope: SessionEventEnvelope {
                        event_seq: snap_seq,
                        event: SessionEvent::Snapshot {
                            session_id: snap_sid.clone(),
                            snapshot,
                        },
                    },
                });
            } else {
                *next_synth_event_seq = (*next_synth_event_seq).max(envelope.event_seq);
            }
            if resync_exited {
                let exit_seq = alloc_sync_event_seq(next_synth_event_seq, envelope.event_seq);
                staged.push(ServerMessage::Event {
                    subscription_id: subscription_id.clone(),
                    envelope: SessionEventEnvelope {
                        event_seq: exit_seq,
                        event: SessionEvent::Exited {
                            session_id: snap_sid,
                            completed: CompletedSession {
                                output_seq: resync_output_seq,
                                bytes_logged: resync_bytes_logged,
                                visible_rows: Vec::new(),
                            },
                        },
                    },
                });
            }
        }
        SessionEvent::Snapshot {
            session_id: snap_sid,
            mut snapshot,
        } => {
            *saw_output_or_snapshot = true;
            if staged.len() < MAX_EVENTS_PER_SUBSCRIPTION_DRAIN {
                snapshot.visible_rows.clear();
                snapshot.styled_rows.clear();
                snapshot.raw_output.clear();
                snapshot.raw_output_prefix.clear();
                let seq = alloc_sync_event_seq(next_synth_event_seq, envelope.event_seq);
                staged.push(ServerMessage::Event {
                    subscription_id: subscription_id.clone(),
                    envelope: SessionEventEnvelope {
                        event_seq: seq,
                        event: SessionEvent::Snapshot {
                            session_id: snap_sid,
                            snapshot,
                        },
                    },
                });
            } else {
                *next_synth_event_seq = (*next_synth_event_seq).max(envelope.event_seq);
            }
        }
        SessionEvent::Exited { .. } => {
            envelope.event_seq = alloc_sync_event_seq(next_synth_event_seq, envelope.event_seq);
            staged.push(ServerMessage::Event {
                subscription_id: subscription_id.clone(),
                envelope,
            });
        }
        SessionEvent::LeaseChanged { .. } | SessionEvent::TerminalSync { .. } => {
            if staged.len() < MAX_EVENTS_PER_SUBSCRIPTION_DRAIN {
                envelope.event_seq = alloc_sync_event_seq(next_synth_event_seq, envelope.event_seq);
                staged.push(ServerMessage::Event {
                    subscription_id: subscription_id.clone(),
                    envelope,
                });
            } else {
                *next_synth_event_seq = (*next_synth_event_seq).max(envelope.event_seq);
            }
        }
    }
}

fn request_id_from_value(value: &Value) -> Option<Value> {
    value.get("id").filter(|id| !id.is_null()).cloned()
}

fn is_absent_id(id: &Option<Value>) -> bool {
    match id {
        None | Some(Value::Null) => true,
        Some(Value::String(s)) => s.is_empty(),
        _ => false,
    }
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
    PairingChallenge {
        client_id: ClientId,
    },
    PairViaTailscale {
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
    ListSessionSnippets,
    ListSessionContexts,
    GetSessionJudgePolicy {
        session_id: SessionId,
    },
    SetSessionJudgePolicy {
        session_id: SessionId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        enabled: Option<bool>,
    },
    ListSessionJudgePolicies,
    GetJudgeHookStatus {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        workspace_path: Option<String>,
    },
    ConfigureJudgeHook {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        workspace_path: Option<String>,
        enabled: bool,
    },
    GetJudgeHistory,
    GetJudgeRules,
    AddJudgeAllowCommand {
        command: String,
    },
    RemoveJudgeAllowCommand {
        command: String,
    },
    AddJudgeDenySubstring {
        substring: String,
    },
    RemoveJudgeDenySubstring {
        substring: String,
    },
    GetRailLayout,
    GetDaemonStats,
    SetRailPins {
        group_keys: Vec<String>,
        session_ids: Vec<String>,
    },
    SetSessionCustomLabel {
        session_id: SessionId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        label: Option<String>,
    },
    SyncTerminal {
        request: SyncTerminalRequest,
    },
    FetchTerminalRows {
        request: FetchTerminalRowsRequest,
    },
    AckTerminalSync {
        subscription_id: SubscriptionId,
        frame_seq: u64,
    },
}

/// One session's current snippet, as carried in [`ServerResult::SessionSnippets`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSnippetEntry {
    pub session_id: SessionId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snippet: Option<String>,
    /// Longer-form summary for the hover popover / search.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// One session's current git context, as carried in
/// [`ServerResult::SessionContexts`]. Mirrors the fields of the
/// [`ServerMessage::SessionContextUpdated`] push so a bulk fetch and the
/// incremental updates reconcile against the same shape.
/// `current_working_directory` is always `None` in the bulk fetch — the cached
/// `SessionContext` holds only the git fields; clients that need the live cwd
/// read it from the push.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionContextEntry {
    pub session_id: SessionId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_working_directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    /// Milliseconds since the Unix epoch of the session's most recent output, so
    /// a client can order its session list by recency. 0 means unknown: a
    /// session that has produced no output, or a daemon predating this field.
    #[serde(default)]
    pub last_activity_ms: u64,
    /// Milliseconds since the Unix epoch of the most recent input written to
    /// the session by any client. The rail's activity sort orders by this.
    /// 0 means unknown: no input yet, or a daemon predating this field.
    #[serde(default)]
    pub last_input_ms: u64,
}

/// One session's current auto-approval judge policy, as carried in
/// [`ServerResult::SessionJudgePolicies`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionJudgePolicyEntry {
    pub session_id: SessionId,
    pub policy: SessionJudgePolicy,
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
    /// Connection-wide push: a session's snippet was (re)generated. Delivered to
    /// every authenticated client regardless of subscriptions, drained from
    /// `global_rx` in `drain_events`.
    SessionSnippetUpdated {
        session_id: SessionId,
        snippet: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
        output_seq: u64,
    },
    /// Connection-wide push: a session's git context (or working directory)
    /// changed — e.g. the shell `cd`-ed into another repo or out of one.
    /// Delivered to every authenticated client so the side rail stays fresh
    /// without re-attaching. `current_working_directory` is set whenever known
    /// (even outside a repo); the git fields are `None` when the cwd is not
    /// inside a repository, so the rail can fall back to showing the cwd.
    SessionContextUpdated {
        session_id: SessionId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        current_working_directory: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        repository_root: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        worktree_root: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        branch: Option<String>,
    },
    /// Connection-wide push: the daemon's background update check found a newer
    /// stable release. Emitted once on the transition into the available state;
    /// the same information also rides every `Hello`, so a missed push is
    /// recovered on the next handshake.
    UpdateAvailable {
        current_version: String,
        latest_version: String,
    },
    /// Connection-wide push: a session's tool-call approval judge policy changed.
    SessionJudgePolicyUpdated {
        session_id: SessionId,
        policy: SessionJudgePolicy,
    },
    /// Connection-wide push: rail pins changed.
    RailPinsUpdated {
        group_keys: Vec<String>,
        session_ids: Vec<String>,
    },
    /// Connection-wide push: a session's custom label changed.
    SessionCustomLabelUpdated {
        session_id: SessionId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        custom_label: Option<String>,
    },
    /// Connection-wide push: a new session was started on the daemon.
    SessionStarted {
        session_id: SessionId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        current_working_directory: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        repository_root: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        worktree_root: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        branch: Option<String>,
        #[serde(default)]
        last_activity_ms: u64,
        #[serde(default)]
        last_input_ms: u64,
    },
    /// Connection-wide push: an existing session was shut down or deleted.
    SessionTerminated {
        session_id: SessionId,
    },
}

impl ServerMessage {
    /// Short stable name for logs and metrics. Matches the serde tag so a
    /// logged kind greps the same on both sides of the wire.
    pub fn kind(&self) -> &'static str {
        match self {
            ServerMessage::Response { .. } => "response",
            ServerMessage::Error { .. } => "error",
            ServerMessage::Event { .. } => "event",
            ServerMessage::SubscriptionClosed { .. } => "subscription_closed",
            ServerMessage::SessionSnippetUpdated { .. } => "session_snippet_updated",
            ServerMessage::SessionContextUpdated { .. } => "session_context_updated",
            ServerMessage::UpdateAvailable { .. } => "update_available",
            ServerMessage::SessionJudgePolicyUpdated { .. } => "session_judge_policy_updated",
            ServerMessage::RailPinsUpdated { .. } => "rail_pins_updated",
            ServerMessage::SessionCustomLabelUpdated { .. } => "session_custom_label_updated",
            ServerMessage::SessionStarted { .. } => "session_started",
            ServerMessage::SessionTerminated { .. } => "session_terminated",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum ServerResult {
    Unit,
    Hello {
        protocol_version: String,
        authenticated: bool,
        /// The running daemon's version (Phase 1–2 of self-update).
        server_version: String,
        /// Whether the daemon has seen a strictly newer stable release.
        update_available: bool,
        /// The newest release tag seen, normalized without a leading `v`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        latest_version: Option<String>,
        /// Free/total bytes on the volume holding the daemon's state. 0/0
        /// means unknown. Defaulted so a hello from a daemon predating
        /// these fields still parses.
        #[serde(default)]
        disk_free_bytes: u64,
        #[serde(default)]
        disk_total_bytes: u64,
        /// Whether the daemon offers Tailscale-identity pairing (allowlist
        /// configured). Defaults false so hellos from older daemons parse.
        #[serde(default)]
        tailscale_pairing_available: bool,
        /// Host CPU busy percent and battery level/state for the daemon
        /// selector. `None`/unknown means the probe failed or the first
        /// CPU sample is still seeding; defaulted so results from older
        /// daemons parse, skipped on the wire when unknown.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cpu_percent: Option<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        battery_percent: Option<u8>,
        #[serde(default)]
        battery_state: triage_core::host::BatteryState,
    },
    Paired {
        token: String,
    },
    PairingChallenge {
        device_code: String,
        expires_at: u64,
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
    SessionSnippets {
        entries: Vec<SessionSnippetEntry>,
    },
    SessionContexts {
        entries: Vec<SessionContextEntry>,
    },
    SessionJudgePolicy {
        session_id: SessionId,
        policy: SessionJudgePolicy,
    },
    SessionJudgePolicies {
        entries: Vec<SessionJudgePolicyEntry>,
    },
    JudgeHookStatus {
        status: triage_core::judge::JudgeHookStatus,
    },
    JudgeHistory {
        records: Vec<triage_core::judge::JudgeRecord>,
    },
    JudgeRules {
        rules: triage_core::judge::JudgeRulesInfo,
    },
    RailLayout {
        group_keys: Vec<String>,
        session_ids: Vec<String>,
        custom_labels: HashMap<String, String>,
    },
    DaemonStats {
        disk_free_bytes: u64,
        disk_total_bytes: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cpu_percent: Option<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        battery_percent: Option<u8>,
        #[serde(default)]
        battery_state: triage_core::host::BatteryState,
    },
    SyncTerminal {
        response: Box<SyncTerminalResponse>,
    },
    FetchTerminalRows {
        response: FetchTerminalRowsResponse,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
}

impl ProtocolError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
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
    use std::path::PathBuf;
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};

    use anyhow::{Result, bail};
    use serde_json::json;
    use triage_core::generated::triage::generated as fb;
    use triage_core::session::{
        AttachMode, InputLeaseState, SessionContext, SessionContextRow, SessionEvent, SessionSize,
        StyledRow, TerminalCursor,
    };

    use super::*;

    /// Disk stats in a response are a live probe: exact bytes can shift
    /// between the handler's probe and any re-probe (other processes, temp
    /// files), so assert the invariant rather than exact equality. Unknown
    /// (0/0) is accepted: some platforms cannot probe at all.
    fn assert_disk_invariant(free_bytes: u64, total_bytes: u64) {
        if free_bytes == 0 && total_bytes == 0 {
            return;
        }
        assert!(
            total_bytes > 0,
            "disk total must be positive, got {total_bytes}"
        );
        assert!(
            free_bytes <= total_bytes,
            "disk free {free_bytes} exceeds total {total_bytes}"
        );
    }

    /// Asserts a hello result's stable fields exactly; disk stats go through
    /// [`assert_disk_invariant`].
    fn assert_hello_result(result: ServerResult, authenticated: bool) {
        match result {
            ServerResult::Hello {
                protocol_version,
                authenticated: actual,
                server_version,
                update_available,
                latest_version,
                disk_free_bytes,
                disk_total_bytes,
                tailscale_pairing_available,
                ..
            } => {
                assert_eq!(protocol_version, PROTOCOL_VERSION);
                assert_eq!(actual, authenticated);
                assert!(!tailscale_pairing_available);
                // FakeSessionApi uses the default `server_update_info`: its
                // own crate version and no newer release known.
                assert_eq!(server_version, env!("CARGO_PKG_VERSION"));
                assert!(!update_available);
                assert_eq!(latest_version, None);
                assert_disk_invariant(disk_free_bytes, disk_total_bytes);
            }
            other => panic!("unexpected result: {other:?}"),
        }
    }

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

        match response {
            ServerMessage::Response { id, result } => {
                assert_eq!(id, Some(json!(1)));
                assert_hello_result(result, true);
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn disk_invariant_accepts_unknown_and_valid_volumes() {
        assert_disk_invariant(0, 0);
        assert_disk_invariant(25, 100);
        assert_disk_invariant(100, 100);
    }

    #[test]
    #[should_panic(expected = "exceeds total")]
    fn disk_invariant_rejects_free_above_total() {
        assert_disk_invariant(101, 100);
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
    fn list_session_contexts_routes_to_session_api() {
        let api = FakeSessionApi::default();
        api.sessions
            .lock()
            .unwrap()
            .push(SessionId::new("session-1").unwrap());
        let mut connection = WebSocketSessionConnection::new(api);

        let response =
            connection.handle_text_message(r#"{"id":"req-1","type":"list_session_contexts"}"#);

        let decoded: ServerMessage = serde_json::from_str(&response).unwrap();
        assert_eq!(
            decoded,
            ServerMessage::Response {
                id: Some(json!("req-1")),
                result: ServerResult::SessionContexts {
                    entries: vec![SessionContextEntry {
                        session_id: SessionId::new("session-1").unwrap(),
                        current_working_directory: None,
                        repository_root: Some("/repo".to_string()),
                        worktree_root: Some("/repo/worktree".to_string()),
                        branch: Some("main".to_string()),
                        last_activity_ms: 1_700_000_000_000,
                        last_input_ms: 1_700_000_005_000,
                    }],
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

    type SetPinsCalls = Arc<Mutex<Vec<(Vec<String>, Vec<String>)>>>;
    type SetCustomLabelCalls = Arc<Mutex<Vec<(SessionId, Option<String>)>>>;

    #[derive(Default)]
    struct FakeSessionApi {
        sessions: Mutex<Vec<SessionId>>,
        written: Arc<Mutex<Vec<WriteInputRequest>>>,
        next_subscription: Arc<Mutex<Option<SessionEventReceiver>>>,
        subscribe_calls: Arc<Mutex<usize>>,
        fail_sync_once: Arc<Mutex<bool>>,
        fail_poll_once: Arc<Mutex<bool>>,
        exited_snapshot: Arc<Mutex<bool>>,
        rail_layout: Mutex<triage_core::session::RailLayout>,
        set_pins_calls: SetPinsCalls,
        set_custom_label_calls: SetCustomLabelCalls,
        terminal_seqno: Arc<Mutex<usize>>,
        hold_sync_update: Arc<Mutex<bool>>,
    }

    impl SessionApi for FakeSessionApi {
        fn list_sessions(&self) -> Result<Vec<SessionId>> {
            Ok(self.sessions.lock().unwrap().clone())
        }

        fn list_session_contexts(&self) -> Result<Vec<SessionContextRow>> {
            Ok(self
                .sessions
                .lock()
                .unwrap()
                .iter()
                .cloned()
                .map(|session_id| SessionContextRow {
                    session_id,
                    context: Some(SessionContext {
                        repository_root: Some(PathBuf::from("/repo")),
                        worktree_root: Some(PathBuf::from("/repo/worktree")),
                        branch: Some("main".to_string()),
                    }),
                    last_activity_ms: 1_700_000_000_000,
                    last_input_ms: 1_700_000_005_000,
                })
                .collect())
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
            *self.subscribe_calls.lock().unwrap() += 1;
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

        fn get_rail_layout(&self) -> Result<triage_core::session::RailLayout> {
            Ok(self.rail_layout.lock().unwrap().clone())
        }

        fn set_rail_pins(&self, group_keys: Vec<String>, session_ids: Vec<String>) -> Result<()> {
            self.set_pins_calls
                .lock()
                .unwrap()
                .push((group_keys.clone(), session_ids.clone()));
            let mut layout = self.rail_layout.lock().unwrap();
            layout.group_keys = group_keys;
            layout.session_ids = session_ids;
            Ok(())
        }

        fn set_session_custom_label(
            &self,
            session_id: SessionId,
            label: Option<String>,
        ) -> Result<()> {
            self.set_custom_label_calls
                .lock()
                .unwrap()
                .push((session_id.clone(), label.clone()));
            let mut layout = self.rail_layout.lock().unwrap();
            if let Some(lbl) = label {
                layout.custom_labels.insert(session_id.to_string(), lbl);
            } else {
                layout.custom_labels.remove(session_id.as_str());
            }
            Ok(())
        }

        fn sync_terminal_session(
            &self,
            request: SyncTerminalRequest,
            cursor: &mut TerminalSyncCursor,
        ) -> Result<(
            SessionSnapshot,
            InputLeaseState,
            triage_core::session::TerminalSyncFrame,
        )> {
            {
                let mut fail = self.fail_sync_once.lock().unwrap();
                if *fail {
                    *fail = false;
                    bail!("transient sync failure");
                }
            }
            let seqno = (*self.terminal_seqno.lock().unwrap()).max(1);
            cursor.primary.initialized = true;
            cursor.primary.synced_seqno = seqno;
            cursor.next_frame_seq = cursor.next_frame_seq.wrapping_add(1);
            let mut snapshot = test_snapshot();
            snapshot.exited = *self.exited_snapshot.lock().unwrap();
            if let Some(sz) = request.size {
                snapshot.size = sz;
            }
            let frame = triage_core::session::TerminalSyncFrame {
                frame_seq: cursor.next_frame_seq,
                rows: snapshot.size.rows as u16,
                cols: snapshot.size.cols as u16,
                total_scrollback_rows: 42,
                viewport_compression: 0,
                viewport_payload: vec![0x54, 0x43, 0x47, 0x31, 0, 0, 0, 0, 0, 0, 0, 0],
                ..Default::default()
            };
            Ok((snapshot, InputLeaseState::default(), frame))
        }

        fn poll_terminal_sync(
            &self,
            _session_id: SessionId,
            cursor: &mut TerminalSyncCursor,
            force_full: bool,
        ) -> Result<PollTerminalSyncOutcome> {
            {
                let mut fail = self.fail_poll_once.lock().unwrap();
                if *fail {
                    *fail = false;
                    bail!("transient poll error");
                }
            }
            if *self.hold_sync_update.lock().unwrap() {
                return Ok(PollTerminalSyncOutcome::HoldForSynchronizedUpdate);
            }
            let seqno = *self.terminal_seqno.lock().unwrap();
            if !force_full && seqno <= cursor.primary.synced_seqno {
                return Ok(PollTerminalSyncOutcome::Idle);
            }
            cursor.primary.synced_seqno = seqno;
            cursor.next_frame_seq = cursor.next_frame_seq.wrapping_add(1);
            Ok(PollTerminalSyncOutcome::Frame(Box::new(
                triage_core::session::TerminalSyncFrame {
                    frame_seq: cursor.next_frame_seq,
                    rows: 24,
                    cols: 80,
                    total_scrollback_rows: 42 + seqno as u64,
                    viewport_compression: 1,
                    viewport_payload: vec![1, 2, 3, 4],
                    ..Default::default()
                },
            )))
        }

        fn fetch_terminal_rows(
            &self,
            request: FetchTerminalRowsRequest,
        ) -> Result<FetchTerminalRowsResponse> {
            Ok(FetchTerminalRowsResponse {
                session_id: request.session_id,
                start_row: request.start_row,
                row_count: request.row_count,
                total_scrollback_rows: 1000,
                trimmed_top_rows: 5,
                erase_scrollback_gen: 2,
                compression: 1,
                payload: vec![9, 8, 7, 6],
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
            raw_output: Vec::new(),
            raw_output_start: 0,
            raw_output_prefix: Vec::new(),
            snippet: None,
            snippet_detail: None,
            agent: None,
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
                history_bytes: None,
                session_id: SessionId::new("session-1").unwrap(),
                client_id: ClientId::new("client-1").unwrap(),
                mode: AttachMode::InteractiveController,
            },
        };

        let encoded = serde_json::to_value(&request).unwrap();

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
        let decoded_none: ClientRequest = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded_none, request);

        let fb_none = flatbuffers_proto::serialize_client_message(&ClientMessage {
            id: Some(json!("req-none")),
            request: request.clone(),
        });
        let root_none = ::flatbuffers::root::<
            triage_core::generated::triage::generated::ClientMessage,
        >(&fb_none)
        .unwrap();
        let parsed_fb_none = flatbuffers_proto::parse_client_message(root_none).unwrap();
        assert_eq!(parsed_fb_none.request, request);

        let capped_request = ClientRequest::AttachSession {
            request: AttachSessionRequest {
                history_bytes: Some(65_536),
                session_id: SessionId::new("session-1").unwrap(),
                client_id: ClientId::new("client-1").unwrap(),
                mode: AttachMode::Observer,
            },
        };
        let encoded_capped = serde_json::to_value(&capped_request).unwrap();
        assert_eq!(
            encoded_capped,
            json!({
                "type": "attach_session",
                "request": {
                    "session_id": "session-1",
                    "client_id": "client-1",
                    "mode": "Observer",
                    "history_bytes": 65536,
                },
            })
        );
        let decoded_capped: ClientRequest = serde_json::from_value(encoded_capped).unwrap();
        assert_eq!(decoded_capped, capped_request);

        let fb_capped = flatbuffers_proto::serialize_client_message(&ClientMessage {
            id: Some(json!("req-cap")),
            request: capped_request.clone(),
        });
        let root_capped = ::flatbuffers::root::<
            triage_core::generated::triage::generated::ClientMessage,
        >(&fb_capped)
        .unwrap();
        let parsed_fb_capped = flatbuffers_proto::parse_client_message(root_capped).unwrap();
        assert_eq!(parsed_fb_capped.request, capped_request);
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
        fn pairing_challenge(&self, client_id: &ClientId) -> Result<PairingChallenge> {
            if client_id == &self.client_id {
                Ok(PairingChallenge {
                    device_code: "DEVICE01".to_string(),
                    expires_at: 123,
                })
            } else {
                anyhow::bail!("invalid_client_id")
            }
        }
        fn pair(&self, code: &str, client_id: &ClientId) -> Result<String> {
            if code == self.pairing_code && client_id == &self.client_id {
                Ok(self.paired_token.clone())
            } else {
                anyhow::bail!("invalid_pairing_code")
            }
        }
    }

    struct TailscaleAuthenticator {
        paired_token: String,
        client_id: ClientId,
        allowed_peer: std::net::SocketAddr,
    }

    impl WebSocketAuthenticator for TailscaleAuthenticator {
        fn require_pairing(&self) -> bool {
            true
        }
        fn authenticate(&self, client_id: &ClientId, token: &str) -> Result<bool> {
            Ok(client_id == &self.client_id && token == self.paired_token)
        }
        fn pairing_challenge(&self, _client_id: &ClientId) -> Result<PairingChallenge> {
            anyhow::bail!("device-code pairing is disabled on this daemon")
        }
        fn pair(&self, _code: &str, _client_id: &ClientId) -> Result<String> {
            anyhow::bail!("device-code pairing is disabled on this daemon")
        }
        fn tailscale_pairing_available(&self) -> bool {
            true
        }
        fn pair_via_tailscale(
            &self,
            client_id: &ClientId,
            peer: std::net::SocketAddr,
        ) -> Result<String> {
            if client_id == &self.client_id && peer == self.allowed_peer {
                Ok(self.paired_token.clone())
            } else {
                anyhow::bail!("tailnet identity is not authorized to pair with this daemon")
            }
        }
    }

    fn tailscale_test_auth() -> TailscaleAuthenticator {
        TailscaleAuthenticator {
            paired_token: "tailnet-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
            allowed_peer: "100.65.193.69:1".parse().unwrap(),
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
    fn unauthenticated_connection_does_not_drain_global_pushes() {
        let auth = FakeAuthenticator {
            require_pairing: true,
            pairing_code: "123456".to_string(),
            paired_token: "secret-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
        };
        let (tx, rx) = mpsc::channel();
        let mut connection =
            WebSocketSessionConnection::with_authenticator(FakeSessionApi::default(), auth)
                .with_global_receiver(rx);

        let push = ServerMessage::SessionSnippetUpdated {
            session_id: SessionId::new("session-1").unwrap(),
            snippet: "ran the tests".to_string(),
            detail: Some("Ran the test suite; all tests passed.".to_string()),
            output_seq: 7,
        };
        tx.send(push.clone()).unwrap();

        // Pairing is required and the connection hasn't authenticated, so the
        // snippet (derived from session output) must not be delivered.
        assert!(connection.drain_events().is_empty());

        // Once paired, the buffered push is delivered.
        let paired = connection.handle_message(ClientMessage {
            id: Some(json!("pair-req")),
            request: ClientRequest::Pair {
                code: "123456".to_string(),
                client_id: ClientId::new("phone").unwrap(),
            },
        });
        assert!(matches!(paired, ServerMessage::Response { .. }));

        assert_eq!(connection.drain_events(), vec![push]);
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
    fn unauthenticated_connection_can_request_pairing_challenge() {
        let auth = FakeAuthenticator {
            require_pairing: true,
            pairing_code: "123456".to_string(),
            paired_token: "secret-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
        };
        let mut connection =
            WebSocketSessionConnection::with_authenticator(FakeSessionApi::default(), auth);

        let response = connection.handle_message(ClientMessage {
            id: Some(json!("challenge-req")),
            request: ClientRequest::PairingChallenge {
                client_id: ClientId::new("phone").unwrap(),
            },
        });

        match response {
            ServerMessage::Response { id, result } => {
                assert_eq!(id, Some(json!("challenge-req")));
                assert_eq!(
                    result,
                    ServerResult::PairingChallenge {
                        device_code: "DEVICE01".to_string(),
                        expires_at: 123,
                    }
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }
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
                assert_hello_result(result, true);
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
                assert_hello_result(result, false);
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

    #[test]
    fn flatbuffers_hello_roundtrip() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());
        let request = ClientMessage {
            id: Some(json!("req-fb")),
            request: ClientRequest::Hello {
                client_id: None,
                token: None,
            },
        };

        let client_bytes = flatbuffers_proto::serialize_client_message(&request);
        let response_bytes = connection.handle_binary_message(&client_bytes);

        let root = flatbuffers::root::<fb::ServerMessage>(&response_bytes).unwrap();
        assert_eq!(
            root.payload_type(),
            fb::ServerMessagePayload::ResponsePayload
        );
        let resp = root.payload_as_response_payload().unwrap();
        assert_eq!(resp.id().unwrap(), "req-fb");

        assert_eq!(resp.result_type(), fb::ServerResultPayload::HelloResult);
        let hello = resp.result_as_hello_result().unwrap();
        assert_eq!(hello.protocol_version().unwrap(), PROTOCOL_VERSION);
        assert!(hello.authenticated());
        // Self-update fields ride the handshake: the default `server_update_info`
        // reports this build with nothing newer known.
        assert_eq!(hello.server_version().unwrap(), env!("CARGO_PKG_VERSION"));
        assert!(!hello.update_available());
        assert!(hello.latest_version().is_none());
        // Disk fields ride the handshake too, as a live probe: assert the
        // invariant, not exact bytes.
        assert_disk_invariant(hello.disk_free_bytes(), hello.disk_total_bytes());
        assert!(!hello.tailscale_pairing_available());
    }

    #[test]
    fn flatbuffers_hello_host_stats_roundtrip() {
        let msg = ServerMessage::Response {
            id: Some(json!("hello-fb")),
            result: ServerResult::Hello {
                protocol_version: "1".to_string(),
                authenticated: true,
                server_version: "0.3.0".to_string(),
                update_available: false,
                latest_version: None,
                disk_free_bytes: 12_345,
                disk_total_bytes: 67_890,
                tailscale_pairing_available: false,
                cpu_percent: Some(33),
                battery_percent: Some(76),
                battery_state: triage_core::host::BatteryState::Discharging,
            },
        };
        let bytes = flatbuffers_proto::serialize_server_message(&msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::Response {
                id: Some("hello-fb"),
                result: flatbuffers_proto::ServerResultBorrowed::Hello {
                    protocol_version: "1",
                    authenticated: true,
                    server_version: "0.3.0",
                    update_available: false,
                    latest_version: None,
                    disk_free_bytes: 12_345,
                    disk_total_bytes: 67_890,
                    tailscale_pairing_available: false,
                    cpu_percent: Some(33),
                    battery_percent: Some(76),
                    battery_state: triage_core::host::BatteryState::Discharging,
                },
            }
        );
    }

    #[test]
    fn flatbuffers_daemon_stats_roundtrip() {
        let msg = ServerMessage::Response {
            id: Some(json!("stats-fb")),
            result: ServerResult::DaemonStats {
                disk_free_bytes: 12_345,
                disk_total_bytes: 67_890,
                cpu_percent: Some(42),
                battery_percent: Some(87),
                battery_state: triage_core::host::BatteryState::Charging,
            },
        };
        let bytes = flatbuffers_proto::serialize_server_message(&msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::Response {
                id: Some("stats-fb"),
                result: flatbuffers_proto::ServerResultBorrowed::DaemonStats {
                    disk_free_bytes: 12_345,
                    disk_total_bytes: 67_890,
                    cpu_percent: Some(42),
                    battery_percent: Some(87),
                    battery_state: triage_core::host::BatteryState::Charging,
                },
            }
        );
    }

    #[test]
    fn flatbuffers_daemon_stats_unknown_roundtrip() {
        // Unknown legs must survive the round trip as unknown (-1), not as
        // a bogus 0: 0% CPU and 0% battery are both valid readings.
        let msg = ServerMessage::Response {
            id: Some(json!("stats-fb-unknown")),
            result: ServerResult::DaemonStats {
                disk_free_bytes: 0,
                disk_total_bytes: 0,
                cpu_percent: None,
                battery_percent: None,
                battery_state: triage_core::host::BatteryState::Unknown,
            },
        };
        let bytes = flatbuffers_proto::serialize_server_message(&msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::Response {
                id: Some("stats-fb-unknown"),
                result: flatbuffers_proto::ServerResultBorrowed::DaemonStats {
                    disk_free_bytes: 0,
                    disk_total_bytes: 0,
                    cpu_percent: None,
                    battery_percent: None,
                    battery_state: triage_core::host::BatteryState::Unknown,
                },
            }
        );
    }

    #[test]
    fn flatbuffers_update_available_roundtrip() {
        let msg = ServerMessage::UpdateAvailable {
            current_version: "0.1.6".to_string(),
            latest_version: "0.1.7".to_string(),
        };
        let bytes = flatbuffers_proto::serialize_server_message(&msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::UpdateAvailable {
                current_version: "0.1.6",
                latest_version: "0.1.7",
            }
        );
    }

    #[test]
    fn hello_advertises_tailscale_pairing_when_available() {
        let mut connection = WebSocketSessionConnection::with_authenticator(
            FakeSessionApi::default(),
            tailscale_test_auth(),
        );
        let response = connection.handle_message(ClientMessage {
            id: Some(json!("hello-ts")),
            request: ClientRequest::Hello {
                client_id: None,
                token: None,
            },
        });
        match response {
            ServerMessage::Response { id, result } => {
                assert_eq!(id, Some(json!("hello-ts")));
                match result {
                    ServerResult::Hello {
                        protocol_version,
                        authenticated,
                        server_version,
                        update_available,
                        latest_version,
                        disk_free_bytes,
                        disk_total_bytes,
                        tailscale_pairing_available,
                        ..
                    } => {
                        assert_eq!(protocol_version, PROTOCOL_VERSION);
                        assert!(!authenticated);
                        assert_eq!(server_version, env!("CARGO_PKG_VERSION"));
                        assert!(!update_available);
                        assert_eq!(latest_version, None);
                        assert_disk_invariant(disk_free_bytes, disk_total_bytes);
                        assert!(tailscale_pairing_available);
                    }
                    other => panic!("unexpected result: {other:?}"),
                }
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn pair_via_tailscale_allowed_preauth_and_mints() {
        let mut connection = WebSocketSessionConnection::with_authenticator(
            FakeSessionApi::default(),
            tailscale_test_auth(),
        )
        .with_peer_addr("100.65.193.69:1".parse().unwrap());
        let response = connection.handle_message(ClientMessage {
            id: Some(json!("pair-ts")),
            request: ClientRequest::PairViaTailscale {
                client_id: ClientId::new("phone").unwrap(),
            },
        });
        match response {
            ServerMessage::Response { id, result } => {
                assert_eq!(id, Some(json!("pair-ts")));
                assert_eq!(
                    result,
                    ServerResult::Paired {
                        token: "tailnet-token".to_string(),
                    }
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }
        // Minting authenticates the connection: session requests now pass.
        let sessions = connection.handle_message(ClientMessage {
            id: Some(json!("list-after")),
            request: ClientRequest::ListSessions,
        });
        assert!(matches!(sessions, ServerMessage::Response { .. }));
    }

    #[test]
    fn pair_via_tailscale_denied_without_peer_addr() {
        let mut connection = WebSocketSessionConnection::with_authenticator(
            FakeSessionApi::default(),
            tailscale_test_auth(),
        );
        let response = connection.handle_message(ClientMessage {
            id: Some(json!("pair-ts")),
            request: ClientRequest::PairViaTailscale {
                client_id: ClientId::new("phone").unwrap(),
            },
        });
        match response {
            ServerMessage::Error { error, .. } => {
                assert!(
                    error.message.contains("peer address"),
                    "unexpected error: {}",
                    error.message
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn flatbuffers_pair_via_tailscale_roundtrip_when_unauthenticated() {
        let mut connection = WebSocketSessionConnection::with_authenticator(
            FakeSessionApi::default(),
            tailscale_test_auth(),
        )
        .with_peer_addr("100.65.193.69:1".parse().unwrap());
        let request = ClientMessage {
            id: Some(json!("pair-ts-fb")),
            request: ClientRequest::PairViaTailscale {
                client_id: ClientId::new("phone").unwrap(),
            },
        };

        let client_bytes = flatbuffers_proto::serialize_client_message(&request);
        let parsed = flatbuffers::root::<fb::ClientMessage>(&client_bytes)
            .ok()
            .and_then(|msg| msg.payload_as_pair_via_tailscale_request())
            .expect("tailscale pair request payload");
        assert_eq!(parsed.client_id().unwrap(), "phone");

        let response_bytes = connection.handle_binary_message(&client_bytes);
        let root = flatbuffers::root::<fb::ServerMessage>(&response_bytes).unwrap();
        assert_eq!(
            root.payload_type(),
            fb::ServerMessagePayload::ResponsePayload
        );
        let resp = root.payload_as_response_payload().unwrap();
        assert_eq!(resp.id().unwrap(), "pair-ts-fb");
        assert_eq!(resp.result_type(), fb::ServerResultPayload::PairedResult);
        let paired = resp.result_as_paired_result().unwrap();
        assert_eq!(paired.token().unwrap(), "tailnet-token");

        let borrowed = flatbuffers_proto::parse_fb_server_message_borrowed(&response_bytes)
            .expect("borrowed paired response");
        assert_eq!(
            borrowed,
            flatbuffers_proto::ServerMessageBorrowed::Response {
                id: Some("pair-ts-fb"),
                result: flatbuffers_proto::ServerResultBorrowed::Paired {
                    token: "tailnet-token",
                },
            }
        );
    }

    #[test]
    fn flatbuffers_pairing_challenge_roundtrip_when_unauthenticated() {
        let auth = FakeAuthenticator {
            require_pairing: true,
            pairing_code: "123456".to_string(),
            paired_token: "secret-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
        };
        let mut connection =
            WebSocketSessionConnection::with_authenticator(FakeSessionApi::default(), auth);
        let request = ClientMessage {
            id: Some(json!("challenge-fb")),
            request: ClientRequest::PairingChallenge {
                client_id: ClientId::new("phone").unwrap(),
            },
        };

        let client_bytes = flatbuffers_proto::serialize_client_message(&request);
        let parsed = flatbuffers::root::<fb::ClientMessage>(&client_bytes)
            .ok()
            .and_then(|msg| msg.payload_as_pairing_challenge_request())
            .expect("pairing challenge request payload");
        assert_eq!(parsed.client_id().unwrap(), "phone");

        let response_bytes = connection.handle_binary_message(&client_bytes);
        let root = flatbuffers::root::<fb::ServerMessage>(&response_bytes).unwrap();
        assert_eq!(
            root.payload_type(),
            fb::ServerMessagePayload::ResponsePayload
        );
        let resp = root.payload_as_response_payload().unwrap();
        assert_eq!(resp.id().unwrap(), "challenge-fb");
        assert_eq!(
            resp.result_type(),
            fb::ServerResultPayload::PairingChallengeResult
        );
        let challenge = resp.result_as_pairing_challenge_result().unwrap();
        assert_eq!(challenge.device_code().unwrap(), "DEVICE01");
        assert_eq!(challenge.expires_at(), 123);

        let borrowed = flatbuffers_proto::parse_fb_server_message_borrowed(&response_bytes)
            .expect("borrowed pairing challenge response");
        assert_eq!(
            borrowed,
            flatbuffers_proto::ServerMessageBorrowed::Response {
                id: Some("challenge-fb"),
                result: flatbuffers_proto::ServerResultBorrowed::PairingChallenge {
                    device_code: "DEVICE01",
                    expires_at: 123,
                },
            }
        );
    }

    #[test]
    fn flatbuffers_invalid_payload_returns_error_safely() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());

        let response_bytes =
            connection.handle_binary_message(&[0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34]);

        let root = flatbuffers::root::<fb::ServerMessage>(&response_bytes).unwrap();
        assert_eq!(root.payload_type(), fb::ServerMessagePayload::ErrorPayload);
        let err = root.payload_as_error_payload().unwrap();
        assert_eq!(err.code().unwrap(), "invalid_flatbuffer");
        assert!(!err.message().unwrap().is_empty());
    }

    #[test]
    fn flatbuffers_session_contexts_carry_activity() {
        // The binary encoder is a separate hand-written path from the JSON one,
        // and this is exactly where the two drifted: `last_activity_ms` reached
        // the schema and the JSON form while the FlatBuffers writer kept
        // omitting it, so the rail read 0 for every session over the default
        // transport and ordered them arbitrarily. Read straight off the buffer
        // because the borrowed parser has no case for this result, only the
        // Dart client decodes it, so nothing else on this side would notice.
        let msg = ServerMessage::Response {
            id: Some(json!("req-1")),
            result: ServerResult::SessionContexts {
                entries: vec![SessionContextEntry {
                    session_id: SessionId::new("session-1").unwrap(),
                    current_working_directory: Some("/repo/wt".to_string()),
                    repository_root: Some("/repo".to_string()),
                    worktree_root: Some("/repo/wt".to_string()),
                    branch: Some("main".to_string()),
                    last_activity_ms: 1_700_000_000_000,
                    last_input_ms: 1_700_000_005_000,
                }],
            },
        };

        let bytes = flatbuffers_proto::serialize_server_message(&msg);
        let entries = flatbuffers::root::<fb::ServerMessage>(&bytes)
            .unwrap()
            .payload_as_response_payload()
            .unwrap()
            .result_as_session_contexts_result()
            .unwrap()
            .entries()
            .unwrap();

        assert_eq!(entries.len(), 1);
        let entry = entries.get(0);
        assert_eq!(entry.session_id(), Some("session-1"));
        assert_eq!(entry.current_working_directory(), Some("/repo/wt"));
        assert_eq!(entry.repository_root(), Some("/repo"));
        assert_eq!(entry.worktree_root(), Some("/repo/wt"));
        assert_eq!(entry.branch(), Some("main"));
        assert_eq!(entry.last_activity_ms(), 1_700_000_000_000);
    }

    #[test]
    fn flatbuffers_session_context_updated_roundtrip() {
        // In a repo: every git field is carried alongside the cwd.
        let in_repo = ServerMessage::SessionContextUpdated {
            session_id: SessionId::new("session-1").unwrap(),
            current_working_directory: Some("/home/me/dev/triage".to_string()),
            repository_root: Some("/home/me/dev/triage".to_string()),
            worktree_root: Some("/home/me/dev/triage/worktrees/x".to_string()),
            branch: Some("feat/x".to_string()),
        };
        let bytes = flatbuffers_proto::serialize_server_message(&in_repo);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::SessionContextUpdated {
                session_id: "session-1",
                current_working_directory: Some("/home/me/dev/triage"),
                repository_root: Some("/home/me/dev/triage"),
                worktree_root: Some("/home/me/dev/triage/worktrees/x"),
                branch: Some("feat/x"),
            }
        );

        // Outside a repo: the cwd is still sent, with the git fields absent so
        // the client can fall back to showing the working directory.
        let no_repo = ServerMessage::SessionContextUpdated {
            session_id: SessionId::new("session-2").unwrap(),
            current_working_directory: Some("/tmp/scratch".to_string()),
            repository_root: None,
            worktree_root: None,
            branch: None,
        };
        let bytes = flatbuffers_proto::serialize_server_message(&no_repo);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::SessionContextUpdated {
                session_id: "session-2",
                current_working_directory: Some("/tmp/scratch"),
                repository_root: None,
                worktree_root: None,
                branch: None,
            }
        );
    }

    #[test]
    fn rail_layout_routes_to_session_api() {
        let api = FakeSessionApi::default();
        {
            let mut layout = api.rail_layout.lock().unwrap();
            layout.group_keys = vec!["/repo/a".to_string()];
            layout.session_ids = vec!["s1".to_string(), "s2".to_string()];
            layout
                .custom_labels
                .insert("s1".to_string(), "Agent One".to_string());
        }
        let mut connection = WebSocketSessionConnection::new(api);
        let response =
            connection.handle_text_message(r#"{"id":"layout-1","type":"get_rail_layout"}"#);
        let decoded: ServerMessage = serde_json::from_str(&response).unwrap();
        match decoded {
            ServerMessage::Response {
                id: Some(id),
                result:
                    ServerResult::RailLayout {
                        group_keys,
                        session_ids,
                        custom_labels,
                    },
            } => {
                assert_eq!(id, json!("layout-1"));
                assert_eq!(group_keys, vec!["/repo/a"]);
                assert_eq!(session_ids, vec!["s1", "s2"]);
                assert_eq!(custom_labels.get("s1"), Some(&"Agent One".to_string()));
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn daemon_stats_reports_live_disk_probe() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());
        let response =
            connection.handle_text_message(r#"{"id":"stats-1","type":"get_daemon_stats"}"#);
        let decoded: ServerMessage = serde_json::from_str(&response).unwrap();
        match decoded {
            ServerMessage::Response {
                id: Some(id),
                result:
                    ServerResult::DaemonStats {
                        disk_free_bytes,
                        disk_total_bytes,
                        cpu_percent,
                        battery_percent,
                        ..
                    },
            } => {
                assert_eq!(id, json!("stats-1"));
                assert_disk_invariant(disk_free_bytes, disk_total_bytes);
                // Live host legs are unknown-or-bounded, never bogus.
                if let Some(cpu) = cpu_percent {
                    assert!(cpu <= 100, "cpu {cpu} exceeds 100");
                }
                if let Some(battery) = battery_percent {
                    assert!(battery <= 100, "battery {battery} exceeds 100");
                }
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    // The invariant above accepts 0/0 (platforms that cannot probe), so a
    // handler hardcoding unknown would pass it. This pins the probe wiring
    // on platforms where the probe always answers.
    #[test]
    #[cfg(any(unix, windows))]
    fn daemon_stats_probe_is_wired_on_supported_platforms() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());
        let response =
            connection.handle_text_message(r#"{"id":"stats-2","type":"get_daemon_stats"}"#);
        let decoded: ServerMessage = serde_json::from_str(&response).unwrap();
        match decoded {
            ServerMessage::Response {
                result:
                    ServerResult::DaemonStats {
                        disk_free_bytes,
                        disk_total_bytes,
                        ..
                    },
                ..
            } => {
                assert!(
                    disk_total_bytes > 0,
                    "probe must report a total, got {disk_total_bytes}"
                );
                assert!(
                    disk_free_bytes <= disk_total_bytes,
                    "free {disk_free_bytes} exceeds total {disk_total_bytes}"
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    // Mirror of the stats pin above for the sibling read: hello accepts 0/0 by
    // design on unknown platforms, so on supported platforms pin that its call
    // site is wired to the probe rather than hardcoded unknown.
    #[test]
    #[cfg(any(unix, windows))]
    fn hello_probe_is_wired_on_supported_platforms() {
        let mut connection = WebSocketSessionConnection::new(FakeSessionApi::default());
        let response = connection.handle_text_message(r#"{"id":"hello-disk","type":"hello"}"#);
        let decoded: ServerMessage = serde_json::from_str(&response).unwrap();
        match decoded {
            ServerMessage::Response {
                result:
                    ServerResult::Hello {
                        disk_free_bytes,
                        disk_total_bytes,
                        ..
                    },
                ..
            } => {
                assert!(
                    disk_total_bytes > 0,
                    "probe must report a total, got {disk_total_bytes}"
                );
                assert!(
                    disk_free_bytes <= disk_total_bytes,
                    "free {disk_free_bytes} exceeds total {disk_total_bytes}"
                );
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn set_rail_pins_and_custom_label_route_to_session_api() {
        let api = FakeSessionApi::default();
        let set_pins_calls = Arc::clone(&api.set_pins_calls);
        let set_custom_label_calls = Arc::clone(&api.set_custom_label_calls);
        let mut connection = WebSocketSessionConnection::new(api);

        let pins_resp = connection.handle_text_message(
            r#"{"id":"pins-1","type":"set_rail_pins","group_keys":["/repo/b"],"session_ids":["s3"]}"#,
        );
        let decoded_pins: ServerMessage = serde_json::from_str(&pins_resp).unwrap();
        assert_eq!(
            decoded_pins,
            ServerMessage::Response {
                id: Some(json!("pins-1")),
                result: ServerResult::Unit,
            }
        );
        assert_eq!(
            *set_pins_calls.lock().unwrap(),
            vec![(vec!["/repo/b".to_string()], vec!["s3".to_string()])]
        );

        let label_resp = connection.handle_text_message(
            r#"{"id":"label-1","type":"set_session_custom_label","session_id":"s3","label":"My Worker"}"#,
        );
        let decoded_label: ServerMessage = serde_json::from_str(&label_resp).unwrap();
        assert_eq!(
            decoded_label,
            ServerMessage::Response {
                id: Some(json!("label-1")),
                result: ServerResult::Unit,
            }
        );
        assert_eq!(
            *set_custom_label_calls.lock().unwrap(),
            vec![(SessionId::new("s3").unwrap(), Some("My Worker".to_string()))]
        );
    }

    #[test]
    fn flatbuffers_rail_layout_roundtrip() {
        let api = FakeSessionApi::default();
        {
            let mut layout = api.rail_layout.lock().unwrap();
            layout.group_keys = vec!["/repo/wt".to_string()];
            layout.session_ids = vec!["s-10".to_string()];
            layout
                .custom_labels
                .insert("s-10".to_string(), "Reviewer".to_string());
        }
        let mut connection = WebSocketSessionConnection::new(api);
        let request = ClientMessage {
            id: Some(json!("layout-fb")),
            request: ClientRequest::GetRailLayout,
        };
        let client_bytes = flatbuffers_proto::serialize_client_message(&request);
        let response_bytes = connection.handle_binary_message(&client_bytes);

        let borrowed =
            flatbuffers_proto::parse_fb_server_message_borrowed(&response_bytes).unwrap();
        match borrowed {
            flatbuffers_proto::ServerMessageBorrowed::Response {
                id: Some(id),
                result:
                    flatbuffers_proto::ServerResultBorrowed::RailLayout {
                        group_keys,
                        session_ids,
                        custom_labels,
                    },
            } => {
                assert_eq!(id, "layout-fb");
                assert_eq!(group_keys, vec!["/repo/wt"]);
                assert_eq!(session_ids, vec!["s-10"]);
                assert_eq!(custom_labels, vec![("s-10", "Reviewer")]);
            }
            other => panic!("unexpected response: {other:?}"),
        }
    }

    #[test]
    fn flatbuffers_rail_pins_updated_roundtrip() {
        let msg = ServerMessage::RailPinsUpdated {
            group_keys: vec!["/repo/x".to_string()],
            session_ids: vec!["s-1".to_string(), "s-2".to_string()],
        };
        let bytes = flatbuffers_proto::serialize_server_message(&msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::RailPinsUpdated {
                group_keys: vec!["/repo/x"],
                session_ids: vec!["s-1", "s-2"],
            }
        );
    }

    #[test]
    fn flatbuffers_session_custom_label_updated_roundtrip() {
        let set_msg = ServerMessage::SessionCustomLabelUpdated {
            session_id: SessionId::new("s-1").unwrap(),
            custom_label: Some("Primary Task".to_string()),
        };
        let bytes_set = flatbuffers_proto::serialize_server_message(&set_msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes_set).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::SessionCustomLabelUpdated {
                session_id: "s-1",
                custom_label: Some("Primary Task"),
            }
        );

        let clear_msg = ServerMessage::SessionCustomLabelUpdated {
            session_id: SessionId::new("s-1").unwrap(),
            custom_label: None,
        };
        let bytes_clear = flatbuffers_proto::serialize_server_message(&clear_msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes_clear).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::SessionCustomLabelUpdated {
                session_id: "s-1",
                custom_label: None,
            }
        );
    }

    #[test]
    fn flatbuffers_session_started_roundtrip() {
        let msg = ServerMessage::SessionStarted {
            session_id: SessionId::new("s-new").unwrap(),
            current_working_directory: Some("/path/to/cwd".to_string()),
            repository_root: Some("/path/to/repo".to_string()),
            worktree_root: Some("/path/to/worktree".to_string()),
            branch: Some("feat/sync".to_string()),
            last_activity_ms: 1720000000000,
            last_input_ms: 1720000000001,
        };
        let bytes = flatbuffers_proto::serialize_server_message(&msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::SessionStarted {
                session_id: "s-new",
                current_working_directory: Some("/path/to/cwd"),
                repository_root: Some("/path/to/repo"),
                worktree_root: Some("/path/to/worktree"),
                branch: Some("feat/sync"),
                last_activity_ms: 1720000000000,
                last_input_ms: 1720000000001,
            }
        );
    }

    #[test]
    fn flatbuffers_session_terminated_roundtrip() {
        let msg = ServerMessage::SessionTerminated {
            session_id: SessionId::new("s-old").unwrap(),
        };
        let bytes = flatbuffers_proto::serialize_server_message(&msg);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::SessionTerminated {
                session_id: "s-old",
            }
        );
    }

    #[test]
    fn json_session_lifecycle_roundtrip() {
        let started = ServerMessage::SessionStarted {
            session_id: SessionId::new("s-1").unwrap(),
            current_working_directory: Some("/dir".to_string()),
            repository_root: Some("/repo".to_string()),
            worktree_root: None,
            branch: Some("main".to_string()),
            last_activity_ms: 123456789,
            last_input_ms: 987654321,
        };
        let started_json = serde_json::to_string(&started).unwrap();
        let started_deserialized: ServerMessage = serde_json::from_str(&started_json).unwrap();
        assert_eq!(started, started_deserialized);

        let terminated = ServerMessage::SessionTerminated {
            session_id: SessionId::new("s-1").unwrap(),
        };
        let terminated_json = serde_json::to_string(&terminated).unwrap();
        let terminated_deserialized: ServerMessage =
            serde_json::from_str(&terminated_json).unwrap();
        assert_eq!(terminated, terminated_deserialized);
    }

    #[test]
    fn server_message_kind_matches_serde_type_tag_for_all_variants() {
        let sid = SessionId::new("s-1").unwrap();
        let sub_id = SubscriptionId::new("sub-1").unwrap();
        let samples = vec![
            ServerMessage::Response {
                id: None,
                result: ServerResult::Unit,
            },
            ServerMessage::Error {
                id: None,
                error: ProtocolError::new("bad_request", "bad"),
            },
            ServerMessage::Event {
                subscription_id: sub_id.clone(),
                envelope: test_output_event(1),
            },
            ServerMessage::SubscriptionClosed {
                subscription_id: sub_id,
            },
            ServerMessage::SessionSnippetUpdated {
                session_id: sid.clone(),
                snippet: "hi".to_string(),
                detail: None,
                output_seq: 1,
            },
            ServerMessage::SessionContextUpdated {
                session_id: sid.clone(),
                current_working_directory: None,
                repository_root: None,
                worktree_root: None,
                branch: None,
            },
            ServerMessage::UpdateAvailable {
                current_version: "0.1.0".to_string(),
                latest_version: "0.2.0".to_string(),
            },
            ServerMessage::SessionJudgePolicyUpdated {
                session_id: sid.clone(),
                policy: SessionJudgePolicy {
                    explicit: None,
                    effective: true,
                },
            },
            ServerMessage::RailPinsUpdated {
                group_keys: vec![],
                session_ids: vec![],
            },
            ServerMessage::SessionCustomLabelUpdated {
                session_id: sid.clone(),
                custom_label: None,
            },
            ServerMessage::SessionStarted {
                session_id: sid.clone(),
                current_working_directory: None,
                repository_root: None,
                worktree_root: None,
                branch: None,
                last_activity_ms: 0,
                last_input_ms: 0,
            },
            ServerMessage::SessionTerminated { session_id: sid },
        ];
        for msg in samples {
            let wire = serde_json::to_value(&msg).expect("serialize ServerMessage");
            assert_eq!(Some(msg.kind()), wire.get("type").and_then(Value::as_str));
        }
    }

    #[test]
    fn flatbuffers_and_json_terminal_sync_roundtrip() {
        let api = FakeSessionApi::default();
        let (tx, rx) = mpsc::channel();
        api.next_subscription.lock().unwrap().replace(rx);
        let mut connection = WebSocketSessionConnection::new(api);

        let sync_req = ClientMessage {
            id: Some(json!("sync-1")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: SessionId::new("session-1").unwrap(),
                    client_id: ClientId::new("client-1").unwrap(),
                    mode: AttachMode::InteractiveController,
                    size: Some(SessionSize {
                        rows: 30,
                        cols: 100,
                        pixel_width: 1000,
                        pixel_height: 600,
                        dpi: 144,
                    }),
                    resize_pty: true,
                    restore_if_exited: false,
                    subscribe: true,
                    known_frame_seq: 0,
                },
            },
        };

        let req_bytes = flatbuffers_proto::serialize_client_message(&sync_req);
        let parsed_req = flatbuffers_proto::parse_client_message(
            flatbuffers::root::<fb::ClientMessage>(&req_bytes).unwrap(),
        )
        .unwrap();
        assert_eq!(parsed_req, sync_req);

        let resp_bytes = connection.handle_binary_message(&req_bytes);
        let borrowed = flatbuffers_proto::parse_fb_server_message_borrowed(&resp_bytes).unwrap();
        assert_eq!(
            borrowed,
            flatbuffers_proto::ServerMessageBorrowed::Response {
                id: Some("sync-1"),
                result: flatbuffers_proto::ServerResultBorrowed::SyncTerminal {
                    subscription_id: Some("sub-1"),
                    frame_seq: 1,
                    rows: 30,
                    cols: 100,
                    total_scrollback_rows: 42,
                    viewport_compression: 0,
                    viewport_payload: &[0x54, 0x43, 0x47, 0x31, 0, 0, 0, 0, 0, 0, 0, 0],
                },
            }
        );

        let fetch_req = ClientMessage {
            id: Some(json!("fetch-1")),
            request: ClientRequest::FetchTerminalRows {
                request: FetchTerminalRowsRequest {
                    session_id: SessionId::new("session-1").unwrap(),
                    start_row: 128,
                    row_count: 64,
                },
            },
        };
        let fetch_bytes = flatbuffers_proto::serialize_client_message(&fetch_req);
        let fetch_resp = connection.handle_binary_message(&fetch_bytes);
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&fetch_resp).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::Response {
                id: Some("fetch-1"),
                result: flatbuffers_proto::ServerResultBorrowed::FetchTerminalRows {
                    session_id: "session-1",
                    start_row: 128,
                    row_count: 64,
                    total_scrollback_rows: 1000,
                    compression: 1,
                    payload: &[9, 8, 7, 6],
                },
            }
        );

        let fetch_json = serde_json::to_string(&fetch_req).unwrap();
        let fetch_json_resp: ServerMessage =
            serde_json::from_str(&connection.handle_text_message(&fetch_json)).unwrap();
        assert!(matches!(
            fetch_json_resp,
            ServerMessage::Response {
                result: ServerResult::FetchTerminalRows { .. },
                ..
            }
        ));
        drop(tx);
    }

    #[test]
    fn terminal_sync_coalesces_slow_links_and_holds_mode_2026() {
        let api = FakeSessionApi::default();
        let terminal_seqno = Arc::clone(&api.terminal_seqno);
        let hold_sync = Arc::clone(&api.hold_sync_update);
        let (tx, rx) = mpsc::channel();
        api.next_subscription.lock().unwrap().replace(rx);
        let mut connection = WebSocketSessionConnection::new(api);

        let sync_resp = connection.handle_message(ClientMessage {
            id: Some(json!("sync-init")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: SessionId::new("session-1").unwrap(),
                    client_id: ClientId::new("client-1").unwrap(),
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: true,
                    known_frame_seq: 0,
                },
            },
        });
        assert!(matches!(
            sync_resp,
            ServerMessage::Response {
                result: ServerResult::SyncTerminal { .. },
                ..
            }
        ));
        assert!(connection.drain_events().is_empty());

        // Frame 2 (in_flight becomes 1 < 2)
        *terminal_seqno.lock().unwrap() = 2;
        tx.send(test_output_event(1)).unwrap();
        let drained_1 = connection.drain_events();
        assert_eq!(drained_1.len(), 1);
        assert!(matches!(
            &drained_1[0],
            ServerMessage::Event {
                envelope: SessionEventEnvelope {
                    event: SessionEvent::TerminalSync { frame, .. },
                    ..
                },
                ..
            } if frame.frame_seq == 2
        ));

        // Frame 3 (in_flight becomes 2 == MAX_IN_FLIGHT_SYNC_FRAMES)
        *terminal_seqno.lock().unwrap() = 3;
        tx.send(test_output_event(2)).unwrap();
        let drained_2 = connection.drain_events();
        assert_eq!(drained_2.len(), 1);
        assert!(matches!(
            &drained_2[0],
            ServerMessage::Event {
                envelope: SessionEventEnvelope {
                    event: SessionEvent::TerminalSync { frame, .. },
                    ..
                },
                ..
            } if frame.frame_seq == 3
        ));

        // Burst of 5 more outputs while client has only acked frame 1:
        // raw Output events are suppressed AND frame 4 is held back!
        for i in 3..8 {
            *terminal_seqno.lock().unwrap() = i + 1;
            tx.send(test_output_event(i as u64)).unwrap();
        }
        assert!(connection.drain_events().is_empty());

        // Mode 2026 synchronized update begins before ACK arrives:
        *hold_sync.lock().unwrap() = true;
        let ack_bytes = flatbuffers_proto::serialize_client_message(&ClientMessage {
            id: None,
            request: ClientRequest::AckTerminalSync {
                subscription_id: SubscriptionId::new("sub-1").unwrap(),
                frame_seq: 3,
            },
        });
        // Fire-and-forget ACK produces no response frame.
        assert!(
            connection
                .handle_binary_message_optional(&ack_bytes)
                .is_none()
        );
        // Still held while Mode 2026 is active:
        assert!(connection.drain_events().is_empty());

        // Mode 2026 ends (?2026l): all 5 intermediate outputs collapse into one frame 4!
        *hold_sync.lock().unwrap() = false;
        let drained_3 = connection.drain_events();
        assert_eq!(drained_3.len(), 1);
        match &drained_3[0] {
            ServerMessage::Event {
                envelope:
                    SessionEventEnvelope {
                        event: SessionEvent::TerminalSync { frame, .. },
                        ..
                    },
                ..
            } => {
                assert_eq!(frame.frame_seq, 4);
                assert_eq!(frame.total_scrollback_rows, 42 + 8);
                let ev_bytes = flatbuffers_proto::serialize_server_message(&drained_3[0]);
                assert_eq!(
                    flatbuffers_proto::parse_fb_server_message_borrowed(&ev_bytes).unwrap(),
                    flatbuffers_proto::ServerMessageBorrowed::Event {
                        subscription_id: "sub-1",
                        // Coalesced Output envelopes 3..=7 advance next_synth_event_seq to 7.
                        event_seq: 7,
                        event: flatbuffers_proto::SessionEventBorrowed::TerminalSync {
                            session_id: "session-1",
                            frame_seq: 4,
                            rows: 24,
                            cols: 80,
                            total_scrollback_rows: 50,
                            viewport_compression: 1,
                            viewport_payload: &[1, 2, 3, 4],
                        },
                    }
                );
            }
            other => panic!("unexpected message: {other:?}"),
        }
    }

    #[test]
    fn binary_parse_error_preserves_request_id_and_resync_keeps_subscription_and_events() {
        let api = FakeSessionApi::default();
        let subscribe_calls = Arc::clone(&api.subscribe_calls);
        let fail_sync_once = Arc::clone(&api.fail_sync_once);
        let terminal_seqno = Arc::clone(&api.terminal_seqno);
        let (tx, rx) = mpsc::channel();
        api.next_subscription.lock().unwrap().replace(rx);
        let mut connection = WebSocketSessionConnection::new(api);

        // 1. FlatBuffers message with valid envelope id `"bad-fb-1"` but missing payload
        // returns `ServerMessage::Error` carrying `id: Some("bad-fb-1")`.
        let mut fbb = flatbuffers::FlatBufferBuilder::new();
        let fb_id = fbb.create_string("bad-fb-1");
        let bad_msg = fb::ClientMessage::create(
            &mut fbb,
            &fb::ClientMessageArgs {
                id: Some(fb_id),
                payload_type: fb::ClientRequestPayload::NONE,
                payload: None,
            },
        );
        fbb.finish(bad_msg, None);
        let err_bytes = connection.handle_binary_message(fbb.finished_data());
        assert_eq!(
            flatbuffers_proto::parse_fb_server_message_borrowed(&err_bytes).unwrap(),
            flatbuffers_proto::ServerMessageBorrowed::Error {
                id: Some("bad-fb-1"),
                error: flatbuffers_proto::ProtocolErrorBorrowed {
                    code: "unsupported_payload",
                    message: "The provided FlatBuffers payload type is not recognized or supported by Triage",
                },
            }
        );

        // 2. Initial SyncTerminal subscribes (`subscribe_calls == 1`).
        let sid = SessionId::new("session-1").unwrap();
        let cid = ClientId::new("client-1").unwrap();
        let init_resp = connection.handle_message(ClientMessage {
            id: Some(json!("sync-1")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid.clone(),
                    client_id: cid.clone(),
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: true,
                    known_frame_seq: 0,
                },
            },
        });
        assert!(matches!(init_resp, ServerMessage::Response { .. }));
        assert_eq!(*subscribe_calls.lock().unwrap(), 1);

        // 3. Fallible SyncTerminal with `known_frame_seq: 0` does NOT reset cursor when RPC fails.
        *fail_sync_once.lock().unwrap() = true;
        let failed_sync = connection.handle_message(ClientMessage {
            id: Some(json!("sync-fail")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid.clone(),
                    client_id: cid.clone(),
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: false,
                    known_frame_seq: 0,
                },
            },
        });
        assert!(matches!(failed_sync, ServerMessage::Error { .. }));
        assert!(
            connection.terminal_sync_subs[&SubscriptionId::new("sub-1").unwrap()]
                .cursor
                .primary
                .initialized
        );

        // 4. Queue a LeaseChanged + Snapshot (with legacy rows) before a `subscribe: false`
        // resize SyncTerminal: subscription stays active without calling `subscribe_session_events`
        // again, LeaseChanged survives, and Snapshot has legacy rows stripped!
        let mut noisy_snapshot = test_snapshot();
        noisy_snapshot.visible_rows = vec!["legacy-row".to_string()];
        noisy_snapshot.raw_output = vec![1, 2, 3];
        tx.send(SessionEventEnvelope {
            event_seq: 10,
            event: SessionEvent::LeaseChanged {
                session_id: sid.clone(),
                change: InputLeaseState::default().acquire(
                    cid.clone(),
                    triage_core::session::InputControllerKind::Interactive,
                ),
            },
        })
        .unwrap();
        tx.send(SessionEventEnvelope {
            event_seq: 11,
            event: SessionEvent::Snapshot {
                session_id: sid.clone(),
                snapshot: noisy_snapshot,
            },
        })
        .unwrap();

        let resize_resp = connection.handle_message(ClientMessage {
            id: Some(json!("sync-resize")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid.clone(),
                    client_id: cid,
                    mode: AttachMode::InteractiveController,
                    size: None,
                    resize_pty: true,
                    restore_if_exited: false,
                    subscribe: false,
                    known_frame_seq: 1,
                },
            },
        });
        match resize_resp {
            ServerMessage::Response {
                result: ServerResult::SyncTerminal { response },
                ..
            } => {
                assert_eq!(response.subscription_id.as_deref(), Some("sub-1"));
                assert_eq!(response.frame.frame_seq, 2);
            }
            other => panic!("unexpected resize resp: {other:?}"),
        }
        assert_eq!(*subscribe_calls.lock().unwrap(), 1);

        // 5. Out-of-range AckTerminalSync (`u64::MAX`) clamps to `next_frame_seq` (2) so
        // flow control still throttles after 2 unacked frames!
        let _ = connection.handle_message(ClientMessage {
            id: None,
            request: ClientRequest::AckTerminalSync {
                subscription_id: SubscriptionId::new("sub-1").unwrap(),
                frame_seq: u64::MAX,
            },
        });
        assert_eq!(
            connection.terminal_sync_subs[&SubscriptionId::new("sub-1").unwrap()]
                .last_acked_frame_seq,
            2
        );

        let drained = connection.drain_events();
        assert_eq!(drained.len(), 2);
        assert!(matches!(
            &drained[0],
            ServerMessage::Event {
                envelope: SessionEventEnvelope {
                    event: SessionEvent::LeaseChanged { .. },
                    ..
                },
                ..
            }
        ));
        match &drained[1] {
            ServerMessage::Event {
                envelope:
                    SessionEventEnvelope {
                        event: SessionEvent::Snapshot { snapshot, .. },
                        ..
                    },
                ..
            } => {
                assert!(snapshot.visible_rows.is_empty());
                assert!(snapshot.raw_output.is_empty());
            }
            other => panic!("expected stripped Snapshot event, got {other:?}"),
        }

        // Confirm subscription is still live after `subscribe: false` sync!
        *terminal_seqno.lock().unwrap() = 5;
        tx.send(test_output_event(12)).unwrap();
        assert_eq!(connection.drain_events().len(), 1);
    }

    #[test]
    fn resync_lifecycle_preserves_generations_handles_resync_required_and_retries_poll_error() {
        let api = FakeSessionApi::default();
        let fail_poll_once = Arc::clone(&api.fail_poll_once);
        let exited_snapshot = Arc::clone(&api.exited_snapshot);
        let terminal_seqno = Arc::clone(&api.terminal_seqno);
        let (tx, rx) = mpsc::channel();
        api.next_subscription.lock().unwrap().replace(rx);
        let mut connection = WebSocketSessionConnection::new(api);

        let sid = SessionId::new("session-1").unwrap();
        let cid = ClientId::new("client-1").unwrap();
        let sub_id = SubscriptionId::new("sub-1").unwrap();
        let _ = connection.handle_message(ClientMessage {
            id: Some(json!("init")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid.clone(),
                    client_id: cid.clone(),
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: true,
                    known_frame_seq: 0,
                },
            },
        });

        // 1. Seed non-zero generation counters on the subscription cursor and force a
        // full re-sync (`known_frame_seq: 0`): `reset_viewport_keep_generations` resets
        // viewport initialization without zeroing `last_alt_screen` or bell/erase gens.
        {
            let sub = connection.terminal_sync_subs.get_mut(&sub_id).unwrap();
            sub.cursor.last_alt_screen = Some(false);
            sub.cursor.last_bell_gen = 9;
            sub.cursor.last_erase_scrollback_gen = 4;
            sub.cursor.last_title_gen = 12;
        }
        let _ = connection.handle_message(ClientMessage {
            id: Some(json!("resync-full")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid.clone(),
                    client_id: cid.clone(),
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: true,
                    known_frame_seq: 0,
                },
            },
        });
        {
            let sub = &connection.terminal_sync_subs[&sub_id];
            assert_eq!(sub.cursor.last_alt_screen, Some(false));
            assert_eq!(sub.cursor.last_bell_gen, 9);
            assert_eq!(sub.cursor.last_erase_scrollback_gen, 4);
            assert_eq!(sub.cursor.last_title_gen, 11);
        }

        // 2. `ResyncRequired` emits a stripped `Snapshot`, and a transient `poll_terminal_sync`
        // error keeps `dirty = true` for one retry tick rather than wedging updates.
        let mut overflow_snap = test_snapshot();
        overflow_snap.visible_rows = vec!["heavy".to_string()];
        overflow_snap.raw_output = vec![9, 9];
        *terminal_seqno.lock().unwrap() = 10;
        *fail_poll_once.lock().unwrap() = true;
        tx.send(SessionEventEnvelope {
            event_seq: 20,
            event: SessionEvent::ResyncRequired {
                session_id: sid.clone(),
                latest_event_seq: 20,
                snapshot: overflow_snap,
            },
        })
        .unwrap();

        let first_drain = connection.drain_events();
        assert_eq!(first_drain.len(), 1);
        match &first_drain[0] {
            ServerMessage::Event {
                envelope:
                    SessionEventEnvelope {
                        event: SessionEvent::Snapshot { snapshot, .. },
                        ..
                    },
                ..
            } => {
                assert!(snapshot.visible_rows.is_empty());
                assert!(snapshot.raw_output.is_empty());
            }
            other => panic!("expected stripped Snapshot from ResyncRequired, got {other:?}"),
        }

        // Retry tick recovers the `TerminalSync` frame without needing new PTY output.
        let retry_drain = connection.drain_events();
        assert_eq!(retry_drain.len(), 1);
        assert!(matches!(
            &retry_drain[0],
            ServerMessage::Event {
                envelope: SessionEventEnvelope {
                    event: SessionEvent::TerminalSync { .. },
                    ..
                },
                ..
            }
        ));

        // 2b. `ResyncRequired` with `snapshot.exited == true` flushes the final
        // `TerminalSync` frame, emits a stripped `Snapshot`, and synthesizes
        // `SessionEvent::Exited` so replay-buffer overflow on child exit never
        // strands the client in an attached state.
        let mut exited_overflow_snap = test_snapshot();
        exited_overflow_snap.exited = true;
        exited_overflow_snap.output_seq = 99;
        exited_overflow_snap.bytes_logged = 4096;
        *terminal_seqno.lock().unwrap() = 11;
        tx.send(SessionEventEnvelope {
            event_seq: 21,
            event: SessionEvent::ResyncRequired {
                session_id: sid.clone(),
                latest_event_seq: 21,
                snapshot: exited_overflow_snap,
            },
        })
        .unwrap();

        let exited_resync_drain = connection.drain_events();
        assert_eq!(exited_resync_drain.len(), 3);
        assert!(matches!(
            &exited_resync_drain[0],
            ServerMessage::Event {
                envelope: SessionEventEnvelope {
                    event: SessionEvent::TerminalSync { .. },
                    ..
                },
                ..
            }
        ));
        assert!(matches!(
            &exited_resync_drain[1],
            ServerMessage::Event {
                envelope: SessionEventEnvelope {
                    event: SessionEvent::Snapshot { snapshot, .. },
                    ..
                },
                ..
            } if snapshot.exited && snapshot.visible_rows.is_empty()
        ));
        assert!(matches!(
            &exited_resync_drain[2],
            ServerMessage::Event {
                envelope: SessionEventEnvelope {
                    event: SessionEvent::Exited { completed, .. },
                    ..
                },
                ..
            } if completed.output_seq == 99 && completed.bytes_logged == 4096
        ));
        assert!(connection.drain_events().is_empty());

        // 3. If the session exited before a re-sync, queued events on the closing channel
        // are discarded rather than emitted alongside `SubscriptionClosed`.
        tx.send(SessionEventEnvelope {
            event_seq: 22,
            event: SessionEvent::LeaseChanged {
                session_id: sid.clone(),
                change: InputLeaseState::default().acquire(
                    cid.clone(),
                    triage_core::session::InputControllerKind::Interactive,
                ),
            },
        })
        .unwrap();
        *exited_snapshot.lock().unwrap() = true;
        let exit_sync = connection.handle_message(ClientMessage {
            id: Some(json!("exit-sync")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid,
                    client_id: cid,
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: true,
                    known_frame_seq: 0,
                },
            },
        });
        match exit_sync {
            ServerMessage::Response {
                result: ServerResult::SyncTerminal { response },
                ..
            } => {
                assert!(response.subscription_id.is_none());
                assert!(response.snapshot.exited);
            }
            other => panic!("unexpected exit_sync: {other:?}"),
        }
        let post_exit = connection.drain_events();
        assert_eq!(
            post_exit,
            vec![ServerMessage::SubscriptionClosed {
                subscription_id: sub_id,
            }]
        );
    }

    #[test]
    fn reauth_hello_clears_subscriptions_event_seq_stays_monotonic_and_actor_revival_resets_gens() {
        let auth = FakeAuthenticator {
            require_pairing: true,
            pairing_code: "123456".to_string(),
            paired_token: "secret-token".to_string(),
            client_id: ClientId::new("phone").unwrap(),
        };
        let api = FakeSessionApi::default();
        let subscribe_calls = Arc::clone(&api.subscribe_calls);
        let terminal_seqno = Arc::clone(&api.terminal_seqno);
        let (tx1, rx1) = mpsc::channel();
        api.next_subscription.lock().unwrap().replace(rx1);
        let next_sub_slot = Arc::clone(&api.next_subscription);
        let mut connection = WebSocketSessionConnection::with_authenticator(api, auth);

        let sid = SessionId::new("session-1").unwrap();
        let cid = ClientId::new("phone").unwrap();
        let sub_id = SubscriptionId::new("sub-1").unwrap();

        // Authenticate via Hello, establish SyncTerminal subscription, then send invalid Hello:
        // connection must become unauthenticated and drop prior subscriptions + pending events.
        let ok_hello = connection.handle_message(ClientMessage {
            id: Some(json!("h1")),
            request: ClientRequest::Hello {
                client_id: Some(cid.clone()),
                token: Some("secret-token".to_string()),
            },
        });
        assert!(matches!(ok_hello, ServerMessage::Response { .. }));

        let sync1 = connection.handle_message(ClientMessage {
            id: Some(json!("s1")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid.clone(),
                    client_id: cid.clone(),
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: true,
                    known_frame_seq: 0,
                },
            },
        });
        assert!(matches!(sync1, ServerMessage::Response { .. }));
        assert_eq!(connection.terminal_sync_subs.len(), 1);

        let bad_hello = connection.handle_message(ClientMessage {
            id: Some(json!("h2")),
            request: ClientRequest::Hello {
                client_id: Some(cid.clone()),
                token: Some("wrong-token".to_string()),
            },
        });
        assert!(matches!(bad_hello, ServerMessage::Response { .. }));
        assert!(connection.terminal_sync_subs.is_empty());
        assert!(connection.subscriptions.is_empty());
        *terminal_seqno.lock().unwrap() = 5;
        let _ = tx1.send(test_output_event(10));
        assert!(connection.drain_events().is_empty());

        // Re-authenticate, subscribe fresh rx2, and verify actor revival (`rx_disconnected`
        // on an active non-exited session) resets stale generation counters while advancing
        // `frame_seq` monotonically.
        let _ = connection.handle_message(ClientMessage {
            id: Some(json!("h3")),
            request: ClientRequest::Hello {
                client_id: Some(cid.clone()),
                token: Some("secret-token".to_string()),
            },
        });
        let (tx2, rx2) = mpsc::channel();
        next_sub_slot.lock().unwrap().replace(rx2);
        let _ = connection.handle_message(ClientMessage {
            id: Some(json!("s2")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid.clone(),
                    client_id: cid.clone(),
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: true,
                    known_frame_seq: 0,
                },
            },
        });
        let sub_id_2 = SubscriptionId::new("sub-2").unwrap();
        {
            let sub = connection.terminal_sync_subs.get_mut(&sub_id_2).unwrap();
            sub.cursor.next_frame_seq = 15;
            sub.cursor.last_bell_gen = 99;
            sub.cursor.last_erase_scrollback_gen = 44;
        }
        // Simulate actor restart: drop old sender tx2 and stage fresh rx3 for replacement.
        drop(tx2);
        let (tx3, rx3) = mpsc::channel();
        next_sub_slot.lock().unwrap().replace(rx3);
        let revived_resp = connection.handle_message(ClientMessage {
            id: Some(json!("s3")),
            request: ClientRequest::SyncTerminal {
                request: SyncTerminalRequest {
                    session_id: sid.clone(),
                    client_id: cid.clone(),
                    mode: AttachMode::Observer,
                    size: None,
                    resize_pty: false,
                    restore_if_exited: false,
                    subscribe: false,
                    known_frame_seq: 15,
                },
            },
        });
        match revived_resp {
            ServerMessage::Response {
                result: ServerResult::SyncTerminal { response },
                ..
            } => {
                assert_eq!(response.subscription_id, Some("sub-2".to_string()));
                assert!(response.frame.frame_seq > 15);
            }
            other => panic!("expected revived SyncTerminal response, got {other:?}"),
        }
        assert_eq!(*subscribe_calls.lock().unwrap(), 3);
        assert_eq!(
            connection.terminal_sync_subs[&sub_id_2]
                .cursor
                .last_bell_gen,
            0
        );
        assert_eq!(
            connection.terminal_sync_subs[&sub_id_2]
                .cursor
                .last_erase_scrollback_gen,
            0
        );

        // Verify event_seq stays strictly monotonic across real events and synthesized
        // TerminalSync / Snapshot / Exited envelopes.
        let mut exited_snap = test_snapshot();
        exited_snap.exited = true;
        *terminal_seqno.lock().unwrap() = 20;
        tx3.send(SessionEventEnvelope {
            event_seq: 50,
            event: SessionEvent::LeaseChanged {
                session_id: sid.clone(),
                change: InputLeaseState::default()
                    .acquire(cid, triage_core::session::InputControllerKind::Interactive),
            },
        })
        .unwrap();
        tx3.send(SessionEventEnvelope {
            event_seq: 51,
            event: SessionEvent::ResyncRequired {
                session_id: sid,
                latest_event_seq: 51,
                snapshot: exited_snap,
            },
        })
        .unwrap();
        let _ = sub_id;
        let drained = connection.drain_events();
        let seqs: Vec<u64> = drained
            .iter()
            .filter_map(|m| match m {
                ServerMessage::Event { envelope, .. } => Some(envelope.event_seq),
                _ => None,
            })
            .collect();
        assert_eq!(seqs.len(), 4);
        for pair in seqs.windows(2) {
            assert!(
                pair[1] > pair[0],
                "expected strictly increasing event_seq, got {seqs:?}"
            );
        }
    }
}
