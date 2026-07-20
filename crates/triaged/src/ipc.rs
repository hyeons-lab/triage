// Filesystem ops are only used by the Unix socket path and by tests; on Windows
// the named-pipe transport touches no filesystem entries.
#[cfg(any(unix, test))]
use std::fs;
use std::io::{BufRead, BufReader, BufWriter, ErrorKind, Write};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};
#[cfg(unix)]
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
    LeaseChange, ResizeSessionRequest, RestoreSessionRequest, ServerUpdateInfo, SessionApi,
    SessionEventEnvelope, SessionEventReceiver, SessionId, SessionSnapshot, StartSessionRequest,
    StyledRowsRequest, StyledRowsResponse, SubscribeSessionEventsRequest, WriteInputRequest,
};

use crate::session::SessionManager;

const SUBSCRIPTION_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);

/// Local IPC transport seam.
///
/// The daemon's control plane speaks a newline-delimited JSON protocol over a
/// local, single-machine socket. On Unix that socket is a filesystem AF_UNIX
/// socket (hardened to `0o600`); on Windows it is a named pipe
/// (`\\.\pipe\triage-<user>`). Only the connect/listen primitives differ — the
/// wire protocol, request handlers, and client are shared. Handover (FD passing
/// via `SCM_RIGHTS`) is Unix-only and keeps its own `UnixStream` path.
mod transport {
    use super::*;

    /// A server-side accepted local IPC stream (yielded by the listener). On
    /// Unix the accept loop uses `UnixStream` directly; this alias names the
    /// Windows `local_socket::Stream` that `handle_connection` consumes.
    #[cfg(windows)]
    pub type LocalStream = interprocess::local_socket::Stream;

    /// A client-side connected local IPC stream. On Unix this is the same
    /// `UnixStream`; on Windows we use the raw named-pipe stream rather than the
    /// `local_socket::Stream` wrapper so the connect can take a wait timeout
    /// (the cross-platform `local_socket` connect hardcodes an unbounded wait).
    #[cfg(unix)]
    pub type ClientStream = UnixStream;
    #[cfg(windows)]
    pub type ClientStream = interprocess::os::windows::named_pipe::DuplexPipeStream<
        interprocess::os::windows::named_pipe::pipe_mode::Bytes,
    >;

    /// Upper bound on how long a client waits for a daemon instance to become
    /// available. The accept loop re-arms in microseconds, so this only matters
    /// when every pipe instance is momentarily busy; without it a busy pipe
    /// (`ERROR_PIPE_BUSY`) could block the client indefinitely.
    #[cfg(windows)]
    const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

    /// Connect a client to the daemon's local IPC endpoint.
    #[cfg(unix)]
    pub fn connect(path: &Path) -> std::io::Result<ClientStream> {
        UnixStream::connect(path)
    }

    #[cfg(windows)]
    pub fn connect(path: &Path) -> std::io::Result<ClientStream> {
        use interprocess::ConnectWaitMode;
        use interprocess::os::windows::named_pipe::{DuplexPipeStream, pipe_mode::Bytes};
        // `connect_by_path` does not prepend the `\\.\pipe\` prefix, so pass the
        // fully-qualified endpoint. A missing daemon fails fast (the pipe does
        // not exist); only an all-instances-busy pipe consumes the timeout.
        let endpoint = super::display_endpoint(path);
        DuplexPipeStream::<Bytes>::connect_by_path_with_wait_mode(
            endpoint.as_str(),
            ConnectWaitMode::Timeout(CONNECT_TIMEOUT),
        )
    }

    /// Signal end-of-request to the server. On Unix we half-close the write side
    /// as a courtesy; on Windows the newline already frames the request, so this
    /// is a no-op (named pipes have no half-close).
    #[cfg(unix)]
    pub fn finish_write(stream: &ClientStream) -> std::io::Result<()> {
        stream.shutdown(std::net::Shutdown::Write)
    }

