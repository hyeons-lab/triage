#![cfg_attr(
    windows,
    allow(dead_code, clippy::needless_return, clippy::large_enum_variant)
)]
use std::collections::{HashMap, VecDeque};
use std::ffi::{OsStr, OsString};
use std::fs;
use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
#[cfg(unix)]
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{
    self, Receiver, RecvTimeoutError, Sender, SyncSender, TryRecvError, TrySendError,
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail, ensure};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use serde::{Deserialize, Serialize};
use triage_core::session::{
    AttachSessionRequest, AttachSessionResponse, ClientId, CompletedSession, InputLeaseRequest,
    InputLeaseState, LeaseChange, ResizeSessionRequest, RestoreSessionRequest, SessionApi,
    SessionContext, SessionEvent, SessionEventEnvelope, SessionEventReceiver, SessionId,
    SessionSize, SessionSnapshot, StartSessionRequest, StyledRow, StyledRowsRequest,
    StyledRowsResponse, StyledSpan, SubscribeSessionEventsRequest, TerminalColor, TerminalCursor,
    TerminalStyle, WriteInputRequest,
};
use unicode_width::UnicodeWidthStr;
use wezterm_term::color::{ColorAttribute, ColorPalette, SrgbaTuple};
use wezterm_term::{Intensity, Terminal, TerminalConfiguration, TerminalSize, Underline};

const EVENT_SUBSCRIBER_BUFFER: usize = 64;
const EVENT_REPLAY_BUFFER: usize = 1024;
const MAX_OSC_BUFFER: usize = 4096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionConfig {
    pub command: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub size: SessionSize,
    pub log_path: PathBuf,
}

impl SessionConfig {
    pub fn new(command: impl Into<String>, log_path: impl Into<PathBuf>) -> Self {
        Self {
            command: command.into(),
            args: Vec::new(),
            cwd: None,
            size: SessionSize::default(),
            log_path: log_path.into(),
        }
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            !self.command.trim().is_empty(),
            "session command must be set"
        );
        self.size.validate()
    }
}

#[derive(Debug)]
struct TriageTerminalConfig;

impl TerminalConfiguration for TriageTerminalConfig {
    fn color_palette(&self) -> ColorPalette {
        ColorPalette::default()
    }
}

pub struct PtySession {
    _master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    reader: Box<dyn Read + Send>,
    _writer: SharedPtyWriter,
    output: OutputState,
}

pub struct SessionActor {
    tx: Sender<ActorCommand>,
    worker: Option<JoinHandle<()>>,
    reader: Option<JoinHandle<()>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionManagerConfig {
    pub log_dir: PathBuf,
}

impl SessionManagerConfig {
    pub fn new(log_dir: impl Into<PathBuf>) -> Self {
        Self {
            log_dir: log_dir.into(),
        }
    }

    fn manifest_path(&self) -> PathBuf {
        self.log_dir.join("sessions.json")
    }
}

/// Crockford Base32 alphabet (RFC 4648 variant): excludes I, L, O, U to reduce typos.
const CROCKFORD_BASE32_ALPHABET: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const PAIRING_CODE_LENGTH: usize = 8;

/// Normalize a user-typed pairing code per Crockford Base32 rules:
/// strip whitespace, uppercase, and map ambiguous characters (I/L → 1, O → 0).
fn normalize_pairing_code(input: &str) -> String {
    input
        .chars()
        .filter(|c| !c.is_whitespace())
        .map(|c| match c.to_ascii_uppercase() {
            'I' | 'L' => '1',
            'O' => '0',
            other => other,
        })
        .collect()
}

pub struct SessionManager {
    config: SessionManagerConfig,
    next_session: AtomicU64,
    sessions: Mutex<HashMap<SessionId, ManagedSession>>,
    pairing_codes: Mutex<HashMap<String, Instant>>,
    paired_devices: Mutex<HashMap<ClientId, String>>,
    require_pairing: bool,
}

enum ManagedSession {
    Live {
        actor: SessionActor,
        lease: InputLeaseState,
        launch: PersistedSessionLaunch,
    },
    Historical {
        session: Box<HistoricalSession>,
        lease: InputLeaseState,
    },
    Restoring {
        session: Box<HistoricalSession>,
        lease: InputLeaseState,
    },
}

struct HistoricalSession {
    persisted: PersistedSession,
    output: OutputState,
    size: SessionSize,
    current_working_directory: Option<PathBuf>,
    context: Option<SessionContext>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct SessionManifest {
    version: u32,
    sessions: Vec<PersistedSession>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedSession {
    id: SessionId,
    command: String,
    args: Vec<String>,
    cwd: Option<PathBuf>,
    size: SessionSize,
    log_path: PathBuf,
    exited: bool,
}

#[derive(Debug, Clone)]
struct PersistedSessionLaunch {
    command: String,
    args: Vec<String>,
    cwd: Option<PathBuf>,
    size: SessionSize,
    log_path: PathBuf,
}

impl From<&SessionConfig> for PersistedSessionLaunch {
    fn from(config: &SessionConfig) -> Self {
        Self {
            command: config.command.clone(),
            args: config.args.clone(),
            cwd: config.cwd.clone(),
            size: config.size.clone(),
            log_path: config.log_path.clone(),
        }
    }
}

impl PersistedSessionLaunch {
    fn into_persisted(self, id: SessionId, exited: bool) -> PersistedSession {
        PersistedSession {
            id,
            command: self.command,
            args: self.args,
            cwd: self.cwd,
            size: self.size,
            log_path: self.log_path,
            exited,
        }
    }
}

impl SessionManager {
    pub fn new(config: SessionManagerConfig) -> Self {
        let sessions = restore_sessions(&config).unwrap_or_else(|error| {
            tracing::warn!(error = ?error, "failed to restore persisted sessions");
            HashMap::new()
        });
        let next_session = next_session_sequence(sessions.keys());
        let paired_devices = load_paired_devices(&config.log_dir);
        let require_pairing = if let Ok(path) = triage_core::config::Config::default_path() {
            if path.exists() {
                triage_core::config::Config::load_from_path(&path)
                    .map(|c| c.remote.require_pairing)
                    .unwrap_or(true)
            } else {
                true
            }
        } else {
            true
        };
        Self {
            config,
            next_session: AtomicU64::new(next_session),
            sessions: Mutex::new(sessions),
            pairing_codes: Mutex::new(HashMap::new()),
            paired_devices: Mutex::new(paired_devices),
            require_pairing,
        }
    }

    fn allocate_session_id(&self) -> Result<SessionId> {
        let sequence = self.next_session.fetch_add(1, Ordering::Relaxed);
        SessionId::new(format!("session-{sequence}"))
    }

    fn log_path(&self, session_id: &SessionId) -> PathBuf {
        self.config.log_dir.join(format!("{session_id}.log"))
    }

    fn sessions(&self) -> Result<std::sync::MutexGuard<'_, HashMap<SessionId, ManagedSession>>> {
        self.sessions
            .lock()
            .map_err(|_| anyhow!("session manager lock poisoned"))
    }

    fn pairing_codes(&self) -> Result<std::sync::MutexGuard<'_, HashMap<String, Instant>>> {
        self.pairing_codes
            .lock()
            .map_err(|_| anyhow!("pairing codes lock poisoned"))
    }

    fn paired_devices(&self) -> Result<std::sync::MutexGuard<'_, HashMap<ClientId, String>>> {
        self.paired_devices
            .lock()
            .map_err(|_| anyhow!("paired devices lock poisoned"))
    }

    fn persist_manifest(&self, sessions: &HashMap<SessionId, ManagedSession>) -> Result<()> {
        fs::create_dir_all(&self.config.log_dir).with_context(|| {
            format!("creating session log dir {}", self.config.log_dir.display())
        })?;
        let mut persisted_sessions = sessions
            .iter()
            .map(|(session_id, session)| session.persisted(session_id.clone()))
            .collect::<Vec<_>>();
        persisted_sessions.sort_by(|left, right| left.id.as_str().cmp(right.id.as_str()));
        let manifest = SessionManifest {
            version: 1,
            sessions: persisted_sessions,
        };
        let manifest_path = self.config.manifest_path();
        let temp_path = manifest_path.with_extension("json.tmp");
        let json = serde_json::to_vec_pretty(&manifest).context("encoding session manifest")?;
        fs::write(&temp_path, json)
            .with_context(|| format!("writing session manifest {}", temp_path.display()))?;
        replace_manifest(&temp_path, &manifest_path)?;
        Ok(())
    }

    fn rollback_restoring_session(&self, session_id: SessionId) -> Result<()> {
        let mut sessions = self.sessions()?;
        let session = sessions
            .remove(&session_id)
            .with_context(|| format!("session {session_id} not found"))?;
        let ManagedSession::Restoring { session, lease } = session else {
            sessions.insert(session_id.clone(), session);
            bail!("session {session_id} is not being restored");
        };
        sessions.insert(session_id, ManagedSession::Historical { session, lease });
        Ok(())
    }

    pub fn generate_pairing_code(&self) -> Result<String> {
        use rand::Rng;

        let mut rng = rand::thread_rng();
        let code: String = (0..PAIRING_CODE_LENGTH)
            .map(|_| {
                let idx = rng.gen_range(0..CROCKFORD_BASE32_ALPHABET.len());
                CROCKFORD_BASE32_ALPHABET[idx] as char
            })
            .collect();

        let expires_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs()
            + 300; // 5 minutes expiry

        let mut codes = self.pairing_codes()?;
        codes.insert(code.clone(), Instant::now() + Duration::from_secs(300));

        let pairing_code_path = self.config.log_dir.join("pairing_code.json");
        let info = serde_json::json!({
            "code": code,
            "expires_at": expires_at,
        });
        let json = serde_json::to_vec_pretty(&info)?;
        if let Some(parent) = pairing_code_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&pairing_code_path, json)?;

        tracing::info!("generated new device pairing PIN");

        Ok(code)
    }

    #[cfg(unix)]
    pub fn serialize_active_sessions(
        &self,
    ) -> Result<(
        crate::handover::HandoverState,
        Vec<std::os::unix::io::RawFd>,
    )> {
        let sessions = self.sessions()?;
        let mut handover_sessions = Vec::new();
        let mut fds = Vec::new();

        for (id, managed) in sessions.iter() {
            if let ManagedSession::Live {
                actor,
                lease: _,
                launch,
            } = managed
            {
                let (tx, rx) = mpsc::channel();
                if let Err(err) = actor
                    .tx
                    .send(ActorCommand::ExtractHandoverState { response: tx })
                {
                    tracing::warn!(session_id = %id, ?err, "Failed to send extract command to actor");
                    continue;
                }

                let ext = match rx.recv().context("waiting for extract response")? {
                    Ok(ext) => ext,
                    Err(err) => {
                        tracing::warn!(session_id = %id, ?err, "Actor failed to extract handover state");
                        continue;
                    }
                };

                fds.push(ext.fd);

                handover_sessions.push(crate::handover::HandoverSession {
                    id: id.clone(),
                    command: launch.command.clone(),
                    args: launch.args.clone(),
                    cwd: launch.cwd.clone(),
                    size: launch.size.clone(),
                    log_path: launch.log_path.clone(),
                    output_seq: ext.output_seq,
                    bytes_logged: ext.bytes_logged,
                    pid: ext.pid,
                });
            }
        }

        let state = crate::handover::HandoverState {
            sessions: handover_sessions,
            has_tcp_listener: false,
        };

        Ok((state, fds))
    }

    #[cfg(unix)]
    pub fn clear_all_live_sessions(&self) {
        if let Ok(mut sessions) = self.sessions() {
            let keys: Vec<_> = sessions.keys().cloned().collect();
            for id in keys {
                if let Some(ManagedSession::Live {
                    mut actor,
                    lease: _,
                    launch: _,
                }) = sessions.remove(&id)
                {
                    let (tx, rx) = mpsc::channel();
                    if let Err(err) = actor.tx.send(ActorCommand::Shutdown { response: tx }) {
                        tracing::warn!(session_id = %id, ?err, "Failed to send shutdown command to actor");
                    } else {
                        let _ = rx.recv();
                    }
                    actor.join_threads();
                }
            }
            sessions.clear();
        }
    }

    #[cfg(unix)]
    pub fn adopt_sessions(
        &self,
        state: crate::handover::HandoverState,
        mut fds: Vec<std::os::unix::io::RawFd>,
    ) -> Result<()> {
        let mut sessions = self.sessions()?;

        for h_sess in state.sessions {
            if fds.is_empty() {
                bail!("No inherited FDs left for session {}", h_sess.id);
            }
            let fd = fds.remove(0);

            let runtime = spawn_adopted_pty_runtime(&h_sess, fd)?;

            let launch = PersistedSessionLaunch {
                command: h_sess.command.clone(),
                args: h_sess.args.clone(),
                cwd: h_sess.cwd.clone(),
                size: h_sess.size.clone(),
                log_path: h_sess.log_path.clone(),
            };

            let event_session_id = Some(h_sess.id.clone());

            let PtyRuntime {
                master,
                child,
                reader,
                writer,
                output,
                size,
                log_path,
                current_working_directory,
            } = runtime;

            let initial_working_directory = current_working_directory
                .or_else(|| h_sess.cwd.clone())
                .or_else(|| std::env::current_dir().ok());
            let initial_context = resolve_session_context(initial_working_directory.as_ref());

            let (command_tx, command_rx) = mpsc::channel();
            let (output_tx, output_rx) = mpsc::sync_channel(64);

            let reader = thread::Builder::new()
                .name("session-actor-reader".into())
                .spawn(move || read_pty_output(reader, output_tx))
                .context("spawning session actor reader thread")?;

            let worker = thread::Builder::new()
                .name("session-actor-worker".into())
                .spawn(move || {
                    let state = ActorState {
                        master,
                        child,
                        writer,
                        output,
                        size,
                        log_path,
                        exited: false,
                        output_closed: false,
                        exit_broadcasted: false,
                        current_working_directory: initial_working_directory,
                        context: initial_context,
                        event_session_id,
                        subscribers: Vec::new(),
                        event_log: VecDeque::new(),
                        next_event_seq: 1,
                    };
                    run_actor(state, command_rx, output_rx);
                })
                .context("spawning session actor worker thread")?;

            let actor = SessionActor {
                tx: command_tx,
                worker: Some(worker),
                reader: Some(reader),
            };

            sessions.insert(
                h_sess.id.clone(),
                ManagedSession::Live {
                    actor,
                    lease: InputLeaseState::default(),
                    launch,
                },
            );
        }

        self.persist_manifest(&sessions)?;
        Ok(())
    }
}

#[cfg(unix)]
fn spawn_adopted_pty_runtime(
    h_sess: &crate::handover::HandoverSession,
    fd: std::os::unix::io::RawFd,
) -> Result<PtyRuntime> {
    use crate::handover::{AdoptedChild, AdoptedMasterPty};

    let master = Box::new(AdoptedMasterPty { fd });
    let child = Box::new(AdoptedChild { pid: h_sess.pid });

    let reader = master.try_clone_reader().context("cloning PTY reader")?;
    let writer = shared_pty_writer(master.take_writer().context("taking PTY writer")?);

    let terminal = terminal_with_writer(&h_sess.size, writer.clone());
    let log = OpenOptions::new()
        .create(true)
        .read(true)
        .append(true)
        .open(&h_sess.log_path)
        .with_context(|| format!("opening session log {}", h_sess.log_path.display()))?;

    let mut output = OutputState {
        log: log.try_clone().context("cloning restored session log")?,
        terminal,
        cwd_sequence_buffer: Vec::new(),
        bytes_logged: 0,
        output_seq: 0,
        log_cache: None,
    };

    let replay = fs::read(&h_sess.log_path)
        .with_context(|| format!("reading session log {}", h_sess.log_path.display()))?;
    let replayed_working_directory = if replay.is_empty() {
        None
    } else {
        output.replay(&replay)?
    };
    let current_working_directory = restorable_cwd(replayed_working_directory, h_sess.cwd.clone());

    Ok(PtyRuntime {
        master,
        child,
        reader,
        writer,
        output,
        size: h_sess.size.clone(),
        log_path: h_sess.log_path.clone(),
        current_working_directory,
    })
}

impl ManagedSession {
    fn persisted(&self, session_id: SessionId) -> PersistedSession {
        match self {
            Self::Live { launch, .. } => launch.clone().into_persisted(session_id, false),
            Self::Historical { session, .. } => session.persisted.clone(),
            Self::Restoring { session, .. } => session.persisted.clone(),
        }
    }
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new(SessionManagerConfig::new(default_log_dir()))
    }
}

impl SessionApi for SessionManager {
    fn list_sessions(&self) -> Result<Vec<SessionId>> {
        let sessions = self.sessions()?;
        Ok(sessions.keys().cloned().collect())
    }

    fn start_session(&self, request: StartSessionRequest) -> Result<SessionId> {
        request.validate()?;
        fs::create_dir_all(&self.config.log_dir).with_context(|| {
            format!("creating session log dir {}", self.config.log_dir.display())
        })?;

        let session_id = self.allocate_session_id()?;
        let log_path = self.log_path(&session_id);
        let config = SessionConfig {
            command: request.command,
            args: request.args,
            cwd: request.cwd,
            size: request.size,
            log_path,
        };
        let launch = PersistedSessionLaunch::from(&config);
        let actor = SessionActor::spawn_managed(config, session_id.clone())?;

        let mut sessions = self.sessions()?;
        sessions.insert(
            session_id.clone(),
            ManagedSession::Live {
                actor,
                lease: InputLeaseState::default(),
                launch,
            },
        );
        if let Err(error) = self.persist_manifest(&sessions) {
            let inserted = sessions.remove(&session_id);
            drop(sessions);
            if let Some(ManagedSession::Live { actor, .. }) = inserted
                && let Err(shutdown_error) = actor.shutdown()
            {
                tracing::warn!(
                    error = ?shutdown_error,
                    "failed to shut down session after manifest persistence failure"
                );
            }
            return Err(error);
        }
        Ok(session_id)
    }

