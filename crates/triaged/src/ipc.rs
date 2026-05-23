use std::fs;
use std::io::{BufRead, BufReader, BufWriter, ErrorKind, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use triage_core::session::{
    AttachSessionRequest, AttachSessionResponse, ClientId, CompletedSession, InputLeaseRequest,
    LeaseChange, ResizeSessionRequest, RestoreSessionRequest, SessionApi, SessionEventEnvelope,
    SessionEventReceiver, SessionId, SessionSnapshot, StartSessionRequest, StyledRowsRequest,
    StyledRowsResponse, SubscribeSessionEventsRequest, WriteInputRequest,
};

use crate::session::SessionManager;

const SUBSCRIPTION_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnixSocketConfig {
    pub socket_path: PathBuf,
}

impl UnixSocketConfig {
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
        }
    }
}

pub struct UnixSocketServer {
    manager: Arc<SessionManager>,
    config: UnixSocketConfig,
}

impl UnixSocketServer {
    pub fn new(manager: Arc<SessionManager>, config: UnixSocketConfig) -> Self {
        Self { manager, config }
    }

    pub fn serve(self) -> Result<()> {
        let listener = bind_owner_socket(&self.config.socket_path)?;

        loop {
            match listener.accept() {
                Ok((stream, _addr)) => {
                    let manager = Arc::clone(&self.manager);
                    if let Err(error) = thread::Builder::new()
                        .name("triage-ipc-client".to_string())
                        .spawn(move || {
                            if let Err(error) = handle_connection(manager, stream)
                                && !is_closed_socket_error(&error)
                            {
                                tracing::warn!(error = ?error, "Unix socket client failed");
                            }
                        })
                    {
                        tracing::warn!(error = ?error, "failed to spawn Unix socket client handler");
                    }
                }
                Err(error) => {
                    tracing::warn!(error = ?error, "failed to accept Unix socket connection");
                }
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnixSocketClient {
    socket_path: PathBuf,
}

impl UnixSocketClient {
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
        }
    }

    fn round_trip(&self, request: WireRequest) -> Result<WireSuccess> {
        let mut stream = UnixStream::connect(&self.socket_path)
            .with_context(|| format!("connecting to {}", self.socket_path.display()))?;
        write_json_line(&mut stream, &request).context("writing Unix socket request")?;
        stream
            .shutdown(std::net::Shutdown::Write)
            .context("finishing Unix socket request")?;

        let mut reader = BufReader::new(stream);
        let response: WireResponse = read_json_line(&mut reader)?.context("reading response")?;
        response.into_result()
    }
}

pub fn default_socket_path() -> PathBuf {
    if let Some(runtime_dir) = std::env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime_dir).join("triage/triage.sock");
    }

    std::env::temp_dir()
        .join(format!("triage-{}", fallback_user_component()))
        .join("triage.sock")
}

impl SessionApi for UnixSocketClient {
    fn list_sessions(&self) -> Result<Vec<SessionId>> {
        match self.round_trip(WireRequest::ListSessions)? {
            WireSuccess::SessionIds(session_ids) => Ok(session_ids),
            other => bail!("unexpected list_sessions response: {other:?}"),
        }
    }

    fn start_session(&self, request: StartSessionRequest) -> Result<SessionId> {
        match self.round_trip(WireRequest::StartSession(request))? {
            WireSuccess::SessionId(session_id) => Ok(session_id),
            other => bail!("unexpected start_session response: {other:?}"),
        }
    }

    fn attach_session(&self, request: AttachSessionRequest) -> Result<AttachSessionResponse> {
        match self.round_trip(WireRequest::AttachSession(request))? {
            WireSuccess::AttachSession(response) => Ok(response),
            other => bail!("unexpected attach_session response: {other:?}"),
        }
    }