    #[cfg(windows)]
    pub fn finish_write(_stream: &ClientStream) -> std::io::Result<()> {
        Ok(())
    }

    /// Build the `interprocess` namespaced name for a Windows named pipe from the
    /// configured socket path (which on Windows carries the bare pipe name).
    /// The single legal named-pipe token for `path`. A pipe lives at
    /// `\\.\pipe\<token>`, where `<token>` must not contain a path separator. The
    /// default socket path is already a clean `triage-<user>`, but a
    /// caller-supplied or test path may be filesystem-like (`…\triage.sock`);
    /// collapse separators into a legal token that is still unique per distinct
    /// path (so parallel tests with different temp dirs don't collide). Shared by
    /// the connect/listen name builder and by user-facing endpoint display.
    #[cfg(windows)]
    pub fn windows_pipe_token(path: &Path) -> std::io::Result<String> {
        let raw = path.to_str().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "named pipe name is not valid UTF-8",
            )
        })?;
        // Accept either a bare token (`triage-<user>`, the default) or a full pipe
        // path (`\\.\pipe\triage-<user>` / `\\?\pipe\...`); strip the well-known
        // prefix so a user-typed full path maps to the same token, then collapse
        // any remaining separators into the single legal token.
        let bare = raw
            .strip_prefix(r"\\.\pipe\")
            .or_else(|| raw.strip_prefix(r"\\?\pipe\"))
            .unwrap_or(raw);
        let collapsed: String = bare
            .chars()
            .map(|c| match c {
                '\\' | '/' | ':' => '_',
                other => other,
            })
            .collect();

        // The full pipe path `\\.\pipe\<token>` is capped by NPFS at 256 UTF-16
        // code units (the Win32 string unit), not chars — a non-BMP char is one
        // `char` but two units. A deep override/test path could exceed that;
        // collapse an over-long token to a readable prefix plus a stable hash so
        // it stays legal and still unique per distinct path.
        if collapsed.encode_utf16().count() <= MAX_PIPE_TOKEN_LEN {
            return Ok(collapsed);
        }
        use sha2::{Digest, Sha256};
        // 16 hex chars (ASCII → 16 units) + one `_` separator = 17 units.
        let hash = hex::encode(&Sha256::digest(collapsed.as_bytes())[..8]);
        let prefix = truncate_utf16_units(&collapsed, MAX_PIPE_TOKEN_LEN - 17);
        Ok(format!("{prefix}_{hash}"))
    }

    /// Maximum length, in UTF-16 code units, for a named-pipe token. NPFS caps
    /// the full `\\.\pipe\<token>` path at 256 units; this leaves margin for the
    /// 9-unit `\\.\pipe\` prefix.
    #[cfg(windows)]
    pub const MAX_PIPE_TOKEN_LEN: usize = 210;

    /// Truncate `s` to at most `max_units` UTF-16 code units, stopping on a
    /// `char` boundary so a surrogate pair is never split.
    #[cfg(windows)]
    fn truncate_utf16_units(s: &str, max_units: usize) -> String {
        let mut out = String::new();
        let mut units = 0usize;
        for c in s.chars() {
            let w = c.len_utf16();
            if units + w > max_units {
                break;
            }
            out.push(c);
            units += w;
        }
        out
    }

    #[cfg(windows)]
    pub fn windows_pipe_name(
        path: &Path,
    ) -> std::io::Result<interprocess::local_socket::Name<'static>> {
        use interprocess::local_socket::{GenericNamespaced, ToNsName};
        windows_pipe_token(path)?.to_ns_name::<GenericNamespaced>()
    }
}

/// Human-facing description of the daemon's control endpoint, for log and error
/// messages. On Unix this is the socket file path; on Windows it is the full
/// named-pipe path (`\\.\pipe\<token>`), since the stored path holds only the
/// bare pipe token (a bare token reads like a typo in an error message).
pub fn display_endpoint(path: &Path) -> String {
    #[cfg(windows)]
    {
        if let Ok(token) = transport::windows_pipe_token(path) {
            return format!(r"\\.\pipe\{token}");
        }
    }
    path.display().to_string()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IpcConfig {
    pub socket_path: PathBuf,
}

impl IpcConfig {
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
        }
    }
}