    fn attach_session(&self, request: AttachSessionRequest) -> Result<AttachSessionResponse> {
        let mut sessions = self.sessions()?;
        let session = sessions
            .get_mut(&request.session_id)
            .with_context(|| format!("session {} not found", request.session_id))?;

        match session {
            ManagedSession::Live { actor, lease, .. } => {
                if let Some(kind) = request.mode.controller_kind() {
                    let change = lease.acquire(request.client_id, kind);
                    actor.broadcast_event(SessionEvent::LeaseChanged {
                        session_id: request.session_id.clone(),
                        change,
                    })?;
                }

                Ok(AttachSessionResponse {
                    snapshot: actor.snapshot()?,
                    lease: lease.clone(),
                })
            }
            ManagedSession::Historical { session, lease } => Ok(AttachSessionResponse {
                snapshot: session.snapshot(),
                lease: lease.clone(),
            }),
            ManagedSession::Restoring { .. } => {
                bail!("session {} is being restored", request.session_id)
            }
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
        let sessions = self.sessions()?;
        let session = sessions
            .get(&request.session_id)
            .with_context(|| format!("session {} not found", request.session_id))?;
        match session {
            ManagedSession::Live { actor, .. } => actor.subscribe_events(request.after_event_seq),
            ManagedSession::Historical { .. } => Ok(closed_session_event_receiver()),
            ManagedSession::Restoring { .. } => {
                bail!("session {} is being restored", request.session_id)
            }
        }
    }

    fn acquire_input_lease(&self, request: InputLeaseRequest) -> Result<LeaseChange> {
        let mut sessions = self.sessions()?;
        let session = sessions
            .get_mut(&request.session_id)
            .with_context(|| format!("session {} not found", request.session_id))?;
        match session {
            ManagedSession::Live { actor, lease, .. } => {
                let change = lease.acquire(request.client_id, request.kind);
                actor.broadcast_event(SessionEvent::LeaseChanged {
                    session_id: request.session_id,
                    change: change.clone(),
                })?;
                Ok(change)
            }
            ManagedSession::Historical { .. } => {
                bail!("restored historical sessions cannot acquire input leases")
            }
            ManagedSession::Restoring { .. } => {
                bail!("session {} is being restored", request.session_id)
            }
        }
    }

    fn release_input_lease(
        &self,
        session_id: SessionId,
        client_id: ClientId,
    ) -> Result<LeaseChange> {
        let mut sessions = self.sessions()?;
        let session = sessions
            .get_mut(&session_id)
            .with_context(|| format!("session {session_id} not found"))?;
        match session {
            ManagedSession::Live { actor, lease, .. } => {
                let change = lease
                    .release(&client_id)
                    .with_context(|| format!("client {client_id} does not hold input lease"))?;
                actor.broadcast_event(SessionEvent::LeaseChanged {
                    session_id,
                    change: change.clone(),
                })?;
                Ok(change)
            }
            ManagedSession::Historical { .. } => {
                bail!("restored historical sessions cannot hold input leases")
            }
            ManagedSession::Restoring { .. } => {
                bail!("session {session_id} is being restored")
            }
        }
    }

    fn write_input(&self, request: WriteInputRequest) -> Result<()> {
        let sessions = self.sessions()?;
        let session = sessions
            .get(&request.session_id)
            .with_context(|| format!("session {} not found", request.session_id))?;
        let ManagedSession::Live { actor, lease, .. } = session else {
            match session {
                ManagedSession::Historical { .. } => {
                    bail!("restored historical sessions cannot accept input")
                }
                ManagedSession::Restoring { .. } => {
                    bail!("session {} is being restored", request.session_id)
                }
                ManagedSession::Live { .. } => unreachable!(),
            }
        };
        let holder = lease
            .holder
            .as_ref()
            .with_context(|| format!("session {} has no input lease holder", request.session_id))?;
        ensure!(
            holder.client_id == request.client_id,
            "client {} does not hold input lease for session {}",
            request.client_id,
            request.session_id
        );
        actor.write_input(request.bytes)
    }

    fn resize_session(&self, request: ResizeSessionRequest) -> Result<SessionSnapshot> {
        let sessions = self.sessions()?;
        let session = sessions
            .get(&request.session_id)
            .with_context(|| format!("session {} not found", request.session_id))?;
        match session {
            ManagedSession::Live { actor, .. } => actor.resize(request.size),
            ManagedSession::Historical { .. } => {
                bail!("restored historical sessions cannot be resized")
            }
            ManagedSession::Restoring { .. } => {
                bail!("session {} is being restored", request.session_id)
            }
        }
    }

    fn restore_session(&self, request: RestoreSessionRequest) -> Result<SessionSnapshot> {
        request.size.validate()?;
        let (persisted, current_working_directory) = {
            let mut sessions = self.sessions()?;
            let existing = sessions
                .remove(&request.session_id)
                .with_context(|| format!("session {} not found", request.session_id))?;
            let ManagedSession::Historical { session, lease } = existing else {
                sessions.insert(request.session_id.clone(), existing);
                bail!(
                    "session {} is already live or restoring",
                    request.session_id
                );
            };
            if !is_restorable_shell_launch(&session.persisted) {
                sessions.insert(
                    request.session_id.clone(),
                    ManagedSession::Historical { session, lease },
                );
                bail!(
                    "session {} was not launched as a restorable shell",
                    request.session_id
                );
            }
            let persisted = session.persisted.clone();
            let current_working_directory = session.current_working_directory.clone();
            sessions.insert(
                request.session_id.clone(),
                ManagedSession::Restoring { session, lease },
            );
            (persisted, current_working_directory)
        };

        let cwd = restorable_cwd(current_working_directory, persisted.cwd.clone());
        let config = SessionConfig {
            command: persisted.command.clone(),
            args: persisted.args.clone(),
            cwd,
            size: request.size,
            log_path: persisted.log_path.clone(),
        };
        let launch = PersistedSessionLaunch::from(&config);
        let actor = match SessionActor::spawn_restored(config, request.session_id.clone()) {
            Ok(actor) => actor,
            Err(error) => {
                self.rollback_restoring_session(request.session_id)?;
                return Err(error);
            }
        };
        let snapshot = match actor.snapshot() {
            Ok(snapshot) => snapshot,
            Err(error) => {
                self.rollback_restoring_session(request.session_id.clone())?;
                actor.shutdown()?;
                return Err(error);
            }
        };

        let mut sessions = self.sessions()?;
        let existing = sessions
            .remove(&request.session_id)
            .with_context(|| format!("session {} not found", request.session_id))?;
        let ManagedSession::Restoring { session, lease } = existing else {
            sessions.insert(request.session_id.clone(), existing);
            drop(sessions);
            actor.shutdown()?;
            bail!("session {} is no longer being restored", request.session_id);
        };
        sessions.insert(
            request.session_id.clone(),
            ManagedSession::Live {
                actor,
                lease: InputLeaseState::default(),
                launch,
            },
        );
        if let Err(error) = self.persist_manifest(&sessions) {
            let inserted = sessions.remove(&request.session_id);
            sessions.insert(
                request.session_id,
                ManagedSession::Historical { session, lease },
            );
            drop(sessions);
            if let Some(ManagedSession::Live { actor, .. }) = inserted
                && let Err(shutdown_error) = actor.shutdown()
            {
                tracing::warn!(
                    error = ?shutdown_error,
                    "failed to shut down restored session after manifest persistence failure"
                );
            }
            return Err(error);
        }

        Ok(snapshot)
    }

    fn snapshot_session(&self, session_id: SessionId) -> Result<SessionSnapshot> {
        let sessions = self.sessions()?;
        let session = sessions
            .get(&session_id)
            .with_context(|| format!("session {session_id} not found"))?;
        match session {
            ManagedSession::Live { actor, .. } => actor.snapshot(),
            ManagedSession::Historical { session, .. } => Ok(session.snapshot()),
            ManagedSession::Restoring { .. } => bail!("session {session_id} is being restored"),
        }
    }

    fn styled_rows(&self, request: StyledRowsRequest) -> Result<StyledRowsResponse> {
        let sessions = self.sessions()?;
        let session = sessions
            .get(&request.session_id)
            .with_context(|| format!("session {} not found", request.session_id))?;
        match session {
            ManagedSession::Live { actor, .. } => actor.styled_rows(request.start, request.end),
            ManagedSession::Historical { session, .. } => {
                session.styled_rows(request.start, request.end)
            }
            ManagedSession::Restoring { .. } => {
                bail!("session {} is being restored", request.session_id)
            }
        }
    }

    fn shutdown_session(&self, session_id: SessionId) -> Result<CompletedSession> {
        let session = {
            let mut sessions = self.sessions()?;
            let session = sessions
                .remove(&session_id)
                .with_context(|| format!("session {session_id} not found"))?;
            if let Err(error) = self.persist_manifest(&sessions) {
                sessions.insert(session_id, session);
                return Err(error);
            }
            session
        };
        match session {
            ManagedSession::Live { actor, .. } => actor.shutdown(),
            ManagedSession::Historical { session, .. } => Ok(session.completed_session()),
            ManagedSession::Restoring { session, .. } => Ok(session.completed_session()),
        }
    }
}

impl PtySession {
    pub fn spawn(config: SessionConfig) -> Result<Self> {
        let runtime = spawn_pty_runtime(config, LogInitialization::Truncate)?;

        Ok(Self {
            _master: runtime.master,
            child: runtime.child,
            reader: runtime.reader,
            _writer: runtime.writer,
            output: runtime.output,
        })
    }

    pub fn drain_until_exit(mut self) -> Result<CompletedSession> {
        let mut chunk = [0; 8192];

        loop {
            match self.reader.read(&mut chunk) {
                Ok(0) => break,
                Ok(read_len) => {
                    self.output.ingest(&chunk[..read_len])?;
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        ErrorKind::BrokenPipe
                            | ErrorKind::ConnectionReset
                            | ErrorKind::UnexpectedEof
                    ) =>
                {
                    break;
                }
                Err(error) if is_closed_pty_error(&error) => break,
                Err(error) => return Err(error).context("reading PTY output"),
            }
        }

        self.child.wait().context("waiting for PTY child")?;
        self.output.log.flush().context("flushing session log")?;

        Ok(CompletedSession {
            output_seq: self.output.output_seq,
            bytes_logged: self.output.bytes_logged,
            visible_rows: visible_rows(&self.output.terminal),
        })
    }
}

pub fn default_log_dir() -> PathBuf {
    default_log_dir_from_env(
        std::env::var_os("XDG_STATE_HOME"),
        std::env::var_os("HOME"),
        std::env::var_os("USERPROFILE"),
    )
}

fn default_log_dir_from_env(
    xdg_state_home: Option<OsString>,
    home: Option<OsString>,
    userprofile: Option<OsString>,
) -> PathBuf {
    xdg_state_home
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = home
                .or(userprofile)
                .map(PathBuf::from)
                .unwrap_or_else(std::env::temp_dir);
            home.join(".local/state")
        })
        .join("triage/sessions")
}

fn load_paired_devices(log_dir: &Path) -> HashMap<ClientId, String> {
    let path = log_dir.join("paired_devices.json");
    if !path.exists() {
        return HashMap::new();
    }

    let content = match fs::read_to_string(&path) {
        Ok(content) => content,
        Err(error) => {
            tracing::warn!(error = ?error, "failed to read paired_devices.json");
            return HashMap::new();
        }
    };

    match serde_json::from_str::<HashMap<String, String>>(&content) {
        Ok(raw_map) => {
            let mut map = HashMap::new();
            for (k, v) in raw_map {
                if let Ok(client_id) = ClientId::new(k) {
                    map.insert(client_id, v);
                }
            }
            map
        }
        Err(error) => {
            tracing::warn!(error = ?error, "failed to parse paired_devices.json");
            HashMap::new()
        }
    }
}

fn save_paired_devices(log_dir: &Path, devices: &HashMap<ClientId, String>) -> Result<()> {
    let path = log_dir.join("paired_devices.json");
    let mut raw_map = HashMap::new();
    for (k, v) in devices {
        raw_map.insert(k.to_string(), v.clone());
    }
    let json = serde_json::to_vec_pretty(&raw_map)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&path, json)?;
    Ok(())
}

fn restore_sessions(config: &SessionManagerConfig) -> Result<HashMap<SessionId, ManagedSession>> {
    let manifest_path = config.manifest_path();
    if !manifest_path.exists() {
        return Ok(HashMap::new());
    }

    let manifest: SessionManifest = serde_json::from_slice(
        &fs::read(&manifest_path)
            .with_context(|| format!("reading session manifest {}", manifest_path.display()))?,
    )
    .with_context(|| format!("decoding session manifest {}", manifest_path.display()))?;
    ensure!(
        manifest.version == 1,
        "unsupported session manifest version {}",
        manifest.version
    );

    let mut sessions = HashMap::new();
    for persisted in manifest.sessions {
        match HistoricalSession::restore(persisted) {
            Ok(session) => {
                sessions.insert(
                    session.persisted.id.clone(),
                    ManagedSession::Historical {
                        session: Box::new(session),
                        lease: InputLeaseState::default(),
                    },
                );
            }
            Err(error) => {
                tracing::warn!(error = ?error, "skipping persisted session");
            }
        }
    }
    Ok(sessions)
}

fn next_session_sequence<'a>(sessions: impl Iterator<Item = &'a SessionId>) -> u64 {
    sessions
        .filter_map(|session_id| {
            session_id
                .as_str()
                .strip_prefix("session-")?
                .parse::<u64>()
                .ok()
        })
        .max()
        .map_or(1, |sequence| sequence.saturating_add(1))
}

fn is_restorable_shell_launch(persisted: &PersistedSession) -> bool {
    let Some(command_name) = Path::new(&persisted.command)
        .file_name()
        .and_then(|name| name.to_str())
    else {
        return false;
    };
    let command_name = command_name.to_ascii_lowercase();
    if !matches!(
        command_name.as_str(),
        "sh" | "bash" | "zsh" | "fish" | "cmd.exe" | "powershell.exe" | "pwsh"
    ) {
        return false;
    }

    persisted.args.is_empty()
        || matches!(persisted.args.as_slice(), [flag] if flag == "-l")
        || is_triage_default_shell_wrapper(&persisted.args)
}

fn is_triage_default_shell_wrapper(args: &[String]) -> bool {
    matches!(args, [flag, script]
        if matches!(flag.as_str(), "-lc" | "-c")
            && script.contains("PROMPT_COMMAND")
            && script.contains("exec \"${SHELL:-/bin/sh}\""))
}

fn restorable_cwd(
    current_working_directory: Option<PathBuf>,
    launch_cwd: Option<PathBuf>,
) -> Option<PathBuf> {
    [current_working_directory, launch_cwd]
        .into_iter()
        .flatten()
        .find(|path| path.is_dir())
}

fn replace_manifest(temp_path: &Path, manifest_path: &Path) -> Result<()> {
    #[cfg(windows)]
    {
        return replace_manifest_with_backup(temp_path, manifest_path);
    }

    #[cfg(not(windows))]
    fs::rename(temp_path, manifest_path).with_context(|| {
        format!(
            "moving session manifest {} to {}",
            temp_path.display(),
            manifest_path.display()
        )
    })
}

#[cfg(any(windows, test))]
fn replace_manifest_with_backup(temp_path: &Path, manifest_path: &Path) -> Result<()> {
    if !manifest_path.exists() {
        return fs::rename(temp_path, manifest_path).with_context(|| {
            format!(
                "moving session manifest {} to {}",
                temp_path.display(),
                manifest_path.display()
            )
        });
    }

    let backup_path = manifest_path.with_extension("json.bak");
    remove_path_if_exists(&backup_path).with_context(|| {
        format!(
            "removing stale session manifest backup {}",
            backup_path.display()
        )
    })?;
    fs::rename(manifest_path, &backup_path).with_context(|| {
        format!(
            "backing up session manifest {} to {}",
            manifest_path.display(),
            backup_path.display()
        )
    })?;

    match fs::rename(temp_path, manifest_path) {
        Ok(()) => {
            remove_path_if_exists(&backup_path).with_context(|| {
                format!("removing session manifest backup {}", backup_path.display())
            })?;
            Ok(())
        }
        Err(error) => {
            if let Err(restore_error) = fs::rename(&backup_path, manifest_path) {
                tracing::error!(
                    error = ?restore_error,
                    "failed to restore previous session manifest after replacement failure"
                );
            }
            Err(error).with_context(|| {
                format!(
                    "moving session manifest {} to {}",
                    temp_path.display(),
                    manifest_path.display()
                )
            })
        }
    }
}

#[cfg(any(windows, test))]
fn remove_path_if_exists(path: &Path) -> Result<()> {
    match fs::metadata(path) {
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path)
            .with_context(|| format!("removing directory {}", path.display())),
        Ok(_) => fs::remove_file(path).with_context(|| format!("removing file {}", path.display())),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("reading metadata {}", path.display())),
    }
}

fn closed_session_event_receiver() -> SessionEventReceiver {
    let (_tx, rx) = mpsc::channel();
    rx
}

impl HistoricalSession {
    fn restore(persisted: PersistedSession) -> Result<Self> {
        let size = persisted.size.clone();
        let mut output = output_state_for_log(&persisted.log_path, persisted.size.clone())?;
        let mut current_working_directory = persisted.cwd.clone();
        let log = fs::read(&persisted.log_path)
            .with_context(|| format!("reading session log {}", persisted.log_path.display()))?;
        if !log.is_empty()
            && let Some(cwd) = output.replay(&log)?
        {
            current_working_directory = Some(cwd);
        }
        let context = resolve_session_context(current_working_directory.as_ref());
        Ok(Self {
            persisted,
            output,
            size,
            current_working_directory,
            context,
        })
    }

    fn snapshot(&self) -> SessionSnapshot {
        snapshot_from_output(
            &self.output,
            &self.size,
            self.current_working_directory.clone(),
            self.context.clone(),
            true,
        )
    }

    fn styled_rows(&self, start: usize, end: usize) -> Result<StyledRowsResponse> {
        ensure!(start <= end, "styled row start must be before end");
        let row_count = self.output.terminal.screen().scrollback_rows();
        ensure!(
            end <= row_count,
            "styled row range {start}..{end} exceeds retained row count {row_count}"
        );
        Ok(StyledRowsResponse {
            output_seq: self.output.output_seq,
            start,
            rows: styled_visible_rows_for_range(&self.output.terminal, start, end),
        })
    }

