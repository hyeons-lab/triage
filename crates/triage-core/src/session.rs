use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SessionId(String);

impl SessionId {
    pub fn new(id: impl Into<String>) -> Result<Self> {
        let id = id.into();
        ensure!(!id.trim().is_empty(), "session id must be set");
        Ok(Self(id))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ClientId(String);

impl ClientId {
    pub fn new(id: impl Into<String>) -> Result<Self> {
        let id = id.into();
        ensure!(!id.trim().is_empty(), "client id must be set");
        Ok(Self(id))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ClientId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSize {
    pub rows: usize,
    pub cols: usize,
    pub pixel_width: usize,
    pub pixel_height: usize,
    pub dpi: usize,
}

impl Default for SessionSize {
    fn default() -> Self {
        Self {
            rows: 24,
            cols: 80,
            pixel_width: 800,
            pixel_height: 480,
            dpi: 96,
        }
    }
}

impl SessionSize {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.rows > 0, "session PTY rows must be greater than zero");
        ensure!(self.cols > 0, "session PTY cols must be greater than zero");
        ensure!(
            self.rows <= u16::MAX as usize,
            "session PTY rows must fit in u16"
        );
        ensure!(
            self.cols <= u16::MAX as usize,
            "session PTY cols must fit in u16"
        );
        ensure!(
            self.pixel_width <= u16::MAX as usize,
            "session PTY pixel width must fit in u16"
        );
        ensure!(
            self.pixel_height <= u16::MAX as usize,
            "session PTY pixel height must fit in u16"
        );
        ensure!(
            self.dpi <= u32::MAX as usize,
            "session terminal DPI must fit in u32"
        );
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSnapshot {
    pub output_seq: u64,
    pub bytes_logged: u64,
    pub size: SessionSize,
    pub visible_rows: Vec<String>,
    pub styled_rows_start: usize,
    pub styled_rows: Vec<StyledRow>,
    pub cursor: TerminalCursor,
    pub current_working_directory: Option<PathBuf>,
    pub context: Option<SessionContext>,
    pub bracketed_paste_enabled: bool,
    pub exited: bool,
    /// Raw (untranslated) PTY output tail for client-side re-emulation — the
    /// single source of truth for history, byte-identical to the live Output
    /// stream. Empty when history is not carried (e.g. resize broadcasts) or
    /// from old hosts.
    #[serde(default)]
    pub raw_output: Vec<u8>,
    /// Byte offset of the first byte of [`Self::raw_output`] within the
    /// session's full output log (`bytes_logged` is the end offset).
    #[serde(default)]
    pub raw_output_start: u64,
    /// Local-LLM one-line description of what the session is doing, if one has
    /// been generated. `None` when summarization is disabled or not yet produced.
    #[serde(default)]
    pub snippet: Option<String>,
    /// Local-LLM longer-form summary (a few sentences) for the side-rail hover
    /// popover and future search. `None` until the detail pass produces it.
    #[serde(default)]
    pub snippet_detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionContext {
    pub repository_root: Option<PathBuf>,
    pub worktree_root: Option<PathBuf>,
    pub branch: Option<String>,
}

/// Separator between the parts of [`SessionContext::localization_label`].
const LABEL_SEPARATOR: &str = "  ·  ";

impl SessionContext {
    /// The repository root's directory name (its last path component), if known.
    pub fn repository_name(&self) -> Option<String> {
        self.repository_root.as_deref().and_then(path_leaf_name)
    }

    /// The worktree root, but only when it is a *distinct* linked worktree —
    /// set and not equal to the repository root. Returns `None` when the
    /// worktree is unset or merely echoes the repository root (the common
    /// "working in the main checkout" case), so callers never render the same
    /// directory as both repo and worktree.
    pub fn distinct_worktree_root(&self) -> Option<&Path> {
        let worktree = self.worktree_root.as_deref()?;
        if Some(worktree) == self.repository_root.as_deref() {
            None
        } else {
            Some(worktree)
        }
    }

    /// The distinct worktree's directory name, if any. See
    /// [`Self::distinct_worktree_root`].
    pub fn worktree_name(&self) -> Option<String> {
        self.distinct_worktree_root().and_then(path_leaf_name)
    }

    /// The branch name, treating an empty string as absent.
    pub fn branch_name(&self) -> Option<&str> {
        self.branch.as_deref().filter(|branch| !branch.is_empty())
    }

    /// A compact one-line `repo · branch · worktree` localization label for the
    /// session. Omits absent parts, and hides the worktree leaf when it merely
    /// echoes the repository root (handled by [`Self::distinct_worktree_root`])
    /// or the branch name, so the label never repeats itself. Returns `None`
    /// when no part is known.
    ///
    /// This is the single source of truth for how a session's git location is
    /// rendered as one line — the daemon's detail-summary header and any other
    /// consumer share it so the format can't drift.
    pub fn localization_label(&self) -> Option<String> {
        let mut parts: Vec<String> = Vec::new();
        if let Some(repo) = self.repository_name() {
            parts.push(repo);
        }
        let branch = self.branch_name();
        if let Some(branch) = branch {
            parts.push(branch.to_string());
        }
        if let Some(worktree) = self.worktree_name()
            && Some(worktree.as_str()) != branch
        {
            parts.push(worktree);
        }
        (!parts.is_empty()).then(|| parts.join(LABEL_SEPARATOR))
    }
}

/// Last path component of `path` as a display string, or `None` for a rootless
/// path (e.g. `/`). Lossy on non-UTF-8 components.
pub fn path_leaf_name(path: &Path) -> Option<String> {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalCursor {
    pub row: usize,
    pub col: usize,
    pub visible: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StyledRow {
    pub spans: Vec<StyledSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StyledSpan {
    pub text: String,
    pub style: TerminalStyle,
}

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalStyle {
    pub foreground: Option<TerminalColor>,
    pub background: Option<TerminalColor>,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub reverse: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompletedSession {
    pub output_seq: u64,
    pub bytes_logged: u64,
    pub visible_rows: Vec<String>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AttachMode {
    #[default]
    Observer,
    InteractiveController,
    AgentController,
}

impl AttachMode {
    pub fn grants_input(self) -> bool {
        !matches!(self, Self::Observer)
    }

    pub fn controller_kind(self) -> Option<InputControllerKind> {
        match self {
            AttachMode::Observer => None,
            AttachMode::InteractiveController => Some(InputControllerKind::Interactive),
            AttachMode::AgentController => Some(InputControllerKind::Agent),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum InputControllerKind {
    Interactive,
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputLeaseHolder {
    pub client_id: ClientId,
    pub kind: InputControllerKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputLeaseState {
    pub holder: Option<InputLeaseHolder>,
    pub generation: u64,
}

impl InputLeaseState {
    pub fn observer_only() -> Self {
        Self {
            holder: None,
            generation: 0,
        }
    }

    pub fn acquire(&mut self, client_id: ClientId, kind: InputControllerKind) -> LeaseChange {
        let previous = self.holder.replace(InputLeaseHolder { client_id, kind });
        self.generation += 1;
        let action = if previous.is_some() {
            LeaseChangeAction::TakenOver
        } else {
            LeaseChangeAction::Acquired
        };
        LeaseChange {
            generation: self.generation,
            previous,
            current: self.holder.clone(),
            action,
        }
    }

    pub fn release(&mut self, client_id: &ClientId) -> Option<LeaseChange> {
        let current = self.holder.as_ref()?;
        if &current.client_id != client_id {
            return None;
        }

        let previous = self.holder.take();
        self.generation += 1;
        Some(LeaseChange {
            generation: self.generation,
            previous,
            current: None,
            action: LeaseChangeAction::Released,
        })
    }
}

impl Default for InputLeaseState {
    fn default() -> Self {
        Self::observer_only()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LeaseChangeAction {
    Acquired,
    Released,
    TakenOver,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaseChange {
    pub generation: u64,
    pub previous: Option<InputLeaseHolder>,
    pub current: Option<InputLeaseHolder>,
    pub action: LeaseChangeAction,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartSessionRequest {
    pub command: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub size: SessionSize,
}

impl StartSessionRequest {
    pub fn new(command: impl Into<String>) -> Self {
        Self {
            command: command.into(),
            args: Vec::new(),
            cwd: None,
            size: SessionSize::default(),
        }
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.command.trim().is_empty(),
            "session command must be set"
        );
        self.size.validate()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachSessionRequest {
    pub session_id: SessionId,
    pub client_id: ClientId,
    pub mode: AttachMode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachSessionResponse {
    pub snapshot: SessionSnapshot,
    pub lease: InputLeaseState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WriteInputRequest {
    pub session_id: SessionId,
    pub client_id: ClientId,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResizeSessionRequest {
    pub session_id: SessionId,
    pub size: SessionSize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestoreSessionRequest {
    pub session_id: SessionId,
    pub size: SessionSize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StyledRowsRequest {
    pub session_id: SessionId,
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StyledRowsResponse {
    pub output_seq: u64,
    pub start: usize,
    pub rows: Vec<StyledRow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputLeaseRequest {
    pub session_id: SessionId,
    pub client_id: ClientId,
    pub kind: InputControllerKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SessionEvent {
    ResyncRequired {
        session_id: SessionId,
        latest_event_seq: u64,
        snapshot: SessionSnapshot,
    },
    Output {
        session_id: SessionId,
        output_seq: u64,
        bytes: Vec<u8>,
    },
    Snapshot {
        session_id: SessionId,
        snapshot: SessionSnapshot,
    },
    LeaseChanged {
        session_id: SessionId,
        change: LeaseChange,
    },
    Exited {
        session_id: SessionId,
        completed: CompletedSession,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionEventEnvelope {
    pub event_seq: u64,
    pub event: SessionEvent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubscribeSessionEventsRequest {
    pub session_id: SessionId,
    pub after_event_seq: Option<u64>,
}

pub type SessionEventReceiver = Receiver<SessionEventEnvelope>;

pub trait SessionApi {
    fn list_sessions(&self) -> Result<Vec<SessionId>>;
    fn start_session(&self, request: StartSessionRequest) -> Result<SessionId>;
    fn attach_session(&self, request: AttachSessionRequest) -> Result<AttachSessionResponse>;
    fn subscribe_session_events(&self, session_id: SessionId) -> Result<SessionEventReceiver>;
    fn subscribe_session_events_from(
        &self,
        request: SubscribeSessionEventsRequest,
    ) -> Result<SessionEventReceiver> {
        if request.after_event_seq.is_some() {
            anyhow::bail!("event replay is not supported by this session API");
        }
        self.subscribe_session_events(request.session_id)
    }
    fn acquire_input_lease(&self, request: InputLeaseRequest) -> Result<LeaseChange>;
    fn release_input_lease(
        &self,
        session_id: SessionId,
        client_id: ClientId,
    ) -> Result<LeaseChange>;
    fn write_input(&self, request: WriteInputRequest) -> Result<()>;
    fn resize_session(&self, request: ResizeSessionRequest) -> Result<SessionSnapshot>;
    fn restore_session(&self, _request: RestoreSessionRequest) -> Result<SessionSnapshot> {
        anyhow::bail!("session restore is not supported by this session API")
    }
    fn snapshot_session(&self, session_id: SessionId) -> Result<SessionSnapshot>;
    fn styled_rows(&self, request: StyledRowsRequest) -> Result<StyledRowsResponse>;
    fn shutdown_session(&self, session_id: SessionId) -> Result<CompletedSession>;
    /// Current snippet for every session (id, one-liner, detail). Sessions
    /// without a snippet yet carry `None`. Default: no snippets (summarization
    /// unsupported).
    #[allow(clippy::type_complexity)]
    fn list_session_snippets(&self) -> Result<Vec<(SessionId, Option<String>, Option<String>)>> {
        Ok(Vec::new())
    }
}

impl<T: SessionApi + ?Sized> SessionApi for std::sync::Arc<T> {
    fn list_sessions(&self) -> Result<Vec<SessionId>> {
        (**self).list_sessions()
    }
    fn start_session(&self, request: StartSessionRequest) -> Result<SessionId> {
        (**self).start_session(request)
    }
    fn attach_session(&self, request: AttachSessionRequest) -> Result<AttachSessionResponse> {
        (**self).attach_session(request)
    }
    fn subscribe_session_events(&self, session_id: SessionId) -> Result<SessionEventReceiver> {
        (**self).subscribe_session_events(session_id)
    }
    fn subscribe_session_events_from(
        &self,
        request: SubscribeSessionEventsRequest,
    ) -> Result<SessionEventReceiver> {
        (**self).subscribe_session_events_from(request)
    }
    fn acquire_input_lease(&self, request: InputLeaseRequest) -> Result<LeaseChange> {
        (**self).acquire_input_lease(request)
    }
    fn release_input_lease(
        &self,
        session_id: SessionId,
        client_id: ClientId,
    ) -> Result<LeaseChange> {
        (**self).release_input_lease(session_id, client_id)
    }
    fn write_input(&self, request: WriteInputRequest) -> Result<()> {
        (**self).write_input(request)
    }
    fn resize_session(&self, request: ResizeSessionRequest) -> Result<SessionSnapshot> {
        (**self).resize_session(request)
    }
    fn restore_session(&self, request: RestoreSessionRequest) -> Result<SessionSnapshot> {
        (**self).restore_session(request)
    }
    fn snapshot_session(&self, session_id: SessionId) -> Result<SessionSnapshot> {
        (**self).snapshot_session(session_id)
    }
    fn styled_rows(&self, request: StyledRowsRequest) -> Result<StyledRowsResponse> {
        (**self).styled_rows(request)
    }
    fn shutdown_session(&self, session_id: SessionId) -> Result<CompletedSession> {
        (**self).shutdown_session(session_id)
    }
    #[allow(clippy::type_complexity)]
    fn list_session_snippets(&self) -> Result<Vec<(SessionId, Option<String>, Option<String>)>> {
        (**self).list_session_snippets()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observer_attach_is_default_and_does_not_grant_input() {
        assert_eq!(AttachMode::default(), AttachMode::Observer);
        assert!(!AttachMode::Observer.grants_input());
        assert!(AttachMode::InteractiveController.grants_input());
        assert!(AttachMode::AgentController.grants_input());
    }

    #[test]
    fn input_lease_tracks_acquire_takeover_and_release() {
        let mut lease = InputLeaseState::default();
        let tui = ClientId::new("local-tui").expect("client id");
        let agent = ClientId::new("agent").expect("client id");

        let acquired = lease.acquire(tui.clone(), InputControllerKind::Interactive);
        assert_eq!(acquired.action, LeaseChangeAction::Acquired);
        assert_eq!(acquired.generation, 1);
        assert_eq!(lease.holder.as_ref().unwrap().client_id, tui);

        let takeover = lease.acquire(agent.clone(), InputControllerKind::Agent);
        assert_eq!(takeover.action, LeaseChangeAction::TakenOver);
        assert_eq!(takeover.generation, 2);
        assert_eq!(takeover.previous.unwrap().client_id, tui);
        assert_eq!(lease.holder.as_ref().unwrap().client_id, agent);

        assert!(lease.release(&tui).is_none());
        let released = lease.release(&agent).expect("release current holder");
        assert_eq!(released.action, LeaseChangeAction::Released);
        assert_eq!(released.generation, 3);
        assert!(lease.holder.is_none());
    }

    #[test]
    fn session_size_validates_transport_bounds() {
        SessionSize::default().validate().expect("default size");

        let size = SessionSize {
            rows: 0,
            ..SessionSize::default()
        };
        assert!(size.validate().is_err());

        let size = SessionSize {
            cols: u16::MAX as usize + 1,
            ..SessionSize::default()
        };
        assert!(size.validate().is_err());
    }

    #[test]
    fn start_session_request_requires_command_and_valid_size() {
        let request = StartSessionRequest::new("/bin/sh");
        request.validate().expect("valid request");

        let request = StartSessionRequest::new(" ");
        assert!(request.validate().is_err());
    }

    fn ctx(repo: Option<&str>, worktree: Option<&str>, branch: Option<&str>) -> SessionContext {
        SessionContext {
            repository_root: repo.map(PathBuf::from),
            worktree_root: worktree.map(PathBuf::from),
            branch: branch.map(str::to_string),
        }
    }

    #[test]
    fn path_leaf_name_takes_the_last_component() {
        assert_eq!(
            path_leaf_name(Path::new("/home/dev/triage")).as_deref(),
            Some("triage")
        );
        // A rootless path has no leaf.
        assert_eq!(path_leaf_name(Path::new("/")), None);
    }

    #[test]
    fn distinct_worktree_root_hides_the_repo_root() {
        // Worktree equal to the repo root is not distinct.
        assert_eq!(
            ctx(Some("/home/dev/triage"), Some("/home/dev/triage"), None).distinct_worktree_root(),
            None
        );
        // A linked worktree under the repo is distinct.
        assert_eq!(
            ctx(
                Some("/home/dev/triage"),
                Some("/home/dev/triage/worktrees/feat-summary"),
                None,
            )
            .distinct_worktree_root(),
            Some(Path::new("/home/dev/triage/worktrees/feat-summary"))
        );
        // Worktree set without a repo root is still distinct.
        assert_eq!(
            ctx(None, Some("/tmp/scratch"), None).distinct_worktree_root(),
            Some(Path::new("/tmp/scratch"))
        );
    }

    #[test]
    fn branch_name_treats_empty_as_absent() {
        assert_eq!(ctx(None, None, Some("main")).branch_name(), Some("main"));
        assert_eq!(ctx(None, None, Some("")).branch_name(), None);
        assert_eq!(ctx(None, None, None).branch_name(), None);
    }

    #[test]
    fn localization_label_joins_repo_branch_worktree() {
        // Linked worktree: all three parts, worktree leaf distinct from branch.
        assert_eq!(
            ctx(
                Some("/home/dev/triage"),
                Some("/home/dev/triage/worktrees/feat-summary"),
                Some("feat/summary"),
            )
            .localization_label()
            .as_deref(),
            Some("triage  ·  feat/summary  ·  feat-summary")
        );

        // Working in the repo root itself: worktree leaf is hidden.
        assert_eq!(
            ctx(
                Some("/home/dev/triage"),
                Some("/home/dev/triage"),
                Some("main"),
            )
            .localization_label()
            .as_deref(),
            Some("triage  ·  main")
        );

        // Worktree leaf that merely echoes the branch is suppressed.
        assert_eq!(
            ctx(
                Some("/home/dev/triage"),
                Some("/home/dev/triage/worktrees/feature"),
                Some("feature"),
            )
            .localization_label()
            .as_deref(),
            Some("triage  ·  feature")
        );

        // No git context at all: no label.
        assert_eq!(ctx(None, None, None).localization_label(), None);
    }
}