pub struct IpcServer {
    manager: Arc<SessionManager>,
    web_cache: Arc<crate::http::WebAssetCache>,
    config: IpcConfig,
}

impl IpcServer {
    pub fn new(
        manager: Arc<SessionManager>,
        web_cache: Arc<crate::http::WebAssetCache>,
        config: IpcConfig,
    ) -> Self {
        Self {
            manager,
            web_cache,
            config,
        }
    }

    #[cfg(unix)]
    pub fn serve(self) -> Result<()> {
        let listener = bind_owner_socket(&self.config.socket_path)?;

        loop {
            match listener.accept() {
                Ok((stream, _addr)) => {
                    let manager = Arc::clone(&self.manager);
                    let web_cache = Arc::clone(&self.web_cache);
                    spawn_client_handler(move || handle_connection(manager, web_cache, stream));
                }
                Err(error) => {
                    tracing::warn!(error = ?error, "failed to accept Unix socket connection");
                }
            }
        }
    }

    #[cfg(windows)]
    pub fn serve(self) -> Result<()> {
        use interprocess::local_socket::ListenerOptions;
        use interprocess::local_socket::traits::ListenerExt as _;

        let pipe_name = display_endpoint(&self.config.socket_path);

        // `create_sync` sets FILE_FLAG_FIRST_PIPE_INSTANCE, so a second daemon's
        // create fails atomically — no need for a self-connect preflight (which
        // could itself block and left a phantom connection in the accept loop).
        let listener = ListenerOptions::new()
            .name(transport::windows_pipe_name(&self.config.socket_path)?)
            .create_sync()
            .with_context(|| {
                format!("creating named pipe {pipe_name} (is another triaged already running?)")
            })?;

        for incoming in listener.incoming() {
            match incoming {
                Ok(stream) => {
                    let manager = Arc::clone(&self.manager);
                    let web_cache = Arc::clone(&self.web_cache);
                    spawn_client_handler(move || handle_connection(manager, web_cache, stream));
                }
                Err(error) => {
                    tracing::warn!(error = ?error, "failed to accept named pipe connection");
                }
            }
        }
        Ok(())
    }
}

/// Spawn a detached worker thread to service one accepted IPC connection. Shared
/// by the Unix and Windows accept loops, which differ only in how they obtain
/// the stream. A clean client disconnect (`is_closed_socket_error`) is not worth
/// logging; anything else is surfaced as a warning.
fn spawn_client_handler<F>(handler: F)
where
    F: FnOnce() -> Result<()> + Send + 'static,
{
    if let Err(error) = thread::Builder::new()
        .name("triage-ipc-client".to_string())
        .spawn(move || {
            if let Err(error) = handler()
                && !is_closed_socket_error(&error)
            {
                tracing::warn!(error = ?error, "IPC client handler failed");
            }
        })
    {
        tracing::warn!(error = ?error, "failed to spawn IPC client handler");
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IpcClient {
    socket_path: PathBuf,
}

impl IpcClient {
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
        }
    }

    pub fn reload_client_assets(&self) -> Result<()> {
        match self.round_trip(WireRequest::ReloadClientAssets)? {
            WireSuccess::Unit => Ok(()),
            other => bail!("unexpected reload response: {other:?}"),
        }
    }

    fn round_trip(&self, request: WireRequest) -> Result<WireSuccess> {
        let mut stream = transport::connect(&self.socket_path)
            .with_context(|| format!("connecting to {}", display_endpoint(&self.socket_path)))?;
        write_json_line(&mut stream, &request).context("writing IPC request")?;
        transport::finish_write(&stream).context("finishing IPC request")?;

        let mut reader = BufReader::new(stream);
        let response: WireResponse = read_json_line(&mut reader)?.context("reading response")?;
        response.into_result()
    }
}