    fn completed_session(&self) -> CompletedSession {
        CompletedSession {
            output_seq: self.output.output_seq,
            bytes_logged: self.output.bytes_logged,
            visible_rows: visible_rows(&self.output.terminal),
        }
    }
}

impl SessionActor {
    pub fn spawn(config: SessionConfig) -> Result<Self> {
        Self::spawn_with_events(config, None, LogInitialization::Truncate)
    }

    fn spawn_managed(config: SessionConfig, session_id: SessionId) -> Result<Self> {
        Self::spawn_with_events(config, Some(session_id), LogInitialization::Truncate)
    }

    fn spawn_restored(config: SessionConfig, session_id: SessionId) -> Result<Self> {
        Self::spawn_with_events(config, Some(session_id), LogInitialization::ReplayExisting)
    }

    fn spawn_with_events(
        config: SessionConfig,
        event_session_id: Option<SessionId>,
        log_initialization: LogInitialization,
    ) -> Result<Self> {
        let initial_working_directory = config.cwd.clone().or_else(|| std::env::current_dir().ok());
        let runtime = spawn_pty_runtime(config, log_initialization)?;
        let PtyRuntime {
            master,
            child,
            reader,
            writer,
            output,
            size,
            log_path,
            current_working_directory,
        } = runtime;
        let initial_working_directory = current_working_directory.or(initial_working_directory);
        let initial_context = resolve_session_context(initial_working_directory.as_ref());

        let (command_tx, command_rx) = mpsc::channel();
        let (output_tx, output_rx) = mpsc::sync_channel(64);
        let reader = thread::Builder::new()
            .name("session-actor-reader".into())
            .spawn(move || read_pty_output(reader, output_tx))
            .context("spawning session actor reader thread")?;
        let worker = thread::Builder::new()
            .name("session-actor-worker".into())
            .spawn(move || {
                let state = ActorState {
                    master,
                    child,
                    writer,
                    output,
                    size,
                    log_path,
                    exited: false,
                    output_closed: false,
                    exit_broadcasted: false,
                    current_working_directory: initial_working_directory,
                    context: initial_context,
                    event_session_id,
                    subscribers: Vec::new(),
                    event_log: VecDeque::new(),
                    next_event_seq: 1,
                };
                run_actor(state, command_rx, output_rx);
            })
            .context("spawning session actor worker thread")?;

        Ok(Self {
            tx: command_tx,
            worker: Some(worker),
            reader: Some(reader),
        })
    }

    pub fn subscribe_events(&self, after_event_seq: Option<u64>) -> Result<SessionEventReceiver> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(ActorCommand::SubscribeEvents {
                after_event_seq,
                response: tx,
            })
            .context("sending session event subscription command")?;
        recv_actor_result(rx, "subscribing to session events")
    }

    #[cfg(test)]
    fn subscriber_count(&self) -> Result<usize> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(ActorCommand::SubscriberCount { response: tx })
            .context("sending session subscriber count command")?;
        recv_actor_result(rx, "counting session event subscribers")
    }

    pub fn broadcast_event(&self, event: SessionEvent) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(ActorCommand::BroadcastEvent {
                event: Box::new(event),
                response: tx,
            })
            .context("sending session event broadcast command")?;
        recv_actor_result(rx, "broadcasting session event")
    }

    pub fn write_input(&self, bytes: impl Into<Vec<u8>>) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(ActorCommand::WriteInput {
                bytes: bytes.into(),
                response: tx,
            })
            .context("sending session input command")?;
        recv_actor_result(rx, "writing session input")
    }

    pub fn resize(&self, size: SessionSize) -> Result<SessionSnapshot> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(ActorCommand::Resize { size, response: tx })
            .context("sending session resize command")?;
        recv_actor_result(rx, "resizing session")
    }

    pub fn snapshot(&self) -> Result<SessionSnapshot> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(ActorCommand::Snapshot { response: tx })
            .context("sending session snapshot command")?;
        recv_actor_result(rx, "reading session snapshot")
    }

    pub fn styled_rows(&self, start: usize, end: usize) -> Result<StyledRowsResponse> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(ActorCommand::StyledRows {
                start,
                end,
                response: tx,
            })
            .context("sending session styled row command")?;
        recv_actor_result(rx, "reading session styled rows")
    }

    pub fn shutdown(mut self) -> Result<CompletedSession> {
        let (tx, rx) = mpsc::channel();
        let result = self
            .tx
            .send(ActorCommand::Shutdown { response: tx })
            .context("sending session shutdown command")
            .and_then(|_| recv_actor_result(rx, "shutting down session"));
        self.join_threads();
        result
    }

    fn join_threads(&mut self) {
        if let Some(worker) = self.worker.take() {
            join_thread_with_timeout(worker, "session actor worker");
        }
        if let Some(reader) = self.reader.take() {
            join_thread_with_timeout(reader, "session actor reader");
        }
    }
}

impl Drop for SessionActor {
    fn drop(&mut self) {
        if self.worker.is_none() {
            return;
        }

        let (tx, rx) = mpsc::channel();
        if self
            .tx
            .send(ActorCommand::Shutdown { response: tx })
            .is_err()
        {
            tracing::warn!("session actor stopped before drop shutdown signal");
        }
        drop(rx);
    }
}

struct ActorState {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    writer: SharedPtyWriter,
    output: OutputState,
    size: SessionSize,
    log_path: PathBuf,
    exited: bool,
    output_closed: bool,
    exit_broadcasted: bool,
    current_working_directory: Option<PathBuf>,
    context: Option<SessionContext>,
    event_session_id: Option<SessionId>,
    subscribers: Vec<EventSubscriber>,
    event_log: VecDeque<SessionEventEnvelope>,
    next_event_seq: u64,
}

struct EventSubscriber {
    tx: SyncSender<SessionEventEnvelope>,
    next_event_seq: u64,
}

struct PtyRuntime {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    reader: Box<dyn Read + Send>,
    writer: SharedPtyWriter,
    output: OutputState,
    size: SessionSize,
    log_path: PathBuf,
    current_working_directory: Option<PathBuf>,
}

struct OutputState {
    log: File,
    terminal: Terminal,
    cwd_sequence_buffer: Vec<u8>,
    bytes_logged: u64,
    output_seq: u64,
    log_cache: Option<Vec<u8>>,
}

enum ActorMessage {
    Output(Vec<u8>),
    OutputClosed(Result<()>),
}

enum ActorCommand {
    WriteInput {
        bytes: Vec<u8>,
        response: Sender<ActorResult<()>>,
    },
    Resize {
        size: SessionSize,
        response: Sender<ActorResult<SessionSnapshot>>,
    },
    Snapshot {
        response: Sender<ActorResult<SessionSnapshot>>,
    },
    StyledRows {
        start: usize,
        end: usize,
        response: Sender<ActorResult<StyledRowsResponse>>,
    },
    SubscribeEvents {
        after_event_seq: Option<u64>,
        response: Sender<ActorResult<SessionEventReceiver>>,
    },
    #[cfg(test)]
    SubscriberCount {
        response: Sender<ActorResult<usize>>,
    },
    BroadcastEvent {
        event: Box<SessionEvent>,
        response: Sender<ActorResult<()>>,
    },
    Shutdown {
        response: Sender<ActorResult<CompletedSession>>,
    },
    #[cfg(unix)]
    ExtractHandoverState {
        response: Sender<ActorResult<ExtractedHandover>>,
    },
}

#[cfg(unix)]
#[derive(Debug)]
pub struct ExtractedHandover {
    pub fd: std::os::unix::io::RawFd,
    pub pid: u32,
    pub output_seq: u64,
    pub bytes_logged: u64,
}

type ActorResult<T> = Result<T>;
type SharedPtyWriter = Arc<Mutex<Box<dyn Write + Send>>>;

fn run_actor(
    mut state: ActorState,
    command_rx: Receiver<ActorCommand>,
    output_rx: Receiver<ActorMessage>,
) {
    loop {
        if state.output_closed {
            match command_rx.recv_timeout(Duration::from_millis(20)) {
                Ok(command) => {
                    if state.handle_command(command, &command_rx, &output_rx) {
                        break;
                    }
                }
                Err(RecvTimeoutError::Timeout) => {
                    state.reap_child();
                    state.broadcast_exit();
                    state.flush_subscribers();
                }
                Err(RecvTimeoutError::Disconnected) => break,
            }
            continue;
        }

        match command_rx.try_recv() {
            Ok(command) => {
                if state.handle_command(command, &command_rx, &output_rx) {
                    break;
                }
                continue;
            }
            Err(TryRecvError::Disconnected) => break,
            Err(TryRecvError::Empty) => {}
        }

        match output_rx.recv_timeout(Duration::from_millis(20)) {
            Ok(message) => state.handle_output(message),
            Err(RecvTimeoutError::Timeout) => state.flush_subscribers(),
            Err(RecvTimeoutError::Disconnected) => {
                state.output_closed = true;
                state.mark_exited();
                state.broadcast_exit();
                state.flush_subscribers();
            }
        }
    }
}

impl ActorState {
    #[cfg(unix)]
    fn extract_handover_state(&mut self) -> Result<ExtractedHandover> {
        let fd = self
            .master
            .as_raw_fd()
            .ok_or_else(|| anyhow!("MasterPty has no raw fd"))?;

        let dup_fd = unsafe { libc::dup(fd) };
        if dup_fd < 0 {
            bail!(
                "failed to dup PTY master: {}",
                std::io::Error::last_os_error()
            );
        }

        let pid = self
            .child
            .process_id()
            .ok_or_else(|| anyhow!("Child process has no process ID"))?;

        Ok(ExtractedHandover {
            fd: dup_fd,
            pid,
            output_seq: self.output.output_seq,
            bytes_logged: self.output.bytes_logged,
        })
    }

    fn handle_output(&mut self, message: ActorMessage) {
        match message {
            ActorMessage::Output(bytes) => match self.output.ingest(&bytes) {
                Ok(current_working_directory) => {
                    if let Some(current_working_directory) = current_working_directory {
                        self.context = resolve_session_context(Some(&current_working_directory));
                        self.current_working_directory = Some(current_working_directory);
                    }
                    if let Some(session_id) = self.event_session_id.clone() {
                        self.broadcast(SessionEvent::Output {
                            session_id,
                            output_seq: self.output.output_seq,
                            bytes,
                        });
                    }
                }
                Err(error) => tracing::warn!(error = ?error, "failed to ingest PTY output"),
            },
            ActorMessage::OutputClosed(result) => {
                if let Err(error) = result {
                    tracing::warn!(error = ?error, "PTY output reader closed with error");
                }
                self.output_closed = true;
                self.mark_exited();
                self.broadcast_exit();
            }
        }
    }

    fn handle_command(
        &mut self,
        command: ActorCommand,
        command_rx: &Receiver<ActorCommand>,
        output_rx: &Receiver<ActorMessage>,
    ) -> bool {
        match command {
            ActorCommand::WriteInput { bytes, response } => {
                let _ = response.send(self.write_input(&bytes));
                false
            }
            ActorCommand::Resize { size, response } => {
                let _ = response.send(self.resize(size));
                false
            }
            ActorCommand::Snapshot { response } => {
                let _ = response.send(Ok(self.snapshot()));
                false
            }
            ActorCommand::StyledRows {
                start,
                end,
                response,
            } => {
                let _ = response.send(self.styled_rows(start, end));
                false
            }
            ActorCommand::SubscribeEvents {
                after_event_seq,
                response,
            } => {
                let _ = response.send(self.subscribe_events(after_event_seq));
                false
            }
            #[cfg(test)]
            ActorCommand::SubscriberCount { response } => {
                self.flush_subscribers();
                let _ = response.send(Ok(self.subscribers.len()));
                false
            }
            ActorCommand::BroadcastEvent { event, response } => {
                self.broadcast(*event);
                let _ = response.send(Ok(()));
                false
            }
            ActorCommand::Shutdown { response } => {
                let _ = response.send(self.shutdown(command_rx, output_rx));
                true
            }
            #[cfg(unix)]
            ActorCommand::ExtractHandoverState { response } => {
                let _ = response.send(self.extract_handover_state());
                false
            }
        }
    }

    fn write_input(&mut self, bytes: &[u8]) -> Result<()> {
        ensure!(!self.exited, "session has already exited");
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| anyhow!("PTY writer lock poisoned"))?;
        writer.write_all(bytes).context("writing input to PTY")?;
        writer.flush().context("flushing PTY input")?;
        Ok(())
    }

    fn resize(&mut self, size: SessionSize) -> Result<SessionSnapshot> {
        size.validate()?;
        self.master
            .resize(pty_size(&size))
            .context("resizing PTY")?;
        self.output
            .reflow_from_log(&self.log_path, &size, self.writer.clone())?;
        self.size = size;
        let snapshot = self.snapshot();
        if let Some(session_id) = self.event_session_id.clone() {
            self.broadcast(SessionEvent::Snapshot {
                session_id,
                snapshot: snapshot.clone(),
            });
        }
        Ok(snapshot)
    }

    fn snapshot(&self) -> SessionSnapshot {
        snapshot_from_output(
            &self.output,
            &self.size,
            self.current_working_directory.clone(),
            self.context.clone(),
            self.exited,
        )
    }

    fn styled_rows(&self, start: usize, end: usize) -> Result<StyledRowsResponse> {
        ensure!(start <= end, "styled row start must be before end");
        let row_count = self.output.terminal.screen().scrollback_rows();
        ensure!(
            end <= row_count,
            "styled row range {start}..{end} exceeds retained row count {row_count}"
        );
        Ok(StyledRowsResponse {
            output_seq: self.output.output_seq,
            start,
            rows: styled_visible_rows_for_range(&self.output.terminal, start, end),
        })
    }

    fn shutdown(
        &mut self,
        command_rx: &Receiver<ActorCommand>,
        output_rx: &Receiver<ActorMessage>,
    ) -> Result<CompletedSession> {
        if !self.exited {
            self.reap_child();
            if !self.exited {
                self.child.kill().context("terminating PTY child")?;
                self.exited = true;
            }
        }
        self.drain_shutdown_output(command_rx, output_rx);
        self.reap_child();
        self.output.log.flush().context("flushing session log")?;

        let completed = self.completed_session();
        self.broadcast_completed(completed.clone());

        Ok(completed)
    }

    fn subscribe_events(&mut self, after_event_seq: Option<u64>) -> Result<SessionEventReceiver> {
        ensure!(
            self.event_session_id.is_some(),
            "session actor was not configured for event fan-out"
        );
        let (tx, rx) = mpsc::sync_channel(EVENT_SUBSCRIBER_BUFFER);
        let next_event_seq = after_event_seq
            .map(|event_seq| event_seq.saturating_add(1))
            .unwrap_or(self.next_event_seq);
        self.subscribers
            .push(EventSubscriber { tx, next_event_seq });
        self.flush_subscribers();
        Ok(rx)
    }

    fn broadcast(&mut self, event: SessionEvent) {
        self.record_event(event);
        self.flush_subscribers();
    }

    fn record_event(&mut self, event: SessionEvent) {
        let envelope = SessionEventEnvelope {
            event_seq: self.next_event_seq,
            event,
        };
        self.next_event_seq += 1;
        self.event_log.push_back(envelope);
        while self.event_log.len() > EVENT_REPLAY_BUFFER {
            self.event_log.pop_front();
        }
    }

    fn flush_subscribers(&mut self) {
        let mut retained = Vec::with_capacity(self.subscribers.len());
        let mut subscribers = std::mem::take(&mut self.subscribers);

        for mut subscriber in subscribers.drain(..) {
            if self.flush_subscriber(&mut subscriber) {
                retained.push(subscriber);
            }
        }

        self.subscribers = retained;
    }

    fn flush_subscriber(&self, subscriber: &mut EventSubscriber) -> bool {
        loop {
            if subscriber.next_event_seq >= self.next_event_seq {
                return true;
            }

            let Some(oldest_event_seq) = self.event_log.front().map(|event| event.event_seq) else {
                return true;
            };

            if subscriber.next_event_seq < oldest_event_seq {
                let resync = self.resync_envelope();
                return match subscriber.tx.try_send(resync) {
                    Ok(()) => {
                        subscriber.next_event_seq = self.next_event_seq;
                        true
                    }
                    Err(TrySendError::Full(_)) => true,
                    Err(TrySendError::Disconnected(_)) => false,
                };
            }

            let event_index = (subscriber.next_event_seq - oldest_event_seq) as usize;
            let Some(envelope) = self.event_log.get(event_index).cloned() else {
                return true;
            };

            match subscriber.tx.try_send(envelope) {
                Ok(()) => subscriber.next_event_seq += 1,
                Err(TrySendError::Full(_)) => return true,
                Err(TrySendError::Disconnected(_)) => return false,
            }
        }
    }

    fn resync_envelope(&self) -> SessionEventEnvelope {
        let latest_event_seq = self.next_event_seq.saturating_sub(1);
        let session_id = self
            .event_session_id
            .clone()
            .expect("event fan-out requires session id");
        SessionEventEnvelope {
            event_seq: latest_event_seq,
            event: SessionEvent::ResyncRequired {
                session_id,
                latest_event_seq,
                snapshot: self.snapshot(),
            },
        }
    }

    fn broadcast_exit(&mut self) {
        if !self.exited || self.exit_broadcasted {
            return;
        }

        self.broadcast_completed(self.completed_session());
    }

    fn broadcast_completed(&mut self, completed: CompletedSession) {
        if self.exit_broadcasted {
            return;
        }

        if let Some(session_id) = self.event_session_id.clone() {
            self.broadcast(SessionEvent::Exited {
                session_id,
                completed,
            });
        }
        self.exit_broadcasted = true;
    }

    fn completed_session(&self) -> CompletedSession {
        CompletedSession {
            output_seq: self.output.output_seq,
            bytes_logged: self.output.bytes_logged,
            visible_rows: visible_rows(&self.output.terminal),
        }
    }

    fn mark_exited(&mut self) {
        if self.exited {
            return;
        }

        self.reap_child();
    }

    fn reap_child(&mut self) {
        match self.child.try_wait() {
            Ok(Some(_)) => self.exited = true,
            Ok(None) => {}
            Err(error) => tracing::warn!(error = ?error, "failed polling PTY child"),
        }
    }

    fn drain_shutdown_output(
        &mut self,
        command_rx: &Receiver<ActorCommand>,
        output_rx: &Receiver<ActorMessage>,
    ) {
        let deadline = Instant::now() + Duration::from_secs(2);

        loop {
            while let Ok(command) = command_rx.try_recv() {
                reject_command_during_shutdown(command);
            }

            if self.output_closed {
                break;
            }

            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                tracing::warn!("timed out draining PTY output during shutdown");
                break;
            }

            match output_rx.recv_timeout(remaining) {
                Ok(ActorMessage::Output(bytes)) => {
                    match self.output.ingest(&bytes) {
                        Ok(current_working_directory) => {
                            if let Some(current_working_directory) = current_working_directory {
                                self.context =
                                    resolve_session_context(Some(&current_working_directory));
                                self.current_working_directory = Some(current_working_directory);
                            }
                        }
                        Err(error) => {
                            tracing::warn!(error = ?error, "failed to ingest PTY output during shutdown");
                            continue;
                        }
                    }
                    if let Some(session_id) = self.event_session_id.clone() {
                        self.broadcast(SessionEvent::Output {
                            session_id,
                            output_seq: self.output.output_seq,
                            bytes,
                        });
                    }
                }
                Ok(ActorMessage::OutputClosed(result)) => {
                    if let Err(error) = result {
                        tracing::warn!(error = ?error, "PTY output reader closed with error");
                    }
                    self.output_closed = true;
                    self.exited = true;
                    self.broadcast_exit();
                    break;
                }
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    self.output_closed = true;
                    self.broadcast_exit();
                    break;
                }
            }
        }
    }
}