    fn subscribe_session_events(&self, session_id: SessionId) -> Result<SessionEventReceiver> {
        self.subscribe_session_events_from(SubscribeSessionEventsRequest {
            session_id,
            after_event_seq: None,
        })
    }

    fn subscribe_session_events_from(
        &self,
        request: SubscribeSessionEventsRequest,
    ) -> Result<SessionEventReceiver> {
        let mut stream = UnixStream::connect(&self.socket_path)
            .with_context(|| format!("connecting to {}", self.socket_path.display()))?;
        write_json_line(
            &mut stream,
            &WireRequest::SubscribeSessionEvents {
                session_id: request.session_id,
                after_event_seq: request.after_event_seq,
            },
        )
        .context("writing Unix socket subscribe request")?;
        stream
            .shutdown(std::net::Shutdown::Write)
            .context("finishing Unix socket subscribe request")?;

        let mut reader = BufReader::new(stream.try_clone().context("cloning subscription stream")?);
        let response: WireResponse =
            read_json_line(&mut reader)?.context("reading subscribe response")?;
        match response.into_result()? {
            WireSuccess::Subscribed => {}
            other => bail!("unexpected subscribe response: {other:?}"),
        }

        let (tx, rx) = mpsc::channel();
        thread::Builder::new()
            .name("triage-ipc-events".to_string())
            .spawn(move || {
                for line in reader.lines() {
                    let Ok(line) = line else {
                        break;
                    };
                    let Ok(response) = serde_json::from_str::<WireResponse>(&line) else {
                        break;
                    };
                    match response.into_result() {
                        Ok(WireSuccess::SessionEvent(envelope)) => {
                            if tx.send(envelope).is_err() {
                                break;
                            }
                        }
                        Ok(WireSuccess::Heartbeat) => {}
                        _ => break,
                    }
                }
            })
            .context("spawning Unix socket event reader")?;

        Ok(rx)
    }

    fn acquire_input_lease(&self, request: InputLeaseRequest) -> Result<LeaseChange> {
        match self.round_trip(WireRequest::AcquireInputLease(request))? {
            WireSuccess::LeaseChange(change) => Ok(change),
            other => bail!("unexpected acquire_input_lease response: {other:?}"),
        }
    }

    fn release_input_lease(
        &self,
        session_id: SessionId,
        client_id: ClientId,
    ) -> Result<LeaseChange> {
        match self.round_trip(WireRequest::ReleaseInputLease {
            session_id,
            client_id,
        })? {
            WireSuccess::LeaseChange(change) => Ok(change),
            other => bail!("unexpected release_input_lease response: {other:?}"),
        }
    }

    fn write_input(&self, request: WriteInputRequest) -> Result<()> {
        match self.round_trip(WireRequest::WriteInput(request))? {
            WireSuccess::Unit => Ok(()),
            other => bail!("unexpected write_input response: {other:?}"),
        }
    }

    fn resize_session(&self, request: ResizeSessionRequest) -> Result<SessionSnapshot> {
        match self.round_trip(WireRequest::ResizeSession(request))? {
            WireSuccess::SessionSnapshot(snapshot) => Ok(snapshot),
            other => bail!("unexpected resize_session response: {other:?}"),
        }
    }

    fn restore_session(&self, request: RestoreSessionRequest) -> Result<SessionSnapshot> {
        match self.round_trip(WireRequest::RestoreSession(request))? {
            WireSuccess::SessionSnapshot(snapshot) => Ok(snapshot),
            other => bail!("unexpected restore_session response: {other:?}"),
        }
    }

    fn snapshot_session(&self, session_id: SessionId) -> Result<SessionSnapshot> {
        match self.round_trip(WireRequest::SnapshotSession { session_id })? {
            WireSuccess::SessionSnapshot(snapshot) => Ok(snapshot),
            other => bail!("unexpected snapshot_session response: {other:?}"),
        }
    }