#[cfg(unix)]
pub fn default_socket_path() -> PathBuf {
    if let Some(runtime_dir) = std::env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime_dir).join("triage/triage.sock");
    }

    std::env::temp_dir()
        .join(format!("triage-{}", fallback_user_component()))
        .join("triage.sock")
}

/// On Windows the "socket path" is the bare name of a named pipe; the transport
/// layer expands it to `\\.\pipe\triage-<user>`. Per-user in the name keeps
/// concurrent users on a shared machine from colliding.
#[cfg(windows)]
pub fn default_socket_path() -> PathBuf {
    PathBuf::from(format!("triage-{}", fallback_user_component()))
}

impl SessionApi for IpcClient {
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
        let mut stream = transport::connect(&self.socket_path)
            .with_context(|| format!("connecting to {}", display_endpoint(&self.socket_path)))?;
        write_json_line(
            &mut stream,
            &WireRequest::SubscribeSessionEvents {
                session_id: request.session_id,
                after_event_seq: request.after_event_seq,
            },
        )
        .context("writing IPC subscribe request")?;
        transport::finish_write(&stream).context("finishing IPC subscribe request")?;

        // The client only reads from here on, so a single handle suffices.
        let mut reader = BufReader::new(stream);
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

    /// Ask the daemon for its update status (Phase 4, the TUI banner). This is a
    /// best-effort, read-only query: any IPC failure (daemon mid-restart,
    /// unexpected reply) falls back to "this build, nothing newer" so the banner
    /// simply stays hidden rather than surfacing an error.
    fn server_update_info(&self) -> ServerUpdateInfo {
        match self.round_trip(WireRequest::ServerUpdateInfo) {
            Ok(WireSuccess::ServerUpdateInfo(info)) => info,
            _ => ServerUpdateInfo {
                server_version: env!("CARGO_PKG_VERSION").to_string(),
                update_available: false,
                latest_version: None,
            },
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
    Handover,
    ReloadClientAssets,
    ServerUpdateInfo,
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
    HandoverState(crate::handover::HandoverState),
    ServerUpdateInfo(ServerUpdateInfo),
}

fn fallback_user_component() -> String {
    user_identifier()
        .filter(|value| !value.trim().is_empty())
        .map(sanitize_path_component)
        .unwrap_or_else(|| format!("pid-{}", std::process::id()))
}

#[cfg(unix)]
fn user_identifier() -> Option<String> {
    std::env::var("UID")
        .or_else(|_| {
            current_user_uid()
                .map(|uid| uid.to_string())
                .ok_or(std::env::VarError::NotPresent)
        })
        .or_else(|_| std::env::var("USER"))
        .ok()
}

#[cfg(unix)]
fn current_user_uid() -> Option<u32> {
    let home = std::env::var_os("HOME")?;
    fs::metadata(home).map(|metadata| metadata.uid()).ok()
}

#[cfg(windows)]
fn user_identifier() -> Option<String> {
    std::env::var("USERNAME").ok()
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

#[cfg(unix)]
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

#[cfg(unix)]
fn handle_connection(
    manager: Arc<SessionManager>,
    web_cache: Arc<crate::http::WebAssetCache>,
    stream: UnixStream,
) -> Result<()> {
    let mut reader = BufReader::new(stream.try_clone().context("cloning Unix socket stream")?);
    // A client that connects then closes without sending a request line (e.g. a
    // liveness probe, or the Windows "already in use" preflight) yields EOF here;
    // that's a normal disconnect, not an error worth logging.
    let Some(request) = read_json_line::<WireRequest>(&mut reader)? else {
        return Ok(());
    };
    // Handover needs the raw stream for SCM_RIGHTS FD passing, so it branches
    // before the shared dispatch (which only deals with the JSON wire protocol).
    if let WireRequest::Handover = request {
        return handle_handover_server(&manager, reader.into_inner());
    }

    let mut writer = BufWriter::new(stream);
    dispatch_request(&manager, &web_cache, request, &mut writer)
}

// Windows named-pipe connection handler. The wire protocol is identical to Unix;
// the only differences are that there is no FD-passing handover, and the request
// is read then the same stream is reused for writing (the client sends exactly one
// request line before reading, so no second read handle is needed).
#[cfg(windows)]
fn handle_connection(
    manager: Arc<SessionManager>,
    web_cache: Arc<crate::http::WebAssetCache>,
    stream: transport::LocalStream,
) -> Result<()> {
    let mut reader = BufReader::new(stream);
    // A client that connects then closes without sending a request line (e.g. a
    // liveness probe, or the Windows "already in use" preflight) yields EOF here;
    // that's a normal disconnect, not an error worth logging.
    let Some(request) = read_json_line::<WireRequest>(&mut reader)? else {
        return Ok(());
    };
    if let WireRequest::Handover = request {
        bail!("Handover request not supported on Windows");
    }

    let mut writer = BufWriter::new(reader.into_inner());
    dispatch_request(&manager, &web_cache, request, &mut writer)
}

/// Service a single non-handover request: stream a subscription, or run the
/// request and write its one-shot response. Shared by both platform handlers.
fn dispatch_request(
    manager: &SessionManager,
    web_cache: &crate::http::WebAssetCache,
    request: WireRequest,
    writer: &mut impl Write,
) -> Result<()> {
    if let WireRequest::SubscribeSessionEvents {
        session_id,
        after_event_seq,
    } = request
    {
        return handle_subscription(manager, session_id, after_event_seq, writer);
    }

    let response = WireResponse::from_result(handle_request(manager, web_cache, request));
    write_json_line(writer, &response).context("writing response")?;
    writer.flush().context("flushing response")?;
    Ok(())
}

#[cfg(unix)]
fn handle_handover_server(manager: &SessionManager, stream: UnixStream) -> Result<()> {
    use crate::handover::{get_active_tcp_listener_fd, send_fds};
    use std::io::{Read, Write};

    tracing::info!("Received handover request. Beginning process serialization...");

    let (mut state, pty_fds) = manager
        .serialize_active_sessions()
        .context("serializing active sessions for handover")?;

    let mut fds_to_send = Vec::new();

    let tcp_fd = get_active_tcp_listener_fd();
    if tcp_fd >= 0 {
        let dup_tcp = unsafe { libc::dup(tcp_fd) };
        if dup_tcp < 0 {
            bail!(
                "failed to dup TCP listener socket: {}",
                std::io::Error::last_os_error()
            );
        }
        fds_to_send.push(dup_tcp);
        state.has_tcp_listener = true;
    } else {
        state.has_tcp_listener = false;
    }

    fds_to_send.extend(pty_fds);

    let response = WireResponse::Ok(Box::new(WireSuccess::HandoverState(state)));
    let response_bytes =
        serde_json::to_vec(&response).context("serializing handover response JSON")?;

    let send_res = send_fds(&stream, &fds_to_send, &response_bytes);

    // Close duplicated FDs in this process to prevent FD leaks!
    for fd in fds_to_send {
        unsafe {
            libc::close(fd);
        }
    }

    send_res.context("sending handover state and FDs via SCM_RIGHTS")?;

    tracing::info!("Handover transfer completed. Waiting for client adoption sync (Phase 2)...");

    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .context("setting read timeout on handover socket")?;
    let mut sync_byte = [0u8; 1];
    if let Err(err) = stream.try_clone()?.read_exact(&mut sync_byte) {
        bail!("Failed to receive sync byte from client: {err}");
    }
    if sync_byte[0] != 0x01 {
        bail!(
            "Invalid sync byte received from client: {:02x}",
            sync_byte[0]
        );
    }

    tracing::info!("Received adoption sync byte (0x01). Initiating Phase 3 (teardown)...");

    // Detach — do NOT kill. The successor daemon has already adopted these
    // sessions via the transferred master fds; sending each actor a shutdown
    // (which calls child.kill()) is what made handovers tear down every session.
    // We process::exit(0) below, so the OS reaps our threads and fds without
    // touching the children.
    manager.detach_all_live_sessions();

    let mut out_stream = stream;
    out_stream
        .write_all(&[0x02])
        .context("writing teardown sync byte (0x02) to client")?;
    out_stream.flush().context("flushing teardown sync byte")?;

    tracing::info!("Process handover handshake completed successfully. Exiting daemon.");

    let socket_path = default_socket_path();
    if socket_path.exists() {
        let _ = fs::remove_file(&socket_path);
    }

    std::process::exit(0);
}

fn handle_subscription(
    manager: &SessionManager,
    session_id: SessionId,
    after_event_seq: Option<u64>,
    writer: &mut impl Write,
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

fn handle_request(
    manager: &SessionManager,
    web_cache: &crate::http::WebAssetCache,
    request: WireRequest,
) -> Result<WireSuccess> {
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
        WireRequest::Handover => {
            bail!("handover requests require direct socket handler")
        }
        WireRequest::ReloadClientAssets => {
            web_cache.reload();
            Ok(WireSuccess::Unit)
        }
        WireRequest::ServerUpdateInfo => {
            Ok(WireSuccess::ServerUpdateInfo(manager.server_update_info()))
        }
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
    let root_cause = error.root_cause();

    if let Some(io_error) = root_cause.downcast_ref::<std::io::Error>() {
        return is_closed_socket_error_kind(io_error.kind());
    }

    // `write_json_line` writes through `serde_json::to_writer`, which wraps the
    // underlying io error in a `serde_json::Error`. The root cause is then not
    // an `io::Error` at all, so the check above misses a client that hung up
    // mid-write and the disconnect is logged as an unexpected warning.
    root_cause
        .downcast_ref::<serde_json::Error>()
        .and_then(serde_json::Error::io_error_kind)
        .is_some_and(is_closed_socket_error_kind)
}

fn is_closed_socket_error_kind(kind: ErrorKind) -> bool {
    matches!(
        kind,
        ErrorKind::BrokenPipe | ErrorKind::ConnectionReset | ErrorKind::UnexpectedEof
    )
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
        let cache = Arc::new(crate::http::WebAssetCache::new(None));
        let server = IpcServer::new(
            Arc::clone(&manager),
            cache,
            IpcConfig::new(socket_path.clone()),
        );
        spawn_server(server);

        let client = IpcClient::new(socket_path.clone());
        let missing = SessionId::new("missing").expect("session id");
        let error = client
            .snapshot_session(missing)
            .expect_err("missing snapshot should fail");

        assert!(error.to_string().contains("not found"));
        let _ = fs::remove_file(socket_path);
        let _ = fs::remove_dir_all(log_dir);
    }

    #[test]
    fn client_fetches_server_update_info_over_socket() {
        let socket_path = unique_socket_path("upd");
        let log_dir = unique_dir("upd-logs");
        let manager = Arc::new(SessionManager::new(SessionManagerConfig::new(
            log_dir.clone(),
        )));
        // Seed a "newer release available" status so the value we read back
        // proves it crossed the wire (the client's fallback is never-available).
        manager.set_update_status_for_test(crate::update::UpdateStatus {
            current: "0.1.6".to_string(),
            latest: Some("0.1.7".to_string()),
            update_available: true,
        });
        let cache = Arc::new(crate::http::WebAssetCache::new(None));
        let server = IpcServer::new(
            Arc::clone(&manager),
            cache,
            IpcConfig::new(socket_path.clone()),
        );
        spawn_server(server);

        let client = IpcClient::new(socket_path.clone());
        let info = client.server_update_info();

        assert!(info.update_available);
        assert_eq!(info.server_version, "0.1.6");
        assert_eq!(info.latest_version.as_deref(), Some("0.1.7"));
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

    /// Exercises the real write path rather than a hand-built error: a client
    /// that hangs up mid-write fails inside `serde_json::to_writer`, so the
    /// root cause is a `serde_json::Error` and not an `io::Error`.
    #[test]
    fn json_closed_socket_errors_are_expected_client_disconnects() {
        struct BrokenPipeWriter;

        impl Write for BrokenPipeWriter {
            fn write(&mut self, _buffer: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::from(ErrorKind::BrokenPipe))
            }

            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }

        let error = write_json_line(&mut BrokenPipeWriter, &"payload")
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
        let cache = Arc::new(crate::http::WebAssetCache::new(None));
        let server = IpcServer::new(
            Arc::clone(&manager),
            cache,
            IpcConfig::new(socket_path.clone()),
        );
        spawn_server(server);

        let client = IpcClient::new(socket_path.clone());
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
        let cache = Arc::new(crate::http::WebAssetCache::new(None));
        let server = IpcServer::new(
            Arc::clone(&manager),
            cache,
            IpcConfig::new(socket_path.clone()),
        );
        spawn_server(server);
        let client = IpcClient::new(socket_path.clone());

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

    fn spawn_server(server: IpcServer) {
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
        while server_not_ready(&socket_path) {
            if let Ok(result) = rx.try_recv() {
                result.expect("test server failed");
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for test server endpoint"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    // Readiness probe for the test server. On Unix the listener is ready once the
    // socket file appears; on Windows the endpoint is a named pipe (no filesystem
    // entry), so probe by attempting to connect.
    #[cfg(unix)]
    fn server_not_ready(socket_path: &Path) -> bool {
        !socket_path.exists()
    }

    #[cfg(windows)]
    fn server_not_ready(socket_path: &Path) -> bool {
        transport::connect(socket_path).is_err()
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
    #[test]
    fn windows_pipe_token_caps_overlong_names() {
        let long = format!(r"\\.\pipe\{}", "a".repeat(400));
        let token = transport::windows_pipe_token(Path::new(&long)).expect("token");
        assert!(token.encode_utf16().count() <= transport::MAX_PIPE_TOKEN_LEN);
        // Stable across calls...
        let again = transport::windows_pipe_token(Path::new(&long)).expect("token");
        assert_eq!(token, again);
        // ...and distinct inputs yield distinct tokens.
        let other = format!(r"\\.\pipe\{}", "b".repeat(400));
        let other_token = transport::windows_pipe_token(Path::new(&other)).expect("token");
        assert_ne!(token, other_token);

        // Non-BMP chars are one `char` but two UTF-16 units, so a char-based cap
        // would undercount and overflow. The bound must hold in UTF-16 units.
        let astral = format!(r"\\.\pipe\{}", "🦀".repeat(400));
        let astral_token = transport::windows_pipe_token(Path::new(&astral)).expect("token");
        assert!(astral_token.encode_utf16().count() <= transport::MAX_PIPE_TOKEN_LEN);
    }

    // The bounded Windows connect (`ConnectWaitMode::Timeout`) must fail *fast*
    // when no daemon is listening — the pipe doesn't exist, so the connect should
    // error immediately rather than wait out the multi-second busy-pipe timeout.
    #[cfg(windows)]
    #[test]
    fn windows_connect_to_missing_daemon_fails_fast() {
        let missing = unique_socket_path("no-daemon");
        let started = Instant::now();
        let result = transport::connect(&missing);
        let elapsed = started.elapsed();
        assert!(
            result.is_err(),
            "connecting to a nonexistent pipe must error"
        );
        assert!(
            elapsed < Duration::from_secs(2),
            "missing-daemon connect should fail fast, took {elapsed:?}"
        );
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