fn translate_newlines(bytes: &[u8]) -> std::borrow::Cow<'_, [u8]> {
    let mut last = 0;
    let mut needs_translation = false;
    let mut bare_lf_count = 0;
    for &byte in bytes {
        if byte == b'\n' && last != b'\r' {
            needs_translation = true;
            bare_lf_count += 1;
        }
        last = byte;
    }

    if !needs_translation {
        return std::borrow::Cow::Borrowed(bytes);
    }

    let mut result = Vec::with_capacity(bytes.len() + bare_lf_count);
    last = 0;
    for &byte in bytes {
        if byte == b'\n' && last != b'\r' {
            result.push(b'\r');
        }
        result.push(byte);
        last = byte;
    }
    std::borrow::Cow::Owned(result)
}

impl OutputState {
    fn ingest(&mut self, bytes: &[u8]) -> Result<Option<PathBuf>> {
        self.log
            .write_all(bytes)
            .context("writing PTY output log")?;
        self.bytes_logged += bytes.len() as u64;
        self.output_seq += 1;
        if let Some(cache) = &mut self.log_cache {
            if cache.len() + bytes.len() <= 1024 * 1024 {
                cache.extend_from_slice(bytes);
            } else {
                self.log_cache = None;
            }
        }
        let current_working_directory = self.extract_current_working_directory(bytes);
        let translated = translate_newlines(bytes);
        self.terminal.advance_bytes(&translated);
        Ok(current_working_directory)
    }

    fn replay(&mut self, bytes: &[u8]) -> Result<Option<PathBuf>> {
        self.bytes_logged += bytes.len() as u64;
        self.output_seq += 1;
        if let Some(cache) = &mut self.log_cache {
            if cache.len() + bytes.len() <= 1024 * 1024 {
                cache.extend_from_slice(bytes);
            } else {
                self.log_cache = None;
            }
        }
        Ok(self.advance_replayed_bytes(bytes))
    }

    fn reflow_from_log(
        &mut self,
        log_path: &PathBuf,
        size: &SessionSize,
        writer: SharedPtyWriter,
    ) -> Result<()> {
        let (replay_writer, replay_gate) = replay_gated_pty_writer();
        self.terminal = terminal_with_writer(size, replay_writer);
        self.cwd_sequence_buffer.clear();

        if let Some(cache) = self.log_cache.clone() {
            self.advance_replayed_bytes(&cache);
        } else {
            self.log
                .flush()
                .context("flushing session log before reflow")?;
            let mut replay = File::open(log_path)
                .with_context(|| format!("opening session log {}", log_path.display()))?;
            let mut buffer = [0_u8; 64 * 1024];
            loop {
                let read = replay
                    .read(&mut buffer)
                    .with_context(|| format!("reading session log {}", log_path.display()))?;
                if read == 0 {
                    break;
                }
                self.advance_replayed_bytes(&buffer[..read]);
            }
        }

        let replay_writes = replay_gate.dropped_write_count();
        let replay_flushes = replay_gate.dropped_flush_count();
        self.terminal.advance_bytes(b"\x1b[c");
        replay_gate.wait_for_dropped_activity_quiet_after(replay_writes, replay_flushes)?;
        replay_gate.enable(Box::new(SharedPtyWriterProxy { writer }))?;
        Ok(())
    }

    fn advance_replayed_bytes(&mut self, bytes: &[u8]) -> Option<PathBuf> {
        let current_working_directory = self.extract_current_working_directory(bytes);
        let translated = translate_newlines(bytes);
        self.terminal.advance_bytes(&translated);
        current_working_directory
    }

    fn extract_current_working_directory(&mut self, bytes: &[u8]) -> Option<PathBuf> {
        if self.cwd_sequence_buffer.is_empty() {
            let start = bytes.iter().position(|byte| *byte == 0x1b)?;
            self.cwd_sequence_buffer.extend_from_slice(&bytes[start..]);
        } else {
            self.cwd_sequence_buffer.extend_from_slice(bytes);
        }
        let mut current_working_directory = None;

        while let Some(start) = find_bytes(&self.cwd_sequence_buffer, b"\x1b]7;file://") {
            if start > 0 {
                self.cwd_sequence_buffer.drain(..start);
            }

            let Some(terminator) = find_osc_terminator(&self.cwd_sequence_buffer) else {
                break;
            };
            let payload = &self.cwd_sequence_buffer[b"\x1b]7;file://".len()..terminator];
            if let Some(path) = cwd_from_osc7_payload(payload) {
                current_working_directory = Some(path);
            }

            let drain_to = if self.cwd_sequence_buffer[terminator] == 0x07 {
                terminator + 1
            } else {
                terminator + 2
            };
            self.cwd_sequence_buffer.drain(..drain_to);
        }

        if !self.cwd_sequence_buffer.is_empty()
            && find_bytes(&self.cwd_sequence_buffer, b"\x1b]7;file://").is_none()
        {
            retain_osc_prefix_candidate(&mut self.cwd_sequence_buffer);
        }

        if self.cwd_sequence_buffer.len() > MAX_OSC_BUFFER {
            self.cwd_sequence_buffer.clear();
        }

        current_working_directory
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LogInitialization {
    Truncate,
    ReplayExisting,
}

fn spawn_pty_runtime(
    config: SessionConfig,
    log_initialization: LogInitialization,
) -> Result<PtyRuntime> {
    config.validate()?;

    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(pty_size(&config.size))
        .context("opening PTY")?;

    let mut command = CommandBuilder::new(&config.command);
    for arg in &config.args {
        command.arg(arg);
    }
    if let Some(cwd) = &config.cwd {
        command.cwd(cwd);
    }

    let child = pair
        .slave
        .spawn_command(command)
        .context("spawning PTY child")?;
    drop(pair.slave);

    let reader = pair
        .master
        .try_clone_reader()
        .context("cloning PTY reader")?;
    match log_initialization {
        LogInitialization::Truncate => {
            let writer = shared_pty_writer(pair.master.take_writer().context("taking PTY writer")?);
            let terminal = terminal_with_writer(&config.size, writer.clone());
            let log = OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&config.log_path)
                .with_context(|| format!("opening session log {}", config.log_path.display()))?;
            Ok(PtyRuntime {
                master: pair.master,
                child,
                reader,
                writer,
                output: OutputState {
                    log,
                    terminal,
                    cwd_sequence_buffer: Vec::new(),
                    bytes_logged: 0,
                    output_seq: 0,
                    log_cache: Some(Vec::new()),
                },
                size: config.size,
                log_path: config.log_path,
                current_working_directory: None,
            })
        }
        LogInitialization::ReplayExisting => {
            let (writer, replay_gate) = replay_gated_pty_writer();
            let terminal = terminal_with_writer(&config.size, writer.clone());
            let log = OpenOptions::new()
                .create(true)
                .read(true)
                .append(true)
                .open(&config.log_path)
                .with_context(|| format!("opening session log {}", config.log_path.display()))?;
            let mut output = OutputState {
                log: log.try_clone().context("cloning restored session log")?,
                terminal,
                cwd_sequence_buffer: Vec::new(),
                bytes_logged: 0,
                output_seq: 0,
                log_cache: Some(Vec::new()),
            };
            let replay = fs::read(&config.log_path)
                .with_context(|| format!("reading session log {}", config.log_path.display()))?;
            let replayed_working_directory = if replay.is_empty() {
                None
            } else {
                output.replay(&replay)?
            };
            let current_working_directory =
                restorable_cwd(replayed_working_directory, config.cwd.clone());
            let replay_writes = replay_gate.dropped_write_count();
            let replay_flushes = replay_gate.dropped_flush_count();
            output.terminal.advance_bytes(b"\x1b[c");
            replay_gate.wait_for_dropped_activity_quiet_after(replay_writes, replay_flushes)?;
            replay_gate.enable(pair.master.take_writer().context("taking PTY writer")?)?;
            Ok(PtyRuntime {
                master: pair.master,
                child,
                reader,
                writer,
                output,
                size: config.size,
                log_path: config.log_path,
                current_working_directory,
            })
        }
    }
}

fn output_state_for_log(log_path: &PathBuf, size: SessionSize) -> Result<OutputState> {
    let log = OpenOptions::new()
        .read(true)
        .append(true)
        .open(log_path)
        .with_context(|| format!("opening session log {}", log_path.display()))?;
    Ok(OutputState {
        log,
        terminal: terminal_with_writer(&size, shared_pty_writer(Box::new(std::io::sink()))),
        cwd_sequence_buffer: Vec::new(),
        bytes_logged: 0,
        output_seq: 0,
        log_cache: Some(Vec::new()),
    })
}

fn terminal_with_writer(size: &SessionSize, writer: SharedPtyWriter) -> Terminal {
    Terminal::new(
        terminal_size(size),
        Arc::new(TriageTerminalConfig),
        "Triage",
        env!("CARGO_PKG_VERSION"),
        Box::new(TerminalOutputSink { writer }),
    )
}

fn snapshot_from_output(
    output: &OutputState,
    size: &SessionSize,
    current_working_directory: Option<PathBuf>,
    context: Option<SessionContext>,
    exited: bool,
) -> SessionSnapshot {
    let visible_rows = visible_rows(&output.terminal);
    let styled_rows_start = visible_rows.len().saturating_sub(size.rows);
    SessionSnapshot {
        output_seq: output.output_seq,
        bytes_logged: output.bytes_logged,
        size: size.clone(),
        styled_rows: styled_visible_rows_for_range(
            &output.terminal,
            styled_rows_start,
            visible_rows.len(),
        ),
        styled_rows_start,
        visible_rows,
        cursor: terminal_cursor(&output.terminal),
        current_working_directory,
        context,
        bracketed_paste_enabled: output.terminal.bracketed_paste_enabled(),
        exited,
    }
}

fn pty_size(size: &SessionSize) -> PtySize {
    PtySize {
        rows: size.rows as u16,
        cols: size.cols as u16,
        pixel_width: size.pixel_width as u16,
        pixel_height: size.pixel_height as u16,
    }
}

fn terminal_size(size: &SessionSize) -> TerminalSize {
    TerminalSize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: size.pixel_width,
        pixel_height: size.pixel_height,
        dpi: size.dpi as u32,
    }
}

fn read_pty_output(mut reader: Box<dyn Read + Send>, tx: SyncSender<ActorMessage>) {
    let mut chunk = [0; 8192];

    loop {
        match reader.read(&mut chunk) {
            Ok(0) => {
                let _ = tx.send(ActorMessage::OutputClosed(Ok(())));
                break;
            }
            Ok(read_len) => {
                if tx
                    .send(ActorMessage::Output(chunk[..read_len].to_vec()))
                    .is_err()
                {
                    break;
                }
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::BrokenPipe | ErrorKind::ConnectionReset | ErrorKind::UnexpectedEof
                ) || is_closed_pty_error(&error) =>
            {
                let _ = tx.send(ActorMessage::OutputClosed(Ok(())));
                break;
            }
            Err(error) => {
                let _ = tx.send(ActorMessage::OutputClosed(
                    Err(error).context("reading PTY output"),
                ));
                break;
            }
        }
    }
}

fn recv_actor_result<T>(rx: Receiver<ActorResult<T>>, context: &'static str) -> Result<T> {
    rx.recv()
        .with_context(|| format!("{context}: actor stopped"))?
        .with_context(|| context)
}

fn reject_command_during_shutdown(command: ActorCommand) {
    let error = anyhow!("session is shutting down");
    match command {
        ActorCommand::WriteInput { response, .. } => {
            let _ = response.send(Err(error));
        }
        ActorCommand::Resize { response, .. } => {
            let _ = response.send(Err(error));
        }
        ActorCommand::Snapshot { response } => {
            let _ = response.send(Err(error));
        }
        ActorCommand::StyledRows { response, .. } => {
            let _ = response.send(Err(error));
        }
        ActorCommand::SubscribeEvents { response, .. } => {
            let _ = response.send(Err(error));
        }
        #[cfg(test)]
        ActorCommand::SubscriberCount { response } => {
            let _ = response.send(Err(error));
        }
        ActorCommand::BroadcastEvent { response, .. } => {
            let _ = response.send(Err(error));
        }
        ActorCommand::Shutdown { response } => {
            let _ = response.send(Err(error));
        }
        #[cfg(unix)]
        ActorCommand::ExtractHandoverState { response } => {
            let _ = response.send(Err(error));
        }
    }
}

fn join_thread_with_timeout(handle: JoinHandle<()>, name: &'static str) {
    let deadline = Instant::now() + Duration::from_secs(2);

    while !handle.is_finished() {
        if Instant::now() >= deadline {
            tracing::warn!(thread = name, "timed out joining thread");
            return;
        }
        thread::sleep(Duration::from_millis(10));
    }

    if handle.join().is_err() {
        tracing::error!(thread = name, "thread panicked during shutdown");
    }
}

fn shared_pty_writer(writer: Box<dyn Write + Send>) -> SharedPtyWriter {
    Arc::new(Mutex::new(writer))
}

fn replay_gated_pty_writer() -> (SharedPtyWriter, Arc<ReplayGateState>) {
    let state = Arc::new(ReplayGateState {
        live_writer: Mutex::new(None),
        pass_through: AtomicBool::new(false),
        dropped_writes: AtomicU64::new(0),
        dropped_flushes: AtomicU64::new(0),
    });
    let writer = shared_pty_writer(Box::new(ReplayGateWriter {
        state: state.clone(),
    }));
    (writer, state)
}

struct ReplayGateState {
    live_writer: Mutex<Option<Box<dyn Write + Send>>>,
    pass_through: AtomicBool,
    dropped_writes: AtomicU64,
    dropped_flushes: AtomicU64,
}

impl ReplayGateState {
    fn dropped_write_count(&self) -> u64 {
        self.dropped_writes.load(Ordering::SeqCst)
    }

    fn dropped_flush_count(&self) -> u64 {
        self.dropped_flushes.load(Ordering::SeqCst)
    }

    fn wait_for_dropped_activity_quiet_after(
        &self,
        previous_writes: u64,
        previous_flushes: u64,
    ) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let quiet_period = Duration::from_millis(50);
        let mut last_writes = self.dropped_write_count();
        let mut last_flushes = self.dropped_flush_count();
        let mut saw_activity = last_writes > previous_writes || last_flushes > previous_flushes;
        let mut quiet_since = Instant::now();

        loop {
            let current_writes = self.dropped_write_count();
            let current_flushes = self.dropped_flush_count();
            if current_writes != last_writes || current_flushes != last_flushes {
                last_writes = current_writes;
                last_flushes = current_flushes;
                saw_activity =
                    current_writes > previous_writes || current_flushes > previous_flushes;
                quiet_since = Instant::now();
            }
            if saw_activity && quiet_since.elapsed() >= quiet_period {
                return Ok(());
            }
            ensure!(
                Instant::now() < deadline,
                "timed out draining restored terminal replay replies"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn enable(&self, writer: Box<dyn Write + Send>) -> Result<()> {
        *self
            .live_writer
            .lock()
            .map_err(|_| anyhow!("PTY writer lock poisoned"))? = Some(writer);
        self.pass_through.store(true, Ordering::SeqCst);
        Ok(())
    }
}

struct ReplayGateWriter {
    state: Arc<ReplayGateState>,
}

struct SharedPtyWriterProxy {
    writer: SharedPtyWriter,
}

impl Write for SharedPtyWriterProxy {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.writer
            .lock()
            .map_err(|_| std::io::Error::other("PTY writer lock poisoned"))?
            .write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.writer
            .lock()
            .map_err(|_| std::io::Error::other("PTY writer lock poisoned"))?
            .flush()
    }
}

impl Write for ReplayGateWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if !self.state.pass_through.load(Ordering::SeqCst) {
            self.state.dropped_writes.fetch_add(1, Ordering::SeqCst);
            return Ok(buf.len());
        }
        let mut live_writer = self
            .state
            .live_writer
            .lock()
            .map_err(|_| std::io::Error::other("PTY writer lock poisoned"))?;
        let live_writer = live_writer
            .as_mut()
            .ok_or_else(|| std::io::Error::other("PTY writer is not installed"))?;
        live_writer.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        if !self.state.pass_through.load(Ordering::SeqCst) {
            self.state.dropped_flushes.fetch_add(1, Ordering::SeqCst);
            return Ok(());
        }
        let mut live_writer = self
            .state
            .live_writer
            .lock()
            .map_err(|_| std::io::Error::other("PTY writer lock poisoned"))?;
        let live_writer = live_writer
            .as_mut()
            .ok_or_else(|| std::io::Error::other("PTY writer is not installed"))?;
        live_writer.flush()
    }
}