    fn styled_rows(&self, request: StyledRowsRequest) -> Result<StyledRowsResponse> {
        match self.round_trip(WireRequest::StyledRows(request))? {
            WireSuccess::StyledRows(response) => Ok(response),
            other => bail!("unexpected styled_rows response: {other:?}"),
        }
    }

    fn shutdown_session(&self, session_id: SessionId) -> Result<CompletedSession> {
        match self.round_trip(WireRequest::ShutdownSession { session_id })? {
            WireSuccess::CompletedSession(completed) => Ok(completed),
            other => bail!("unexpected shutdown_session response: {other:?}"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
enum WireRequest {
    ListSessions,
    StartSession(StartSessionRequest),
    AttachSession(AttachSessionRequest),
    SubscribeSessionEvents {
        session_id: SessionId,
        after_event_seq: Option<u64>,
    },
    AcquireInputLease(InputLeaseRequest),
    ReleaseInputLease {
        session_id: SessionId,
        client_id: ClientId,
    },
    WriteInput(WriteInputRequest),
    ResizeSession(ResizeSessionRequest),
    RestoreSession(RestoreSessionRequest),
    SnapshotSession {
        session_id: SessionId,
    },
    StyledRows(StyledRowsRequest),
    ShutdownSession {
        session_id: SessionId,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
enum WireResponse {
    Ok(Box<WireSuccess>),
    Err { message: String },
}

impl WireResponse {
    fn from_result(result: Result<WireSuccess>) -> Self {
        match result {
            Ok(success) => Self::Ok(Box::new(success)),
            Err(error) => Self::Err {
                message: error.to_string(),
            },
        }
    }

    fn into_result(self) -> Result<WireSuccess> {
        match self {
            Self::Ok(success) => Ok(*success),
            Self::Err { message } => Err(anyhow!(message)),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
enum WireSuccess {
    Unit,
    SessionIds(Vec<SessionId>),
    SessionId(SessionId),
    AttachSession(AttachSessionResponse),
    LeaseChange(LeaseChange),
    SessionSnapshot(SessionSnapshot),
    StyledRows(StyledRowsResponse),
    CompletedSession(CompletedSession),
    Subscribed,
    SessionEvent(SessionEventEnvelope),
    Heartbeat,
}

fn fallback_user_component() -> String {
    std::env::var("UID")
        .or_else(|_| {
            current_user_uid()
                .map(|uid| uid.to_string())
                .ok_or(std::env::VarError::NotPresent)
        })
        .or_else(|_| std::env::var("USER"))
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(sanitize_path_component)
        .unwrap_or_else(|| format!("pid-{}", std::process::id()))
}

fn current_user_uid() -> Option<u32> {
    let home = std::env::var_os("HOME")?;
    fs::metadata(home).map(|metadata| metadata.uid()).ok()
}

fn sanitize_path_component(value: String) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '_'
            }
        })
        .collect()
}

fn bind_owner_socket(socket_path: &Path) -> Result<UnixListener> {
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating socket directory {}", parent.display()))?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("securing socket directory {}", parent.display()))?;
    }

    if socket_path.exists() {
        match UnixStream::connect(socket_path) {
            Ok(_) => bail!("Unix socket {} is already in use", socket_path.display()),
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::ConnectionRefused | ErrorKind::NotFound
                ) =>
            {
                fs::remove_file(socket_path)
                    .with_context(|| format!("removing stale socket {}", socket_path.display()))?;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("checking existing socket {}", socket_path.display())
                });
            }
        }
    }

    let listener = UnixListener::bind(socket_path)
        .with_context(|| format!("binding Unix socket {}", socket_path.display()))?;
    fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("securing Unix socket {}", socket_path.display()))?;
    Ok(listener)
}