fn resolve_session_context(cwd: Option<&PathBuf>) -> Option<SessionContext> {
    let cwd = cwd?;
    let worktree_root = git_path_output(cwd, &["rev-parse", "--show-toplevel"]);
    let repository_root = git_repository_root(cwd).or_else(|| worktree_root.clone());
    let branch = git_output(cwd, &["branch", "--show-current"]).filter(|branch| !branch.is_empty());

    (repository_root.is_some() || worktree_root.is_some() || branch.is_some()).then_some(
        SessionContext {
            repository_root,
            worktree_root,
            branch,
        },
    )
}

fn git_repository_root(cwd: &PathBuf) -> Option<PathBuf> {
    let common_dir = git_path_output(
        cwd,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    if common_dir.file_name() == Some(OsStr::new(".git")) {
        return common_dir.parent().map(Path::to_path_buf);
    }
    let mut ancestors = common_dir.ancestors();
    let _worktree_name = ancestors.next()?;
    let worktrees_dir = ancestors.next()?;
    if worktrees_dir.file_name() != Some(OsStr::new("worktrees")) {
        return None;
    }
    let git_dir = ancestors.next()?;
    if git_dir.file_name() != Some(OsStr::new(".git")) {
        return None;
    }
    git_dir.parent().map(Path::to_path_buf)
}

fn git_raw_output(cwd: &PathBuf, args: &[&str]) -> Option<Vec<u8>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
        .ok()?;
    output.status.success().then_some(output.stdout)
}

/// Decodes git stdout as UTF-8. Use only for textual fields (e.g. branch
/// names); paths can contain non-UTF-8 bytes and must use `git_path_output`.
fn git_output(cwd: &PathBuf, args: &[&str]) -> Option<String> {
    let value = String::from_utf8(git_raw_output(cwd, args)?).ok()?;
    let value = value.trim().to_string();
    (!value.is_empty()).then_some(value)
}

fn trim_ascii_whitespace(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|b| !b.is_ascii_whitespace())
        .map_or(start, |index| index + 1);
    &bytes[start..end]
}

/// Resolves a path-valued git command without lossy UTF-8 decoding so repos
/// whose path contains non-UTF-8 bytes still produce a usable `PathBuf`.
#[cfg(unix)]
fn git_path_output(cwd: &PathBuf, args: &[&str]) -> Option<PathBuf> {
    use std::ffi::OsString;

    let bytes = git_raw_output(cwd, args)?;
    let trimmed = trim_ascii_whitespace(&bytes);
    (!trimmed.is_empty()).then(|| PathBuf::from(OsString::from_vec(trimmed.to_vec())))
}

#[cfg(not(unix))]
fn git_path_output(cwd: &PathBuf, args: &[&str]) -> Option<PathBuf> {
    git_output(cwd, args).map(PathBuf::from)
}

struct TerminalOutputSink {
    writer: SharedPtyWriter,
}

impl Write for TerminalOutputSink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.writer
            .lock()
            .map_err(|_| std::io::Error::other("PTY writer lock poisoned"))?
            .write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.writer
            .lock()
            .map_err(|_| std::io::Error::other("PTY writer lock poisoned"))?
            .flush()
    }
}

#[cfg(unix)]
fn is_closed_pty_error(error: &std::io::Error) -> bool {
    // Linux PTY masters report EIO after the slave side closes.
    error.raw_os_error() == Some(5)
}

#[cfg(not(unix))]
fn is_closed_pty_error(_: &std::io::Error) -> bool {
    false
}

fn visible_rows(terminal: &Terminal) -> Vec<String> {
    let screen = terminal.screen();
    let end = screen.scrollback_rows();

    screen
        .lines_in_phys_range(0..end)
        .iter()
        .map(|line| line.as_str().trim_end().to_owned())
        .collect()
}

#[cfg(test)]
fn styled_visible_rows(terminal: &Terminal) -> Vec<StyledRow> {
    let screen = terminal.screen();
    let end = screen.scrollback_rows();
    styled_visible_rows_for_range(terminal, 0, end)
}

fn styled_visible_rows_for_range(terminal: &Terminal, start: usize, end: usize) -> Vec<StyledRow> {
    let screen = terminal.screen();
    let palette = ColorPalette::default();
    let mut lines = screen.lines_in_phys_range(start..end);

    lines
        .iter_mut()
        .map(|line| {
            let mut spans: Vec<StyledSpan> = Vec::new();
            let mut skip_cells = 0;
            let visible_cols = visible_line_width(&line.as_str());
            let mut col = 0;
            for cell in line.cells_mut() {
                if skip_cells > 0 {
                    skip_cells -= 1;
                    continue;
                }
                let width = cell.width().max(1);
                skip_cells = width.saturating_sub(1);
                let style = terminal_style(cell.attrs(), &palette);
                let text = if col >= visible_cols {
                    " ".repeat(width)
                } else {
                    cell.str().to_string()
                };
                col += width;
                if let Some(span) = spans.last_mut()
                    && span.style == style
                {
                    span.text.push_str(&text);
                    continue;
                }
                spans.push(StyledSpan { text, style });
            }
            StyledRow { spans }
        })
        .collect()
}

fn visible_line_width(line: &str) -> usize {
    UnicodeWidthStr::width(line.trim_end())
}

fn terminal_cursor(terminal: &Terminal) -> TerminalCursor {
    let screen = terminal.screen();
    let cursor = terminal.cursor_pos();
    TerminalCursor {
        row: screen
            .scrollback_rows()
            .saturating_sub(screen.physical_rows)
            + cursor.y.max(0) as usize,
        col: cursor.x,
        visible: matches!(
            cursor.visibility,
            wezterm_surface::CursorVisibility::Visible
        ),
    }
}

fn terminal_style(attrs: &wezterm_term::CellAttributes, palette: &ColorPalette) -> TerminalStyle {
    TerminalStyle {
        foreground: terminal_color(attrs.foreground(), palette, true),
        background: terminal_color(attrs.background(), palette, false),
        bold: attrs.intensity() == Intensity::Bold,
        dim: attrs.intensity() == Intensity::Half,
        italic: attrs.italic(),
        underline: attrs.underline() != Underline::None,
        reverse: attrs.reverse(),
    }
}

fn terminal_color(
    color: ColorAttribute,
    palette: &ColorPalette,
    foreground: bool,
) -> Option<TerminalColor> {
    if color == ColorAttribute::Default {
        return None;
    }
    let SrgbaTuple(red, green, blue, _) = if foreground {
        palette.resolve_fg(color)
    } else {
        palette.resolve_bg(color)
    };
    Some(TerminalColor {
        red: srgb_component(red),
        green: srgb_component(green),
        blue: srgb_component(blue),
    })
}

fn srgb_component(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * 255.0).round() as u8
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn find_osc_terminator(bytes: &[u8]) -> Option<usize> {
    let mut index = b"\x1b]7;file://".len();
    while index < bytes.len() {
        if bytes[index] == 0x07 {
            return Some(index);
        }
        if bytes[index] == 0x1b && bytes.get(index + 1) == Some(&b'\\') {
            return Some(index);
        }
        index += 1;
    }
    None
}

fn retain_osc_prefix_candidate(buffer: &mut Vec<u8>) {
    let prefix = b"\x1b]7;file://";
    let keep = (1..prefix.len())
        .rev()
        .find(|len| buffer.ends_with(&prefix[..*len]))
        .unwrap_or(0);
    if keep == 0 {
        buffer.clear();
    } else if buffer.len() > keep {
        buffer.drain(..buffer.len() - keep);
    }
}

fn cwd_from_osc7_payload(payload: &[u8]) -> Option<PathBuf> {
    let slash = payload.iter().position(|byte| *byte == b'/')?;
    let path_bytes = percent_decode_uri_path(&payload[slash..])?;
    path_buf_from_uri_path_bytes(path_bytes)
}

#[cfg(unix)]
fn path_buf_from_uri_path_bytes(path_bytes: Vec<u8>) -> Option<PathBuf> {
    Some(std::ffi::OsString::from_vec(path_bytes).into())
}

#[cfg(not(unix))]
fn path_buf_from_uri_path_bytes(path_bytes: Vec<u8>) -> Option<PathBuf> {
    String::from_utf8(path_bytes).ok().map(PathBuf::from)
}

fn percent_decode_uri_path(path: &[u8]) -> Option<Vec<u8>> {
    let mut decoded = Vec::with_capacity(path.len());
    let mut index = 0;
    while index < path.len() {
        if path[index] == b'%' {
            let high = hex_value(*path.get(index + 1)?)?;
            let low = hex_value(*path.get(index + 2)?)?;
            decoded.push((high << 4) | low);
            index += 3;
        } else {
            decoded.push(path[index]);
            index += 1;
        }
    }
    Some(decoded)
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

impl triage_transport_ws::WebSocketAuthenticator for SessionManager {
    fn require_pairing(&self) -> bool {
        self.require_pairing
    }

    fn authenticate(&self, client_id: &ClientId, token: &str) -> Result<bool> {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        let hash = hex::encode(hasher.finalize());

        let devices = self.paired_devices()?;
        if let Some(stored_hash) = devices.get(client_id) {
            Ok(stored_hash == &hash)
        } else {
            Ok(false)
        }
    }

    fn pair(&self, code: &str, client_id: &ClientId) -> Result<String> {
        use rand::Rng;
        use sha2::{Digest, Sha256};

        let normalized = normalize_pairing_code(code);
        let mut codes = self.pairing_codes()?;
        if let Some(expiry) = codes.get(&normalized) {
            if Instant::now() > *expiry {
                codes.remove(&normalized);
                anyhow::bail!("pairing PIN has expired");
            }
        } else {
            anyhow::bail!("invalid pairing PIN");
        }

        codes.remove(&normalized);

        let mut token_bytes = [0u8; 32];
        rand::thread_rng().fill(&mut token_bytes);
        let token = hex::encode(token_bytes);

        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        let hash = hex::encode(hasher.finalize());

        let mut devices = self.paired_devices()?;
        devices.insert(client_id.clone(), hash);

        save_paired_devices(&self.config.log_dir, &devices)?;

        let pairing_code_path = self.config.log_dir.join("pairing_code.json");
        if pairing_code_path.exists() {
            let _ = fs::remove_file(pairing_code_path);
        }

        Ok(token)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn output_state_extracts_osc7_working_directory() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        assert!(
            output
                .ingest(b"\x1b]7;file://host/tmp/tria")
                .unwrap()
                .is_none()
        );
        let cwd = output.ingest(b"ge\x1b\\").unwrap();

        assert_eq!(cwd, Some(PathBuf::from("/tmp/triage")));
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_tracks_bracketed_paste_mode() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        assert!(!output.terminal.bracketed_paste_enabled());
        output
            .ingest(b"\x1b[?2004h")
            .expect("enable bracketed paste");
        assert!(output.terminal.bracketed_paste_enabled());
        output
            .ingest(b"\x1b[?2004l")
            .expect("disable bracketed paste");
        assert!(!output.terminal.bracketed_paste_enabled());
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_skips_cwd_scan_when_chunk_has_no_escape() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        let cwd = output
            .ingest(b"plain output without control bytes")
            .unwrap();

        assert_eq!(cwd, None);
        assert!(output.cwd_sequence_buffer.is_empty());
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_preserves_split_osc7_prefix_candidate() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        assert!(output.ingest(b"noise\x1b]7;file").unwrap().is_none());
        let cwd = output.ingest(b"://host/tmp/split\x07").unwrap();

        assert_eq!(cwd, Some(PathBuf::from("/tmp/split")));
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_decodes_osc7_percent_encoded_working_directory() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        let cwd = output
            .ingest(b"\x1b]7;file://host/tmp/a%20b/%23hash%25\x07")
            .unwrap();

        assert_eq!(cwd, Some(PathBuf::from("/tmp/a b/#hash%")));
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    #[cfg(unix)]
    fn output_state_preserves_non_utf8_percent_encoded_working_directory() {
        use std::os::unix::ffi::OsStrExt;

        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        let cwd = output.ingest(b"\x1b]7;file://host/tmp/%FF\x07").unwrap();

        assert_eq!(
            cwd.as_ref().expect("cwd").as_os_str().as_bytes(),
            b"/tmp/\xFF"
        );
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_ignores_malformed_osc7_percent_encoding() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        let cwd = output.ingest(b"\x1b]7;file://host/tmp/a%2x\x07").unwrap();

        assert_eq!(cwd, None);
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_bounds_unterminated_osc7_working_directory() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        output
            .ingest(b"\x1b]7;file://host/")
            .expect("ingest partial OSC 7");
        output
            .ingest(&vec![b'a'; MAX_OSC_BUFFER * 2])
            .expect("ingest unterminated OSC 7 payload");

        assert!(output.cwd_sequence_buffer.is_empty());
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_recovers_after_aborting_overlong_osc7_working_directory() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        output
            .ingest(b"\x1b]7;file://host/")
            .expect("ingest partial OSC 7");
        output
            .ingest(&vec![b'a'; MAX_OSC_BUFFER * 2])
            .expect("ingest overlong unterminated OSC 7 payload");

        let cwd = output
            .ingest(b"\x1b]7;file://host/tmp/recovered\x07")
            .expect("ingest next OSC 7");

        assert_eq!(cwd, Some(PathBuf::from("/tmp/recovered")));
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn styled_rows_preserve_foreground_color() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        output
            .ingest(b"\x1b[31mred\x1b[0m plain")
            .expect("ingest styled output");
        let rows = styled_visible_rows(&output.terminal);
        let red_span = rows
            .iter()
            .flat_map(|row| &row.spans)
            .find(|span| span.text.contains("red"))
            .expect("red span");

        assert!(red_span.style.foreground.is_some());
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn styled_rows_preserve_dim_intensity() {
        let log_path = unique_log_path();
        let mut output = test_output_state(&log_path, SessionSize::default());

        output
            .ingest(b"\x1b[2mhint\x1b[0m")
            .expect("ingest dim output");
        let rows = styled_visible_rows(&output.terminal);
        let dim_span = rows
            .iter()
            .flat_map(|row| &row.spans)
            .find(|span| span.text.contains("hint"))
            .expect("dim span");

        assert!(dim_span.style.dim);
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn visible_rows_include_retained_scrollback() {
        let log_path = unique_log_path();
        let mut output = test_output_state(
            &log_path,
            SessionSize {
                rows: 3,
                cols: 24,
                pixel_width: 240,
                pixel_height: 60,
                dpi: 96,
            },
        );

        output
            .ingest(b"line-1\r\nline-2\r\nline-3\r\nline-4\r\nline-5")
            .expect("ingest scrollback output");
        let rows = visible_rows(&output.terminal);

        assert!(
            rows.iter().any(|row| row.contains("line-1")),
            "scrollback rows should include line-1: {rows:?}"
        );
        assert!(
            rows.iter().any(|row| row.contains("line-5")),
            "scrollback rows should include line-5: {rows:?}"
        );
        assert!(rows.len() > output.terminal.screen().physical_rows);
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_reflows_log_at_resized_width() {
        let log_path = unique_log_path();
        let narrow = SessionSize {
            rows: 6,
            cols: 12,
            pixel_width: 120,
            pixel_height: 120,
            dpi: 96,
        };
        let wide = SessionSize {
            rows: 6,
            cols: 80,
            pixel_width: 800,
            pixel_height: 120,
            dpi: 96,
        };
        let long_line = "0123456789abcdefghijklmnopqrstuvwxyz";
        let mut output = test_output_state(&log_path, narrow);

        output
            .ingest(long_line.as_bytes())
            .expect("ingest long line");
        let bytes_logged = output.bytes_logged;
        let output_seq = output.output_seq;
        let narrow_rows = visible_rows(&output.terminal);
        assert!(
            !narrow_rows.iter().any(|row| row == long_line),
            "narrow terminal should soft-wrap the long line: {narrow_rows:?}"
        );

        output
            .reflow_from_log(
                &log_path,
                &wide,
                shared_pty_writer(Box::new(std::io::sink())),
            )
            .expect("reflow log");

        let wide_rows = visible_rows(&output.terminal);
        assert!(
            wide_rows.iter().any(|row| row == long_line),
            "wide terminal should replay the log without narrow wrapping: {wide_rows:?}"
        );
        assert_eq!(output.bytes_logged, bytes_logged);
        assert_eq!(output.output_seq, output_seq);
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn output_state_reflow_suppresses_historical_terminal_replies() {
        let log_path = unique_log_path();
        let captured = Arc::new(Mutex::new(Vec::new()));
        let writer = shared_pty_writer(Box::new(RecordingWriter {
            bytes: captured.clone(),
        }));
        let mut output = test_output_state(&log_path, SessionSize::default());

        output.ingest(b"\x1b[6n").expect("ingest cursor query");
        captured.lock().expect("captured writer lock").clear();

        output
            .reflow_from_log(&log_path, &SessionSize::default(), writer)
            .expect("reflow log");
        assert!(
            captured.lock().expect("captured writer lock").is_empty(),
            "historical reflow should not write terminal replies to the live PTY"
        );
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn styled_rows_can_be_limited_to_current_viewport() {
        let log_path = unique_log_path();
        let mut output = test_output_state(
            &log_path,
            SessionSize {
                rows: 3,
                cols: 24,
                pixel_width: 240,
                pixel_height: 60,
                dpi: 96,
            },
        );

        output
            .ingest(b"\x1b[31mline-1\r\nline-2\r\nline-3\r\nline-4\r\nline-5\x1b[0m")
            .expect("ingest scrollback output");
        let row_count = output.terminal.screen().scrollback_rows();
        let styled_start = row_count.saturating_sub(output.terminal.screen().physical_rows);
        let rows = styled_visible_rows_for_range(&output.terminal, styled_start, row_count);

        assert_eq!(rows.len(), output.terminal.screen().physical_rows);
        assert!(
            rows.iter()
                .flat_map(|row| &row.spans)
                .any(|span| span.text.contains("line-5"))
        );
        assert!(
            rows.iter()
                .flat_map(|row| &row.spans)
                .all(|span| !span.text.contains("line-1"))
        );
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn styled_rows_response_extracts_requested_history_range() {
        let log_path = unique_log_path();
        let mut config = command_that_prints_marker(log_path.clone());
        config.size = SessionSize {
            rows: 2,
            cols: 24,
            pixel_width: 240,
            pixel_height: 40,
            dpi: 96,
        };
        let actor = SessionActor::spawn(config).expect("spawn session actor");
        let snapshot = wait_for_visible_marker(&actor, "triage-ready");
        let end = snapshot.visible_rows.len().min(2);
        let response = actor.styled_rows(0, end).expect("load styled rows");

        assert_eq!(response.output_seq, snapshot.output_seq);
        assert_eq!(response.start, 0);
        assert_eq!(response.rows.len(), end);
        actor.shutdown().expect("shutdown session actor");
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn session_snapshot_styles_only_current_viewport() {
        let log_path = unique_log_path();
        let actor = SessionActor::spawn(command_that_prints_marker(log_path.clone()))
            .expect("spawn session actor");
        let snapshot = wait_for_visible_marker(&actor, "triage-ready");

        assert!(snapshot.styled_rows.len() <= snapshot.size.rows);
        assert_eq!(
            snapshot.styled_rows_start,
            snapshot
                .visible_rows
                .len()
                .saturating_sub(snapshot.size.rows)
        );
        actor.shutdown().expect("shutdown session actor");
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn session_context_discovers_git_worktree_branch_and_root() {
        let repo = unique_log_dir();
        let _ = std::fs::remove_dir_all(&repo);
        std::fs::create_dir_all(repo.join("nested")).expect("create nested repo dir");
        git_test_command(&repo, &["init"]);
        git_test_command(&repo, &["checkout", "-b", "feature/context"]);

        let context =
            resolve_session_context(Some(&repo.join("nested"))).expect("git session context");

        // git normalizes its reported toplevel (macOS resolves the /var ->
        // /private/var symlink; Windows expands 8.3 names and uses forward
        // slashes), so compare canonicalized paths rather than the raw
        // temp-dir path.
        let canonical = |path: &std::path::Path| {
            std::fs::canonicalize(path).expect("canonicalize path for comparison")
        };
        let expected = Some(canonical(&repo));
        assert_eq!(context.repository_root.as_deref().map(canonical), expected);
        assert_eq!(context.worktree_root.as_deref().map(canonical), expected);
        assert_eq!(context.branch.as_deref(), Some("feature/context"));
        let _ = std::fs::remove_dir_all(repo);
    }

    #[test]
    fn session_context_distinguishes_repository_root_from_linked_worktree() {
        let repo = unique_log_dir();
        let worktree = repo.with_extension("worktree");
        let _ = std::fs::remove_dir_all(&repo);
        let _ = std::fs::remove_dir_all(&worktree);
        std::fs::create_dir_all(&repo).expect("create repo dir");
        git_test_command(&repo, &["init"]);
        git_test_command(&repo, &["config", "user.email", "triage@example.invalid"]);
        git_test_command(&repo, &["config", "user.name", "Triage Test"]);
        std::fs::write(repo.join("README.md"), "test\n").expect("write test file");
        git_test_command(&repo, &["add", "README.md"]);
        git_test_command(&repo, &["commit", "-m", "initial"]);
        git_test_command(
            &repo,
            &[
                "worktree",
                "add",
                "-b",
                "feature/context-worktree",
                worktree.to_str().expect("utf-8 worktree path"),
            ],
        );
        std::fs::create_dir_all(worktree.join("nested")).expect("create nested worktree dir");

        let context =
            resolve_session_context(Some(&worktree.join("nested"))).expect("git session context");

        let canonical = |path: &std::path::Path| {
            std::fs::canonicalize(path).expect("canonicalize path for comparison")
        };
        assert_eq!(
            context.repository_root.as_deref().map(canonical),
            Some(canonical(&repo))
        );
        assert_eq!(
            context.worktree_root.as_deref().map(canonical),
            Some(canonical(&worktree))
        );
        assert_eq!(context.branch.as_deref(), Some("feature/context-worktree"));
        let _ = std::fs::remove_dir_all(worktree);
        let _ = std::fs::remove_dir_all(repo);
    }

    #[test]
    fn session_context_reports_submodule_checkout_as_repository_root() {
        let super_repo = unique_log_dir();
        let submodule_repo = super_repo.with_extension("submodule-src");
        let _ = std::fs::remove_dir_all(&super_repo);
        let _ = std::fs::remove_dir_all(&submodule_repo);
        std::fs::create_dir_all(&super_repo).expect("create super repo dir");
        std::fs::create_dir_all(&submodule_repo).expect("create submodule repo dir");

        git_test_command(&submodule_repo, &["init"]);
        git_test_command(
            &submodule_repo,
            &["config", "user.email", "triage@example.invalid"],
        );
        git_test_command(&submodule_repo, &["config", "user.name", "Triage Test"]);
        std::fs::write(submodule_repo.join("README.md"), "submodule\n")
            .expect("write submodule file");
        git_test_command(&submodule_repo, &["add", "README.md"]);
        git_test_command(&submodule_repo, &["commit", "-m", "initial"]);

        git_test_command(&super_repo, &["init"]);
        git_test_command(
            &super_repo,
            &["config", "user.email", "triage@example.invalid"],
        );
        git_test_command(&super_repo, &["config", "user.name", "Triage Test"]);
        git_test_command(
            &super_repo,
            &[
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "add",
                submodule_repo.to_str().expect("utf-8 submodule repo path"),
                "vendor/submodule",
            ],
        );
        git_test_command(&super_repo, &["commit", "-m", "add submodule"]);
        std::fs::create_dir_all(super_repo.join("vendor/submodule/nested"))
            .expect("create nested submodule dir");

        let submodule_checkout = super_repo.join("vendor/submodule");
        let context = resolve_session_context(Some(&submodule_checkout.join("nested")))
            .expect("git session context");

        let canonical = |path: &std::path::Path| {
            std::fs::canonicalize(path).expect("canonicalize path for comparison")
        };
        let expected = Some(canonical(&submodule_checkout));
        assert_eq!(context.repository_root.as_deref().map(canonical), expected);
        assert_eq!(context.worktree_root.as_deref().map(canonical), expected);
        let _ = std::fs::remove_dir_all(super_repo);
        let _ = std::fs::remove_dir_all(submodule_repo);
    }

    #[test]
    fn session_context_is_absent_outside_git_worktree() {
        let dir = unique_log_dir();
        std::fs::create_dir_all(&dir).expect("create non-git dir");

        assert!(resolve_session_context(Some(&dir)).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn test_translate_newlines_direct() {
        use std::borrow::Cow;

        // Empty bytes should remain borrowed and empty
        assert!(matches!(translate_newlines(b""), Cow::Borrowed(b"")));

        // Normal text without bare newlines should remain borrowed
        assert!(matches!(
            translate_newlines(b"hello world"),
            Cow::Borrowed(b"hello world")
        ));
        assert!(matches!(
            translate_newlines(b"hello\r\nworld\r\n"),
            Cow::Borrowed(b"hello\r\nworld\r\n")
        ));

        // Text with a bare newline should be translated to Owned with \r\n
        let translated = translate_newlines(b"hello\nworld");
        assert!(matches!(translated, Cow::Owned(_)));
        assert_eq!(translated.as_ref(), b"hello\r\nworld");

        // Mixed content with both CRLF and bare newlines should translate only bare ones
        let mixed = translate_newlines(b"hello\r\nworld\nagain\r\n");
        assert!(matches!(mixed, Cow::Owned(_)));
        assert_eq!(mixed.as_ref(), b"hello\r\nworld\r\nagain\r\n");
    }

    #[test]
    fn visible_rows_align_raw_bare_line_feed_to_column_0() {
        let log_path = unique_log_path();
        let mut output = test_output_state(
            &log_path,
            SessionSize {
                rows: 4,
                cols: 32,
                pixel_width: 320,
                pixel_height: 80,
                dpi: 96,
            },
        );

        output
            .ingest(b"Nodes: 330\nEdges: 2400\nFiles: 8")
            .expect("ingest bare line feeds");
        let rows = visible_rows(&output.terminal);

        assert!(rows.iter().any(|row| row == "Nodes: 330"));
        assert!(rows.iter().any(|row| row == "Edges: 2400"));
        assert!(rows.iter().any(|row| row == "Files: 8"));
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn translate_newlines_across_chunk_boundaries() {
        let log_path = unique_log_path();
        let mut output = test_output_state(
            &log_path,
            SessionSize {
                rows: 4,
                cols: 32,
                pixel_width: 320,
                pixel_height: 80,
                dpi: 96,
            },
        );

        // First chunk ends with \r
        output.ingest(b"Nodes: 330\r").expect("ingest first chunk");
        // Second chunk starts with \n
        output
            .ingest(b"\nEdges: 2400")
            .expect("ingest second chunk");

        let rows = visible_rows(&output.terminal);
        assert!(rows.iter().any(|row| row == "Nodes: 330"));
        assert!(rows.iter().any(|row| row == "Edges: 2400"));
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn terminal_cursor_uses_scrollback_row_coordinates() {
        let log_path = unique_log_path();
        let mut output = test_output_state(
            &log_path,
            SessionSize {
                rows: 3,
                cols: 24,
                pixel_width: 240,
                pixel_height: 60,
                dpi: 96,
            },
        );

        output
            .ingest(b"line-1\r\nline-2\r\nline-3\r\nline-4\r\nline-5")
            .expect("ingest scrollback output");
        let cursor = terminal_cursor(&output.terminal);

        assert!(
            cursor.row
                >= output
                    .terminal
                    .screen()
                    .scrollback_rows()
                    .saturating_sub(output.terminal.screen().physical_rows),
            "cursor should be positioned within the scrollback-backed row list: {cursor:?}"
        );
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn styled_rows_preserve_trailing_background_cells() {
        let log_path = unique_log_path();
        let mut output = test_output_state(
            &log_path,
            SessionSize {
                rows: 2,
                cols: 12,
                pixel_width: 120,
                pixel_height: 40,
                dpi: 96,
            },
        );

        output
            .ingest(b"\x1b[44mbox    \x1b[0m")
            .expect("ingest background output");
        let rows = styled_visible_rows(&output.terminal);
        let background_span = rows
            .iter()
            .flat_map(|row| &row.spans)
            .find(|span| span.text.contains("box"))
            .expect("background span");

        assert_eq!(background_span.text, "box    ");
        assert!(background_span.style.background.is_some());
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn styled_rows_preserve_clear_to_end_background_cells() {
        let log_path = unique_log_path();
        let mut output = test_output_state(
            &log_path,
            SessionSize {
                rows: 2,
                cols: 12,
                pixel_width: 120,
                pixel_height: 40,
                dpi: 96,
            },
        );

        output
            .ingest(b"\x1b[48;2;32;32;32m\x1b[K")
            .expect("ingest background clear output");
        let rows = styled_visible_rows(&output.terminal);
        let background_span = rows
            .iter()
            .flat_map(|row| &row.spans)
            .find(|span| span.text == "            ")
            .expect("clear-to-end background span");

        assert_eq!(
            background_span.style.background,
            Some(TerminalColor {
                red: 32,
                green: 32,
                blue: 32
            })
        );
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn styled_rows_do_not_keep_submitted_text_after_line_clear() {
        let log_path = unique_log_path();
        let mut output = test_output_state(
            &log_path,
            SessionSize {
                rows: 2,
                cols: 20,
                pixel_width: 200,
                pixel_height: 40,
                dpi: 96,
            },
        );

        output
            .ingest(b"\x1b[48;2;32;32;32msubmitted prompt\r\x1b[2K\x1b[K")
            .expect("ingest cleared submitted prompt");
        let rows = styled_visible_rows(&output.terminal);
        let text = rows
            .iter()
            .flat_map(|row| &row.spans)
            .map(|span| span.text.as_str())
            .collect::<String>();

        assert!(!text.contains("submitted prompt"), "{text:?}");
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    fn visible_line_width_uses_terminal_columns() {
        assert_eq!(visible_line_width("e\u{301} "), 1);
        assert_eq!(visible_line_width("表 "), 2);
    }

    #[test]
    fn terminal_color_queries_are_written_back_to_pty() {
        let log_path = unique_log_path();
        let responses = Arc::new(Mutex::new(Vec::new()));
        let mut output = test_output_state_with_writer(
            &log_path,
            SessionSize::default(),
            Box::new(RecordingWriter {
                bytes: responses.clone(),
            }),
        );

        output
            .ingest(b"\x1b]11;?\x07")
            .expect("ingest background color query");
        let deadline = Instant::now() + Duration::from_secs(2);
        let response = loop {
            let response = responses.lock().expect("response buffer lock").clone();
            if !response.is_empty() || Instant::now() >= deadline {
                break response;
            }
            std::thread::sleep(Duration::from_millis(10));
        };

        assert!(
            std::str::from_utf8(&response)
                .expect("terminal response utf8")
                .contains("]11;"),
            "expected OSC 11 terminal response, got {response:?}"
        );
        let _ = std::fs::remove_file(log_path);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn pty_session_logs_raw_bytes_and_updates_visible_rows() {
        let log_path = unique_log_path();
        let mut config = command_that_prints_marker(log_path.clone());
        config.size = SessionSize {
            rows: 6,
            cols: 32,
            pixel_width: 640,
            pixel_height: 240,
            dpi: 96,
        };

        let completed = PtySession::spawn(config)
            .expect("spawn PTY session")
            .drain_until_exit()
            .expect("drain PTY output");

        let logged = std::fs::read(&log_path).expect("read raw PTY log");
        let _ = std::fs::remove_file(&log_path);

        assert_eq!(completed.bytes_logged, logged.len() as u64);
        assert!(completed.output_seq > 0);
        assert!(
            String::from_utf8_lossy(&logged).contains("triage-ready"),
            "raw PTY output did not contain marker: {:?}",
            logged
        );
        assert!(
            completed
                .visible_rows
                .iter()
                .any(|row| row.contains("triage-ready")),
            "visible rows did not contain marker: {:?}",
            completed.visible_rows
        );
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_actor_accepts_input_resizes_snapshots_and_shuts_down() {
        let log_path = unique_log_path();
        let mut config = long_running_shell(log_path.clone());
        config.size = SessionSize {
            rows: 6,
            cols: 40,
            pixel_width: 800,
            pixel_height: 240,
            dpi: 96,
        };

        let actor = SessionActor::spawn(config).expect("spawn session actor");
        actor
            .write_input(input_that_prints_marker())
            .expect("write PTY input");

        let first = wait_for_visible_marker(&actor, "actor-ready");
        assert!(
            first.output_seq > 0,
            "snapshot should include output sequence after PTY output"
        );
        assert!(
            first.bytes_logged > 0,
            "snapshot should include logged byte count"
        );

        let resized = actor
            .resize(SessionSize {
                rows: 8,
                cols: 48,
                pixel_width: 960,
                pixel_height: 320,
                dpi: 96,
            })
            .expect("resize session actor");
        assert_eq!(resized.size.rows, 8);
        assert_eq!(resized.size.cols, 48);
        assert!(resized.output_seq >= first.output_seq);

        let completed = actor.shutdown().expect("shutdown session actor");
        let logged = std::fs::read(&log_path).expect("read raw PTY log");
        let _ = std::fs::remove_file(&log_path);

        assert_eq!(completed.bytes_logged, logged.len() as u64);
        assert!(completed.output_seq >= first.output_seq);
        assert!(
            String::from_utf8_lossy(&logged).contains("actor-ready"),
            "raw PTY output did not contain actor marker: {:?}",
            logged
        );
        assert!(
            completed
                .visible_rows
                .iter()
                .any(|row| row.contains("actor-ready")),
            "final visible rows did not contain marker: {:?}",
            completed.visible_rows
        );
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_actor_keeps_final_state_after_output_closes() {
        let log_path = unique_log_path();
        let mut config = command_that_prints_marker(log_path.clone());
        config.size = SessionSize {
            rows: 6,
            cols: 32,
            pixel_width: 640,
            pixel_height: 240,
            dpi: 96,
        };

        let actor = SessionActor::spawn(config).expect("spawn session actor");
        let snapshot = wait_for_exited_snapshot(&actor);
        assert!(
            snapshot
                .visible_rows
                .iter()
                .any(|row| row.contains("triage-ready")),
            "snapshot visible rows did not contain marker: {:?}",
            snapshot.visible_rows
        );

        let completed = actor.shutdown().expect("shutdown exited session actor");
        let logged = std::fs::read(&log_path).expect("read raw PTY log");
        let _ = std::fs::remove_file(&log_path);

        assert_eq!(completed.bytes_logged, logged.len() as u64);
        assert_eq!(completed.output_seq, snapshot.output_seq);
        assert!(
            completed
                .visible_rows
                .iter()
                .any(|row| row.contains("triage-ready")),
            "completed visible rows did not contain marker: {:?}",
            completed.visible_rows
        );
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_manager_enforces_input_lease_before_writing() {
        let log_dir = unique_log_dir();
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        let mut request = StartSessionRequest::new(long_running_shell_command());
        request.size = SessionSize {
            rows: 6,
            cols: 40,
            pixel_width: 800,
            pixel_height: 240,
            dpi: 96,
        };
        let session_id = manager.start_session(request).expect("start session");
        let observer = ClientId::new("observer").expect("observer id");
        let local_tui = ClientId::new("local-tui").expect("local tui id");
        let remote_agent = ClientId::new("remote-agent").expect("remote agent id");

        let observed = manager
            .attach_session(AttachSessionRequest {
                session_id: session_id.clone(),
                client_id: observer.clone(),
                mode: triage_core::session::AttachMode::Observer,
            })
            .expect("attach observer");
        assert!(observed.lease.holder.is_none());
        assert!(
            manager
                .write_input(WriteInputRequest {
                    session_id: session_id.clone(),
                    client_id: observer,
                    bytes: input_that_prints_marker(),
                })
                .is_err(),
            "observer should not be allowed to write PTY input"
        );

        let controlled = manager
            .attach_session(AttachSessionRequest {
                session_id: session_id.clone(),
                client_id: local_tui.clone(),
                mode: triage_core::session::AttachMode::InteractiveController,
            })
            .expect("attach controller");
        assert_eq!(
            controlled.lease.holder.as_ref().unwrap().client_id,
            local_tui
        );
        manager
            .write_input(WriteInputRequest {
                session_id: session_id.clone(),
                client_id: local_tui.clone(),
                bytes: input_that_prints_marker(),
            })
            .expect("controller writes input");
        let first = wait_for_manager_marker(&manager, session_id.clone(), "actor-ready");
        assert!(first.output_seq > 0);

        let takeover = manager
            .acquire_input_lease(InputLeaseRequest {
                session_id: session_id.clone(),
                client_id: remote_agent.clone(),
                kind: triage_core::session::InputControllerKind::Agent,
            })
            .expect("agent takes lease");
        assert_eq!(takeover.previous.unwrap().client_id, local_tui);
        assert!(
            manager
                .write_input(WriteInputRequest {
                    session_id: session_id.clone(),
                    client_id: local_tui,
                    bytes: input_that_prints_marker(),
                })
                .is_err(),
            "previous holder should not be allowed to write after takeover"
        );

        manager
            .release_input_lease(session_id.clone(), remote_agent.clone())
            .expect("release agent lease");
        assert!(
            manager
                .write_input(WriteInputRequest {
                    session_id: session_id.clone(),
                    client_id: remote_agent,
                    bytes: input_that_prints_marker(),
                })
                .is_err(),
            "released holder should not be allowed to write"
        );

        let completed = manager
            .shutdown_session(session_id.clone())
            .expect("shutdown managed session");
        let logged = std::fs::read(log_dir.join(format!("{session_id}.log")))
            .expect("read managed session log");
        let _ = std::fs::remove_dir_all(&log_dir);

        assert_eq!(completed.bytes_logged, logged.len() as u64);
        assert!(
            String::from_utf8_lossy(&logged).contains("actor-ready"),
            "managed PTY log did not contain marker: {:?}",
            logged
        );
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_manager_lists_running_sessions() {
        let log_dir = unique_log_dir();
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        let mut request = StartSessionRequest::new(long_running_shell_command());
        request.size = SessionSize {
            rows: 6,
            cols: 40,
            pixel_width: 800,
            pixel_height: 240,
            dpi: 96,
        };
        let session_id = manager.start_session(request).expect("start session");

        let sessions = manager.list_sessions().expect("list sessions");

        assert!(sessions.contains(&session_id));
        manager
            .shutdown_session(session_id)
            .expect("shutdown managed session");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_manager_persists_manifest_when_session_starts() {
        let log_dir = unique_log_dir();
        let config = SessionManagerConfig::new(log_dir.clone());
        let manager = SessionManager::new(config.clone());
        let request = StartSessionRequest::new(long_running_shell_command());

        let session_id = manager.start_session(request).expect("start session");

        let manifest: SessionManifest = serde_json::from_slice(
            &std::fs::read(config.manifest_path()).expect("read session manifest"),
        )
        .expect("decode session manifest");
        assert_eq!(manifest.version, 1);
        let persisted = manifest
            .sessions
            .iter()
            .find(|session| session.id == session_id)
            .expect("persisted session");
        assert_eq!(
            persisted.log_path,
            log_dir.join(format!("{session_id}.log"))
        );
        assert!(!persisted.exited);

        manager
            .shutdown_session(session_id)
            .expect("shutdown managed session");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    fn session_manager_replaces_existing_manifest() {
        let log_dir = unique_log_dir();
        let config = SessionManagerConfig::new(log_dir.clone());
        let manager = SessionManager::new(config.clone());
        let sessions = std::collections::HashMap::new();

        manager
            .persist_manifest(&sessions)
            .expect("write initial manifest");
        manager
            .persist_manifest(&sessions)
            .expect("replace existing manifest");

        let manifest: SessionManifest = serde_json::from_slice(
            &std::fs::read(config.manifest_path()).expect("read session manifest"),
        )
        .expect("decode session manifest");
        assert_eq!(manifest.version, 1);
        assert!(manifest.sessions.is_empty());

        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    fn manifest_backup_replace_restores_existing_manifest_when_install_fails() {
        let log_dir = unique_log_dir();
        std::fs::create_dir_all(&log_dir).expect("create log dir");
        let manifest_path = log_dir.join("sessions.json");
        let temp_path = log_dir.join("sessions.json.tmp");
        std::fs::write(&manifest_path, b"previous manifest").expect("write previous manifest");

        let error = replace_manifest_with_backup(&temp_path, &manifest_path)
            .expect_err("missing temp manifest should fail replacement");

        assert!(
            error.to_string().contains("moving session manifest"),
            "unexpected replacement error: {error:?}"
        );
        assert_eq!(
            std::fs::read(&manifest_path).expect("read restored manifest"),
            b"previous manifest"
        );
        assert!(!manifest_path.with_extension("json.bak").exists());

        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_manager_rolls_back_started_session_when_manifest_persist_fails() {
        let log_dir = unique_log_dir();
        let config = SessionManagerConfig::new(log_dir.clone());
        std::fs::create_dir_all(config.manifest_path()).expect("create manifest path directory");
        let manager = SessionManager::new(config);

        let error = manager
            .start_session(StartSessionRequest::new(long_running_shell_command()))
            .expect_err("start session should fail when manifest cannot be replaced");

        assert!(
            error.to_string().contains("moving session manifest")
                || error
                    .to_string()
                    .contains("removing existing session manifest"),
            "unexpected persist error: {error:?}"
        );
        assert!(
            manager
                .list_sessions()
                .expect("list sessions after rollback")
                .is_empty(),
            "failed manifest persistence should not retain the started session"
        );

        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_manager_keeps_session_when_shutdown_manifest_persist_fails() {
        let log_dir = unique_log_dir();
        let config = SessionManagerConfig::new(log_dir.clone());
        let manager = SessionManager::new(config.clone());
        let session_id = manager
            .start_session(StartSessionRequest::new(long_running_shell_command()))
            .expect("start session");
        std::fs::remove_file(config.manifest_path()).expect("remove manifest file");
        std::fs::create_dir_all(config.manifest_path()).expect("create manifest path directory");

        let error = manager
            .shutdown_session(session_id.clone())
            .expect_err("shutdown should fail when manifest cannot be replaced");

        assert!(
            error.to_string().contains("moving session manifest"),
            "unexpected persist error: {error:?}"
        );
        assert!(
            manager
                .list_sessions()
                .expect("list sessions after failed shutdown")
                .contains(&session_id),
            "failed shutdown persistence should keep the session registered"
        );

        std::fs::remove_dir_all(config.manifest_path()).expect("remove blocking manifest dir");
        manager
            .shutdown_session(session_id)
            .expect("shutdown after manifest path restored");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    fn session_manager_restores_historical_sessions_from_manifest() {
        let log_dir = unique_log_dir();
        std::fs::create_dir_all(&log_dir).expect("create log dir");
        let session_id = SessionId::new("session-7").expect("session id");
        let log_path = log_dir.join("session-7.log");
        std::fs::write(&log_path, b"restored-ready\r\n").expect("write session log");
        let manifest = SessionManifest {
            version: 1,
            sessions: vec![PersistedSession {
                id: session_id.clone(),
                command: "/bin/sh".to_string(),
                args: Vec::new(),
                cwd: None,
                size: SessionSize {
                    rows: 6,
                    cols: 40,
                    pixel_width: 800,
                    pixel_height: 240,
                    dpi: 96,
                },
                log_path,
                exited: false,
            }],
        };
        std::fs::write(
            SessionManagerConfig::new(log_dir.clone()).manifest_path(),
            serde_json::to_vec(&manifest).expect("encode manifest"),
        )
        .expect("write manifest");

        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));

        let sessions = manager.list_sessions().expect("list sessions");
        assert_eq!(sessions.len(), 1);
        assert!(sessions.contains(&session_id));
        let snapshot = manager
            .snapshot_session(session_id.clone())
            .expect("restored snapshot");
        assert!(snapshot.exited);
        assert_eq!(snapshot.bytes_logged, b"restored-ready\r\n".len() as u64);
        assert!(
            snapshot
                .visible_rows
                .iter()
                .any(|row| row.contains("restored-ready")),
            "restored rows did not include replayed log: {:?}",
            snapshot.visible_rows
        );

        let rows = manager
            .styled_rows(StyledRowsRequest {
                session_id: session_id.clone(),
                start: 0,
                end: snapshot.visible_rows.len(),
            })
            .expect("restored styled rows");
        assert_eq!(rows.output_seq, snapshot.output_seq);
        assert_eq!(rows.rows.len(), snapshot.visible_rows.len());
        let restored_events = manager
            .subscribe_session_events(session_id.clone())
            .expect("subscribe to restored session events");
        assert!(matches!(
            restored_events.try_recv(),
            Err(TryRecvError::Disconnected)
        ));
        assert!(
            manager
                .write_input(WriteInputRequest {
                    session_id: session_id.clone(),
                    client_id: ClientId::new("client").expect("client id"),
                    bytes: b"echo nope\n".to_vec(),
                })
                .is_err(),
            "historical sessions should reject input"
        );

        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_manager_restores_historical_shell_as_live_session() {
        let log_dir = unique_log_dir();
        std::fs::create_dir_all(&log_dir).expect("create log dir");
        let session_id = SessionId::new("session-7").expect("session id");
        let log_path = log_dir.join("session-7.log");
        std::fs::write(&log_path, b"history-before-restore\r\n").expect("write session log");
        write_manifest(
            &log_dir,
            PersistedSession {
                id: session_id.clone(),
                command: long_running_shell_command().to_string(),
                args: Vec::new(),
                cwd: None,
                size: SessionSize {
                    rows: 6,
                    cols: 40,
                    pixel_width: 800,
                    pixel_height: 240,
                    dpi: 96,
                },
                log_path: log_path.clone(),
                exited: false,
            },
        );
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));

        let snapshot = manager
            .restore_session(RestoreSessionRequest {
                session_id: session_id.clone(),
                size: SessionSize {
                    rows: 6,
                    cols: 40,
                    pixel_width: 800,
                    pixel_height: 240,
                    dpi: 96,
                },
            })
            .expect("restore shell session");

        assert!(!snapshot.exited);
        assert!(
            snapshot
                .visible_rows
                .iter()
                .any(|row| row.contains("history-before-restore")),
            "restored live snapshot lost historical rows: {:?}",
            snapshot.visible_rows
        );
        let client_id = ClientId::new("restore-client").expect("client id");
        manager
            .attach_session(AttachSessionRequest {
                session_id: session_id.clone(),
                client_id: client_id.clone(),
                mode: triage_core::session::AttachMode::InteractiveController,
            })
            .expect("attach restored session");
        manager
            .write_input(WriteInputRequest {
                session_id: session_id.clone(),
                client_id,
                bytes: input_that_prints_marker(),
            })
            .expect("write restored session input");
        wait_for_manager_marker(&manager, session_id.clone(), "actor-ready");

        let logged = std::fs::read_to_string(&log_path).expect("read restored log");
        assert!(logged.contains("history-before-restore"));
        assert!(logged.contains("actor-ready"));
        manager
            .shutdown_session(session_id)
            .expect("shutdown restored session");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn restored_live_session_reflows_history_on_resize() {
        let log_dir = unique_log_dir();
        std::fs::create_dir_all(&log_dir).expect("create log dir");
        let session_id = SessionId::new("session-7").expect("session id");
        let log_path = log_dir.join("session-7.log");
        let long_line = "0123456789abcdefghijklmnopqrstuvwxyz";
        std::fs::write(&log_path, long_line).expect("write session log");
        write_manifest(
            &log_dir,
            PersistedSession {
                id: session_id.clone(),
                command: long_running_shell_command().to_string(),
                args: Vec::new(),
                cwd: None,
                size: SessionSize {
                    rows: 6,
                    cols: 12,
                    pixel_width: 120,
                    pixel_height: 120,
                    dpi: 96,
                },
                log_path: log_path.clone(),
                exited: false,
            },
        );
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));

        let restored = manager
            .restore_session(RestoreSessionRequest {
                session_id: session_id.clone(),
                size: SessionSize {
                    rows: 6,
                    cols: 12,
                    pixel_width: 120,
                    pixel_height: 120,
                    dpi: 96,
                },
            })
            .expect("restore shell session");
        assert!(
            !restored.visible_rows.iter().any(|row| row == long_line),
            "narrow restored session should initially wrap history: {:?}",
            restored.visible_rows
        );

        let resized = manager
            .resize_session(ResizeSessionRequest {
                session_id: session_id.clone(),
                size: SessionSize {
                    rows: 6,
                    cols: 80,
                    pixel_width: 800,
                    pixel_height: 120,
                    dpi: 96,
                },
            })
            .expect("resize restored session");

        assert!(
            resized
                .visible_rows
                .iter()
                .any(|row| row.starts_with(long_line)),
            "resized restored session should reflow history: {:?}",
            resized.visible_rows
        );
        manager
            .shutdown_session(session_id)
            .expect("shutdown restored session");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg(not(windows))]
    fn session_manager_restores_shell_in_last_known_cwd() {
        let log_dir = unique_log_dir();
        let cwd = log_dir.join("last-cwd");
        std::fs::create_dir_all(&cwd).expect("create restored cwd");
        let session_id = SessionId::new("session-7").expect("session id");
        let log_path = log_dir.join("session-7.log");
        std::fs::write(
            &log_path,
            format!("\x1b]7;file://localhost{}\x1b\\", cwd.display()),
        )
        .expect("write OSC 7 session log");
        write_manifest(
            &log_dir,
            PersistedSession {
                id: session_id.clone(),
                command: long_running_shell_command().to_string(),
                args: Vec::new(),
                cwd: Some(log_dir.clone()),
                size: SessionSize::default(),
                log_path,
                exited: false,
            },
        );
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        let client_id = ClientId::new("restore-client").expect("client id");

        let snapshot = manager
            .restore_session(RestoreSessionRequest {
                session_id: session_id.clone(),
                size: SessionSize::default(),
            })
            .expect("restore shell session");

        assert_eq!(snapshot.current_working_directory, Some(cwd.clone()));
        manager
            .attach_session(AttachSessionRequest {
                session_id: session_id.clone(),
                client_id: client_id.clone(),
                mode: triage_core::session::AttachMode::InteractiveController,
            })
            .expect("attach restored session");
        manager
            .write_input(WriteInputRequest {
                session_id: session_id.clone(),
                client_id,
                bytes: b"pwd\n".to_vec(),
            })
            .expect("write pwd");
        wait_for_manager_marker(&manager, session_id.clone(), &cwd.display().to_string());

        manager
            .shutdown_session(session_id)
            .expect("shutdown restored session");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg(not(windows))]
    fn session_manager_falls_back_when_last_known_cwd_is_unusable() {
        let log_dir = unique_log_dir();
        let launch_cwd = log_dir.join("launch-cwd");
        let stale_cwd = log_dir.join("deleted-cwd");
        std::fs::create_dir_all(&launch_cwd).expect("create launch cwd");
        let session_id = SessionId::new("session-7").expect("session id");
        let log_path = log_dir.join("session-7.log");
        std::fs::write(
            &log_path,
            format!("\x1b]7;file://localhost{}\x1b\\", stale_cwd.display()),
        )
        .expect("write stale OSC 7 session log");
        write_manifest(
            &log_dir,
            PersistedSession {
                id: session_id.clone(),
                command: long_running_shell_command().to_string(),
                args: Vec::new(),
                cwd: Some(launch_cwd.clone()),
                size: SessionSize::default(),
                log_path,
                exited: false,
            },
        );
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        let client_id = ClientId::new("restore-client").expect("client id");

        let snapshot = manager
            .restore_session(RestoreSessionRequest {
                session_id: session_id.clone(),
                size: SessionSize::default(),
            })
            .expect("restore shell session");

        assert_eq!(snapshot.current_working_directory, Some(launch_cwd.clone()));
        manager
            .attach_session(AttachSessionRequest {
                session_id: session_id.clone(),
                client_id: client_id.clone(),
                mode: triage_core::session::AttachMode::InteractiveController,
            })
            .expect("attach restored session");
        manager
            .write_input(WriteInputRequest {
                session_id: session_id.clone(),
                client_id,
                bytes: b"pwd\n".to_vec(),
            })
            .expect("write pwd");
        wait_for_manager_marker(
            &manager,
            session_id.clone(),
            &launch_cwd.display().to_string(),
        );

        manager
            .shutdown_session(session_id)
            .expect("shutdown restored session");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    fn session_manager_rejects_restore_already_in_progress() {
        let log_dir = unique_log_dir();
        std::fs::create_dir_all(&log_dir).expect("create log dir");
        let session_id = SessionId::new("session-7").expect("session id");
        let log_path = log_dir.join("session-7.log");
        std::fs::write(&log_path, b"history-before-restore\r\n").expect("write session log");
        write_manifest(
            &log_dir,
            PersistedSession {
                id: session_id.clone(),
                command: long_running_shell_command().to_string(),
                args: Vec::new(),
                cwd: None,
                size: SessionSize::default(),
                log_path,
                exited: false,
            },
        );
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        {
            let mut sessions = manager.sessions().expect("lock sessions");
            let existing = sessions.remove(&session_id).expect("historical session");
            let ManagedSession::Historical { session, lease } = existing else {
                panic!("expected historical session");
            };
            sessions.insert(
                session_id.clone(),
                ManagedSession::Restoring { session, lease },
            );
        }

        let error = manager
            .restore_session(RestoreSessionRequest {
                session_id,
                size: SessionSize::default(),
            })
            .expect_err("restore in progress should fail");

        assert!(
            error.to_string().contains("already live or restoring"),
            "unexpected restore error: {error:?}"
        );
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    fn session_manager_rejects_non_shell_historical_restore() {
        let log_dir = unique_log_dir();
        std::fs::create_dir_all(&log_dir).expect("create log dir");
        let session_id = SessionId::new("session-7").expect("session id");
        let log_path = log_dir.join("session-7.log");
        std::fs::write(&log_path, b"not-a-shell\r\n").expect("write session log");
        write_manifest(
            &log_dir,
            PersistedSession {
                id: session_id.clone(),
                command: "python".to_string(),
                args: Vec::new(),
                cwd: None,
                size: SessionSize::default(),
                log_path,
                exited: false,
            },
        );
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));

        let error = manager
            .restore_session(RestoreSessionRequest {
                session_id: session_id.clone(),
                size: SessionSize::default(),
            })
            .expect_err("non-shell restore should fail");

        assert!(
            error
                .to_string()
                .contains("not launched as a restorable shell"),
            "unexpected restore error: {error:?}"
        );
        assert!(
            manager
                .snapshot_session(session_id)
                .expect("historical session remains available")
                .exited
        );
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    fn next_session_sequence_advances_past_restored_ids() {
        let sessions = [
            SessionId::new("session-7").expect("session id"),
            SessionId::new("session-41").expect("session id"),
            SessionId::new("custom").expect("session id"),
        ];

        assert_eq!(next_session_sequence(sessions.iter()), 42);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn session_manager_fans_out_session_events_to_subscribers() {
        let log_dir = unique_log_dir();
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        let mut request = StartSessionRequest::new(long_running_shell_command());
        request.size = SessionSize {
            rows: 6,
            cols: 40,
            pixel_width: 800,
            pixel_height: 240,
            dpi: 96,
        };
        let session_id = manager.start_session(request).expect("start session");
        let local_tui = ClientId::new("local-tui").expect("local tui id");
        let first_subscriber = manager
            .subscribe_session_events(session_id.clone())
            .expect("subscribe first client");
        let second_subscriber = manager
            .subscribe_session_events(session_id.clone())
            .expect("subscribe second client");

        manager
            .acquire_input_lease(InputLeaseRequest {
                session_id: session_id.clone(),
                client_id: local_tui.clone(),
                kind: triage_core::session::InputControllerKind::Interactive,
            })
            .expect("acquire input lease");
        assert!(matches!(
            wait_for_event(&first_subscriber, "first lease event", |event| {
                matches!(
                    event,
                    SessionEvent::LeaseChanged { session_id: event_session_id, change }
                        if event_session_id == &session_id
                            && change.action == triage_core::session::LeaseChangeAction::Acquired
                )
            }),
            SessionEvent::LeaseChanged { .. }
        ));
        assert!(matches!(
            wait_for_event(&second_subscriber, "second lease event", |event| {
                matches!(
                    event,
                    SessionEvent::LeaseChanged { session_id: event_session_id, change }
                        if event_session_id == &session_id
                            && change.action == triage_core::session::LeaseChangeAction::Acquired
                )
            }),
            SessionEvent::LeaseChanged { .. }
        ));

        manager
            .write_input(WriteInputRequest {
                session_id: session_id.clone(),
                client_id: local_tui,
                bytes: input_that_prints_marker(),
            })
            .expect("write PTY input");
        wait_for_output_event(&first_subscriber, &session_id, "actor-ready");
        wait_for_output_event(&second_subscriber, &session_id, "actor-ready");

        manager
            .resize_session(ResizeSessionRequest {
                session_id: session_id.clone(),
                size: SessionSize {
                    rows: 8,
                    cols: 48,
                    pixel_width: 960,
                    pixel_height: 320,
                    dpi: 96,
                },
            })
            .expect("resize managed session");
        wait_for_snapshot_event(&first_subscriber, &session_id, 8);
        wait_for_snapshot_event(&second_subscriber, &session_id, 8);

        manager
            .shutdown_session(session_id.clone())
            .expect("shutdown managed session");
        wait_for_exit_event(&first_subscriber, &session_id);
        wait_for_exit_event(&second_subscriber, &session_id);
        assert_no_exit_event(&first_subscriber, &session_id);
        assert_no_exit_event(&second_subscriber, &session_id);
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY EOF handling needs a dedicated Windows lifecycle test"
    )]
    fn full_event_buffer_drops_output_without_disconnect() {
        let log_dir = unique_log_dir();
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        let request = StartSessionRequest::new(long_running_shell_command());
        let session_id = manager.start_session(request).expect("start session");
        let subscriber = manager
            .subscribe_session_events(session_id.clone())
            .expect("subscribe client");

        for index in 0..=EVENT_SUBSCRIBER_BUFFER {
            let sessions = manager.sessions().expect("lock sessions");
            let session = sessions.get(&session_id).expect("managed session");
            let ManagedSession::Live { actor, .. } = session else {
                panic!("expected live session");
            };
            actor
                .broadcast_event(SessionEvent::Output {
                    session_id: session_id.clone(),
                    output_seq: index as u64,
                    bytes: format!("burst-{index}").into_bytes(),
                })
                .expect("broadcast output");
        }

        for _ in 0..EVENT_SUBSCRIBER_BUFFER {
            let _ = subscriber
                .recv_timeout(Duration::from_secs(1))
                .expect("drain queued output event");
        }

        {
            let sessions = manager.sessions().expect("lock sessions");
            let session = sessions.get(&session_id).expect("managed session");
            let ManagedSession::Live { actor, .. } = session else {
                panic!("expected live session");
            };
            actor
                .broadcast_event(SessionEvent::Output {
                    session_id: session_id.clone(),
                    output_seq: 999,
                    bytes: b"still-subscribed".to_vec(),
                })
                .expect("broadcast sentinel output");
        }

        wait_for_output_event(&subscriber, &session_id, "still-subscribed");
        manager
            .shutdown_session(session_id)
            .expect("shutdown managed session");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg(not(windows))]
    fn dropped_event_subscribers_are_pruned_on_next_flush() {
        let log_dir = unique_log_dir();
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        let request = StartSessionRequest::new(long_running_shell_command());
        let session_id = manager.start_session(request).expect("start session");
        let subscriber = manager
            .subscribe_session_events(session_id.clone())
            .expect("subscribe client");
        drop(subscriber);

        {
            let sessions = manager.sessions().expect("lock sessions");
            let session = sessions.get(&session_id).expect("managed session");
            let ManagedSession::Live { actor, .. } = session else {
                panic!("expected live session");
            };
            actor
                .broadcast_event(SessionEvent::Output {
                    session_id: session_id.clone(),
                    output_seq: 1,
                    bytes: b"after-disconnect".to_vec(),
                })
                .expect("broadcast output after subscriber disconnect");
            assert_eq!(actor.subscriber_count().expect("subscriber count"), 0);
        }

        manager
            .shutdown_session(session_id)
            .expect("shutdown managed session");
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    #[cfg(not(windows))]
    fn full_event_buffer_replays_exit_after_subscriber_drains() {
        let log_dir = unique_log_dir();
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir.clone()));
        let request = StartSessionRequest::new(long_running_shell_command());
        let session_id = manager.start_session(request).expect("start session");
        let subscriber = manager
            .subscribe_session_events(session_id.clone())
            .expect("subscribe client");

        for index in 0..=EVENT_SUBSCRIBER_BUFFER {
            let sessions = manager.sessions().expect("lock sessions");
            let session = sessions.get(&session_id).expect("managed session");
            let ManagedSession::Live { actor, .. } = session else {
                panic!("expected live session");
            };
            actor
                .broadcast_event(SessionEvent::Output {
                    session_id: session_id.clone(),
                    output_seq: index as u64,
                    bytes: format!("burst-{index}").into_bytes(),
                })
                .expect("broadcast output");
        }

        {
            let sessions = manager.sessions().expect("lock sessions");
            let session = sessions.get(&session_id).expect("managed session");
            let ManagedSession::Live { actor, .. } = session else {
                panic!("expected live session");
            };
            actor.write_input(b"exit\n".to_vec()).expect("exit shell");
        }

        wait_for_exit_event(&subscriber, &session_id);
        let _ = std::fs::remove_dir_all(&log_dir);
    }

    #[test]
    fn replay_with_delayed_writer_suppresses_historical_terminal_replies() {
        let log_path = unique_log_path();
        let log = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&log_path)
            .expect("open test log");
        let captured = Arc::new(Mutex::new(Vec::new()));
        let (writer, replay_gate) = replay_gated_pty_writer();
        let mut output = OutputState {
            log,
            terminal: terminal_with_writer(&SessionSize::default(), writer.clone()),
            cwd_sequence_buffer: Vec::new(),
            bytes_logged: 0,
            output_seq: 0,
            log_cache: Some(Vec::new()),
        };

        output
            .replay(b"\x1b[c")
            .expect("replay historical device attributes query");
        assert!(
            captured.lock().expect("captured writer lock").is_empty(),
            "historical replay should not write terminal replies to the live PTY"
        );

        let replay_writes = replay_gate.dropped_write_count();
        let replay_flushes = replay_gate.dropped_flush_count();
        output.terminal.advance_bytes(b"\x1b[c");
        replay_gate
            .wait_for_dropped_activity_quiet_after(replay_writes, replay_flushes)
            .expect("drain replay writer");
        replay_gate
            .enable(Box::new(RecordingWriter {
                bytes: captured.clone(),
            }))
            .expect("install live writer");
        assert!(
            captured.lock().expect("captured writer lock").is_empty(),
            "queued historical terminal replies should drain before the live writer is installed"
        );

        output
            .ingest(b"\x1b[c")
            .expect("ingest live device attributes query");
        wait_for_recorded_bytes(&captured);
        assert!(
            !captured.lock().expect("captured writer lock").is_empty(),
            "live terminal queries should still receive terminal replies after restore"
        );
        let _ = std::fs::remove_file(&log_path);
    }

    fn unique_log_path() -> PathBuf {
        let unique = format!(
            "triage-pty-session-{}-{:?}.log",
            std::process::id(),
            std::thread::current().id()
        );
        std::env::temp_dir().join(unique)
    }

    fn test_output_state(log_path: &PathBuf, size: SessionSize) -> OutputState {
        test_output_state_with_writer(log_path, size, Box::new(std::io::sink()))
    }

    fn test_output_state_with_writer(
        log_path: &PathBuf,
        size: SessionSize,
        writer: Box<dyn Write + Send>,
    ) -> OutputState {
        let log = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(log_path)
            .expect("open test log");
        let writer = shared_pty_writer(writer);
        OutputState {
            log,
            terminal: terminal_with_writer(&size, writer),
            cwd_sequence_buffer: Vec::new(),
            bytes_logged: 0,
            output_seq: 0,
            log_cache: Some(Vec::new()),
        }
    }

    fn unique_log_dir() -> PathBuf {
        let unique = format!(
            "triage-session-manager-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        );
        std::env::temp_dir().join(unique)
    }

    #[test]
    fn default_log_dir_uses_xdg_state_home_when_set() {
        let log_dir = default_log_dir_from_env(
            Some(OsString::from("/tmp/triage-state")),
            Some(OsString::from("/tmp/home")),
            None,
        );

        assert_eq!(
            log_dir,
            PathBuf::from("/tmp/triage-state").join("triage/sessions")
        );
    }

    #[test]
    fn default_log_dir_falls_back_to_home_local_state() {
        let log_dir = default_log_dir_from_env(None, Some(OsString::from("/tmp/home")), None);

        assert_eq!(
            log_dir,
            PathBuf::from("/tmp/home").join(".local/state/triage/sessions")
        );
    }

    #[test]
    fn normalize_pairing_code_maps_ambiguous_chars() {
        assert_eq!(normalize_pairing_code("abc def"), "ABCDEF");
        assert_eq!(normalize_pairing_code("oLi"), "011");
        assert_eq!(normalize_pairing_code("  9kxq4m7p  "), "9KXQ4M7P");
        assert_eq!(normalize_pairing_code("Oil-LIO"), "011-110");
    }

    fn git_test_command(cwd: &PathBuf, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(cwd)
            .args(args)
            .status()
            .expect("run git test command");
        assert!(status.success(), "git {args:?} failed");
    }

    fn write_manifest(log_dir: &PathBuf, persisted: PersistedSession) {
        std::fs::create_dir_all(log_dir).expect("create log dir");
        let manifest = SessionManifest {
            version: 1,
            sessions: vec![persisted],
        };
        std::fs::write(
            SessionManagerConfig::new(log_dir.clone()).manifest_path(),
            serde_json::to_vec(&manifest).expect("encode manifest"),
        )
        .expect("write manifest");
    }

    struct RecordingWriter {
        bytes: Arc<Mutex<Vec<u8>>>,
    }

    impl Write for RecordingWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.bytes
                .lock()
                .map_err(|_| std::io::Error::other("recording writer lock poisoned"))?
                .extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn wait_for_recorded_bytes(bytes: &Arc<Mutex<Vec<u8>>>) {
        let deadline = Instant::now() + Duration::from_secs(1);

        loop {
            if !bytes.lock().expect("recorded bytes lock").is_empty() {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for recorded terminal reply"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[cfg(windows)]
    fn long_running_shell_command() -> &'static str {
        "cmd.exe"
    }

    #[cfg(not(windows))]
    fn long_running_shell_command() -> &'static str {
        "/bin/sh"
    }

    #[cfg(windows)]
    fn command_that_prints_marker(log_path: PathBuf) -> SessionConfig {
        let mut config = SessionConfig::new("cmd.exe", log_path);
        config.args = vec!["/C".to_string(), "echo triage-ready".to_string()];
        config
    }

    #[cfg(not(windows))]
    fn command_that_prints_marker(log_path: PathBuf) -> SessionConfig {
        let mut config = SessionConfig::new("/bin/sh", log_path);
        config.args = vec!["-c".to_string(), "printf 'triage-ready\\r\\n'".to_string()];
        config
    }

    #[cfg(windows)]
    fn long_running_shell(log_path: PathBuf) -> SessionConfig {
        SessionConfig::new("cmd.exe", log_path)
    }

    #[cfg(not(windows))]
    fn long_running_shell(log_path: PathBuf) -> SessionConfig {
        SessionConfig::new("/bin/sh", log_path)
    }

    #[cfg(windows)]
    fn input_that_prints_marker() -> Vec<u8> {
        b"echo actor-ready\r\n".to_vec()
    }

    #[cfg(not(windows))]
    fn input_that_prints_marker() -> Vec<u8> {
        b"printf 'actor-ready\\r\\n'\n".to_vec()
    }

    fn wait_for_visible_marker(actor: &SessionActor, marker: &str) -> SessionSnapshot {
        let deadline = Instant::now() + Duration::from_secs(5);

        loop {
            let snapshot = actor.snapshot().expect("snapshot session actor");
            if snapshot.visible_rows.iter().any(|row| row.contains(marker)) {
                return snapshot;
            }

            assert!(
                Instant::now() < deadline,
                "timed out waiting for {marker}; latest snapshot: {:?}",
                snapshot
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_for_exited_snapshot(actor: &SessionActor) -> SessionSnapshot {
        let deadline = Instant::now() + Duration::from_secs(5);

        loop {
            let snapshot = actor.snapshot().expect("snapshot session actor");
            if snapshot.exited {
                return snapshot;
            }

            assert!(
                Instant::now() < deadline,
                "timed out waiting for session exit; latest snapshot: {:?}",
                snapshot
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_for_manager_marker(
        manager: &SessionManager,
        session_id: SessionId,
        marker: &str,
    ) -> SessionSnapshot {
        let deadline = Instant::now() + Duration::from_secs(5);

        loop {
            let snapshot = manager
                .snapshot_session(session_id.clone())
                .expect("snapshot managed session");
            if snapshot.visible_rows.iter().any(|row| row.contains(marker))
                || snapshot.visible_rows.join("").contains(marker)
            {
                return snapshot;
            }

            assert!(
                Instant::now() < deadline,
                "timed out waiting for {marker}; latest snapshot: {:?}",
                snapshot
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_for_output_event(
        receiver: &SessionEventReceiver,
        session_id: &SessionId,
        marker: &str,
    ) {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut output = Vec::new();

        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(
                !remaining.is_zero(),
                "timed out waiting for output marker {marker}; latest output: {:?}",
                String::from_utf8_lossy(&output)
            );
            let event = receiver
                .recv_timeout(remaining.min(Duration::from_millis(100)))
                .unwrap_or_else(|error| {
                    panic!("event stream ended while waiting for output marker {marker}: {error}")
                })
                .event;
            if let SessionEvent::Output {
                session_id: event_session_id,
                bytes,
                ..
            } = event
                && &event_session_id == session_id
            {
                output.extend_from_slice(&bytes);
                if output.len() > 8192 {
                    output.drain(..output.len() - 8192);
                }
                if String::from_utf8_lossy(&output).contains(marker) {
                    return;
                }
            }
        }
    }

    fn wait_for_snapshot_event(
        receiver: &SessionEventReceiver,
        session_id: &SessionId,
        rows: usize,
    ) {
        assert!(matches!(
            wait_for_event(receiver, "resize snapshot event", |event| {
                matches!(
                    event,
                    SessionEvent::Snapshot { session_id: event_session_id, snapshot }
                        if event_session_id == session_id && snapshot.size.rows == rows
                )
            }),
            SessionEvent::Snapshot { .. }
        ));
    }

    fn wait_for_exit_event(receiver: &SessionEventReceiver, session_id: &SessionId) {
        assert!(matches!(
            wait_for_event(receiver, "exit event", |event| {
                matches!(
                    event,
                    SessionEvent::Exited { session_id: event_session_id, completed }
                        if event_session_id == session_id && completed.output_seq > 0
                )
            }),
            SessionEvent::Exited { .. }
        ));
    }

    fn assert_no_exit_event(receiver: &SessionEventReceiver, session_id: &SessionId) {
        let deadline = Instant::now() + Duration::from_millis(100);

        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return;
            }

            match receiver.recv_timeout(remaining.min(Duration::from_millis(20))) {
                Ok(envelope)
                    if matches!(
                        envelope.event,
                        SessionEvent::Exited {
                            session_id: ref event_session_id,
                            ..
                        } if event_session_id == session_id
                    ) =>
                {
                    panic!("received duplicate exit event for session {session_id}");
                }
                Ok(_) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Timeout)
                | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
            }
        }
    }

    fn wait_for_event(
        receiver: &SessionEventReceiver,
        label: &str,
        matches_event: impl Fn(&SessionEvent) -> bool,
    ) -> SessionEvent {
        let deadline = Instant::now() + Duration::from_secs(5);

        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            assert!(!remaining.is_zero(), "timed out waiting for {label}");
            match receiver.recv_timeout(remaining.min(Duration::from_millis(100))) {
                Ok(envelope) if matches_event(&envelope.event) => return envelope.event,
                Ok(_) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    panic!("event stream closed while waiting for {label}");
                }
            }
        }
    }
}