fn handle_connection(manager: Arc<SessionManager>, stream: UnixStream) -> Result<()> {
    let mut reader = BufReader::new(stream.try_clone().context("cloning Unix socket stream")?);
    let request: WireRequest = read_json_line(&mut reader)?.context("reading request")?;
    let mut writer = BufWriter::new(stream);

    if let WireRequest::SubscribeSessionEvents {
        session_id,
        after_event_seq,
    } = request
    {
        return handle_subscription(&manager, session_id, after_event_seq, &mut writer);
    }

    let response = WireResponse::from_result(handle_request(&manager, request));
    write_json_line(&mut writer, &response).context("writing response")?;
    writer.flush().context("flushing response")?;
    Ok(())
}

fn handle_subscription(
    manager: &SessionManager,
    session_id: SessionId,
    after_event_seq: Option<u64>,
    writer: &mut BufWriter<UnixStream>,
) -> Result<()> {
    match manager.subscribe_session_events_from(SubscribeSessionEventsRequest {
        session_id,
        after_event_seq,
    }) {
        Ok(events) => {
            write_json_line(writer, &WireResponse::Ok(Box::new(WireSuccess::Subscribed)))
                .context("writing subscribe response")?;
            writer.flush().context("flushing subscribe response")?;

            loop {
                match events.recv_timeout(SUBSCRIPTION_HEARTBEAT_INTERVAL) {
                    Ok(event) => {
                        write_json_line(
                            writer,
                            &WireResponse::Ok(Box::new(WireSuccess::SessionEvent(event))),
                        )
                        .context("writing session event")?;
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        write_json_line(
                            writer,
                            &WireResponse::Ok(Box::new(WireSuccess::Heartbeat)),
                        )
                        .context("writing subscription heartbeat")?;
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
                writer.flush().context("flushing subscription response")?;
            }
            Ok(())
        }
        Err(error) => {
            write_json_line(
                writer,
                &WireResponse::Err {
                    message: error.to_string(),
                },
            )
            .context("writing subscribe error")?;
            writer.flush().context("flushing subscribe error")?;
            Ok(())
        }
    }
}

fn handle_request(manager: &SessionManager, request: WireRequest) -> Result<WireSuccess> {
    match request {
        WireRequest::ListSessions => manager.list_sessions().map(WireSuccess::SessionIds),
        WireRequest::StartSession(request) => {
            manager.start_session(request).map(WireSuccess::SessionId)
        }
        WireRequest::AttachSession(request) => manager
            .attach_session(request)
            .map(WireSuccess::AttachSession),
        WireRequest::SubscribeSessionEvents { .. } => {
            bail!("subscription requests require streaming handler")
        }
        WireRequest::AcquireInputLease(request) => manager
            .acquire_input_lease(request)
            .map(WireSuccess::LeaseChange),
        WireRequest::ReleaseInputLease {
            session_id,
            client_id,
        } => manager
            .release_input_lease(session_id, client_id)
            .map(WireSuccess::LeaseChange),
        WireRequest::WriteInput(request) => {
            manager.write_input(request).map(|()| WireSuccess::Unit)
        }
        WireRequest::ResizeSession(request) => manager
            .resize_session(request)
            .map(WireSuccess::SessionSnapshot),
        WireRequest::RestoreSession(request) => manager
            .restore_session(request)
            .map(WireSuccess::SessionSnapshot),
        WireRequest::SnapshotSession { session_id } => manager
            .snapshot_session(session_id)
            .map(WireSuccess::SessionSnapshot),
        WireRequest::StyledRows(request) => {
            manager.styled_rows(request).map(WireSuccess::StyledRows)
        }
        WireRequest::ShutdownSession { session_id } => manager
            .shutdown_session(session_id)
            .map(WireSuccess::CompletedSession),
    }
}

fn read_json_line<T: for<'de> Deserialize<'de>>(reader: &mut impl BufRead) -> Result<Option<T>> {
    let mut line = String::new();
    let read = reader.read_line(&mut line).context("reading JSON line")?;
    if read == 0 {
        return Ok(None);
    }
    serde_json::from_str(&line)
        .context("decoding JSON line")
        .map(Some)
}

fn write_json_line<T: Serialize>(writer: &mut impl Write, value: &T) -> Result<()> {
    serde_json::to_writer(&mut *writer, value).context("encoding JSON line")?;
    writer.write_all(b"\n").context("terminating JSON line")
}

fn is_closed_socket_error(error: &anyhow::Error) -> bool {
    error
        .root_cause()
        .downcast_ref::<std::io::Error>()
        .is_some_and(|io_error| {
            matches!(
                io_error.kind(),
                ErrorKind::BrokenPipe | ErrorKind::ConnectionReset | ErrorKind::UnexpectedEof
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::SessionManagerConfig;
    use std::time::{Duration, Instant};
    use triage_core::session::{AttachMode, RestoreSessionRequest, SessionEvent, SessionSize};

    #[test]
    fn client_reports_server_errors() {
        let socket_path = unique_socket_path("ms");
        let log_dir = unique_dir("ms-logs");
        let manager = Arc::new(SessionManager::new(SessionManagerConfig::new(
            log_dir.clone(),
        )));
        let server = UnixSocketServer::new(
            Arc::clone(&manager),
            UnixSocketConfig::new(socket_path.clone()),
        );
        spawn_server(server);

        let client = UnixSocketClient::new(socket_path.clone());
        let missing = SessionId::new("missing").expect("session id");
        let error = client
            .snapshot_session(missing)
            .expect_err("missing snapshot should fail");

        assert!(error.to_string().contains("not found"));
        let _ = fs::remove_file(socket_path);
        let _ = fs::remove_dir_all(log_dir);
    }

    #[test]
    fn closed_socket_errors_are_expected_client_disconnects() {
        let error = Err::<(), _>(std::io::Error::from(ErrorKind::BrokenPipe))
            .context("flushing subscription response")
            .expect_err("broken pipe should stay an error");

        assert!(is_closed_socket_error(&error));
    }

    #[test]
    fn closed_socket_detection_only_matches_root_cause() {
        let error = anyhow!(
            "flushing subscription response: {}",
            std::io::Error::from(ErrorKind::BrokenPipe)
        );

        assert!(!is_closed_socket_error(&error));
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY behavior needs a dedicated Windows lifecycle test"
    )]
    fn client_drives_session_over_unix_socket() {
        let socket_path = unique_socket_path("lc");
        let log_dir = unique_dir("lc-logs");
        let manager = Arc::new(SessionManager::new(SessionManagerConfig::new(
            log_dir.clone(),
        )));
        let server = UnixSocketServer::new(
            Arc::clone(&manager),
            UnixSocketConfig::new(socket_path.clone()),
        );
        spawn_server(server);

        let client = UnixSocketClient::new(socket_path.clone());
        let client_id = ClientId::new("test-client").expect("client id");
        let mut request = StartSessionRequest::new("/bin/sh");
        request.args = vec!["-lc".to_string(), "cat".to_string()];
        request.size = SessionSize::default();
        let session_id = client.start_session(request).expect("start session");
        assert!(
            client
                .list_sessions()
                .expect("list sessions")
                .contains(&session_id)
        );
        let events = client
            .subscribe_session_events(session_id.clone())
            .expect("subscribe events");
        client
            .attach_session(AttachSessionRequest {
                session_id: session_id.clone(),
                client_id: client_id.clone(),
                mode: AttachMode::InteractiveController,
            })
            .expect("attach session");
        client
            .write_input(WriteInputRequest {
                session_id: session_id.clone(),
                client_id,
                bytes: b"socket-ready\n".to_vec(),
            })
            .expect("write input");

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let snapshot = client
                .snapshot_session(session_id.clone())
                .expect("snapshot session");
            if snapshot
                .visible_rows
                .iter()
                .any(|row| row.contains("socket-ready"))
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for socket output: {:?}",
                snapshot.visible_rows
            );
            std::thread::sleep(Duration::from_millis(20));
        }

        wait_for_output_event(&events);
        client
            .shutdown_session(session_id)
            .expect("shutdown session");
        let _ = fs::remove_file(socket_path);
        let _ = fs::remove_dir_all(log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY behavior needs a dedicated Windows lifecycle test"
    )]
    fn client_restores_historical_shell_over_unix_socket() {
        let socket_path = unique_socket_path("rs");
        let log_dir = unique_dir("rs-logs");
        fs::create_dir_all(&log_dir).expect("create log dir");
        let session_id = SessionId::new("session-7").expect("session id");
        let log_path = log_dir.join("session-7.log");
        fs::write(&log_path, b"socket-history\r\n").expect("write session log");
        let manifest = serde_json::json!({
            "version": 1,
            "sessions": [{
                "id": session_id,
                "command": long_running_shell_command(),
                "args": [],
                "cwd": null,
                "size": {
                    "rows": 6,
                    "cols": 40,
                    "pixel_width": 800,
                    "pixel_height": 240,
                    "dpi": 96
                },
                "log_path": log_path,
                "exited": false
            }]
        });
        fs::write(
            log_dir.join("sessions.json"),
            serde_json::to_vec(&manifest).expect("encode manifest"),
        )
        .expect("write manifest");
        let manager = Arc::new(SessionManager::new(SessionManagerConfig::new(
            log_dir.clone(),
        )));
        let server = UnixSocketServer::new(
            Arc::clone(&manager),
            UnixSocketConfig::new(socket_path.clone()),
        );
        spawn_server(server);
        let client = UnixSocketClient::new(socket_path.clone());

        let snapshot = client
            .restore_session(RestoreSessionRequest {
                session_id: SessionId::new("session-7").expect("session id"),
                size: SessionSize {
                    rows: 6,
                    cols: 40,
                    pixel_width: 800,
                    pixel_height: 240,
                    dpi: 96,
                },
            })
            .expect("restore session over socket");

        assert!(!snapshot.exited);
        assert!(
            snapshot
                .visible_rows
                .iter()
                .any(|row| row.contains("socket-history")),
            "restored socket snapshot lost historical rows: {:?}",
            snapshot.visible_rows
        );
        manager
            .shutdown_session(SessionId::new("session-7").expect("session id"))
            .expect("shutdown restored socket session");
        let _ = fs::remove_file(socket_path);
        let _ = fs::remove_dir_all(log_dir);
    }

    fn spawn_server(server: UnixSocketServer) {
        let socket_path = server.config.socket_path.clone();
        let (tx, rx) = mpsc::channel();
        thread::Builder::new()
            .name("triage-ipc-test-server".to_string())
            .spawn(move || {
                let result = server.serve();
                let _ = tx.send(result.map_err(|error| format!("{error:#}")));
            })
            .expect("spawn server");

        let deadline = Instant::now() + Duration::from_secs(1);
        while !socket_path.exists() {
            if let Ok(result) = rx.try_recv() {
                result.expect("test server failed");
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for test socket"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn unique_socket_path(name: &str) -> PathBuf {
        unique_dir(name).join("triage.sock")
    }

    fn unique_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "triage-ipc-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ))
    }

    #[cfg(windows)]
    fn long_running_shell_command() -> &'static str {
        "cmd.exe"
    }

    #[cfg(not(windows))]
    fn long_running_shell_command() -> &'static str {
        "/bin/sh"
    }

    fn wait_for_output_event(events: &SessionEventReceiver) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(!remaining.is_zero(), "timed out waiting for output event");
            match events.recv_timeout(remaining.min(Duration::from_millis(100))) {
                Ok(envelope) if matches!(envelope.event, SessionEvent::Output { .. }) => return,
                Ok(_) => {}
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    panic!("event stream closed while waiting for output event");
                }
            }
        }
    }
}
