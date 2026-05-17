use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::TryRecvError;

use anyhow::Result;
use argus_core::session::{
    AttachMode, AttachSessionRequest, ClientId, CompletedSession, InputLeaseState,
    ResizeSessionRequest, SessionApi, SessionEvent, SessionEventReceiver, SessionId, SessionSize,
    SessionSnapshot, StartSessionRequest, StyledRow, StyledRowsRequest, WriteInputRequest,
};
#[cfg(unix)]
use argus_daemon::ipc::UnixSocketClient;
use argus_daemon::session::{SessionManager, SessionManagerConfig};

const MAX_EVENTS_PER_SESSION_TICK: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionView {
    pub session_id: SessionId,
    pub snapshot: SessionSnapshot,
    pub lease: InputLeaseState,
    pub last_completed: Option<CompletedSession>,
    pub scroll_offset: usize,
}

pub struct LocalSessionApp {
    manager: Box<dyn SessionApi>,
    client_id: ClientId,
    owns_sessions: bool,
    sessions: Vec<SessionRuntime>,
    selected: usize,
    current_size: SessionSize,
    last_error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseSessionOutcome {
    Closed,
    ClosedLastSession,
    NotClosed,
}

struct SessionRuntime {
    events: SessionEventReceiver,
    view: SessionView,
}

impl LocalSessionApp {
    pub fn start(size: SessionSize) -> Result<Self> {
        Self::start_with_log_dir(size, default_tui_log_dir())
    }

    #[cfg(unix)]
    pub fn connect(socket_path: impl Into<PathBuf>, size: SessionSize) -> Result<Self> {
        let manager = UnixSocketClient::new(socket_path);
        Self::start_with_manager(Box::new(manager), size, false)
    }

    fn start_with_log_dir(size: SessionSize, log_dir: PathBuf) -> Result<Self> {
        let manager = SessionManager::new(SessionManagerConfig::new(log_dir));
        Self::start_with_manager(Box::new(manager), size, true)
    }

    fn start_with_manager(
        manager: Box<dyn SessionApi>,
        size: SessionSize,
        owns_sessions: bool,
    ) -> Result<Self> {
        let client_id = local_tui_client_id()?;
        let mut sessions = if owns_sessions {
            Vec::new()
        } else {
            attach_existing_sessions(manager.as_ref(), &client_id)?
        };

        if sessions.is_empty() {
            sessions.push(start_local_session(
                manager.as_ref(),
                &client_id,
                size.clone(),
                std::env::current_dir().ok(),
            )?);
        }

        let mut app = Self {
            manager,
            client_id,
            owns_sessions,
            sessions,
            selected: 0,
            current_size: size,
            last_error: None,
        };
        app.activate_selected_session();
        Ok(app)
    }

    pub fn create_session(&mut self, size: SessionSize) {
        let cwd = self.view().snapshot.current_working_directory.clone();
        match start_local_session(self.manager.as_ref(), &self.client_id, size.clone(), cwd) {
            Ok(session) => {
                self.sessions.push(session);
                self.selected = self.sessions.len() - 1;
                self.current_size = size;
                self.last_error = None;
            }
            Err(error) => {
                self.last_error = Some(format!("creating local session: {error}"));
            }
        }
    }

    pub fn close_selected_session(&mut self) -> CloseSessionOutcome {
        let Some(session) = self.sessions.get(self.selected) else {
            self.last_error = Some("no selected session to close".to_string());
            return CloseSessionOutcome::NotClosed;
        };

        let session_id = session.view.session_id.clone();
        if let Err(error) = self.manager.shutdown_session(session_id) {
            self.last_error = Some(format!("closing selected session: {error}"));
            return CloseSessionOutcome::NotClosed;
        }

        self.sessions.remove(self.selected);
        if self.sessions.is_empty() {
            self.last_error = None;
            return CloseSessionOutcome::ClosedLastSession;
        }

        if self.selected >= self.sessions.len() {
            self.selected = self.sessions.len() - 1;
        }
        self.last_error = None;
        self.activate_selected_session();
        CloseSessionOutcome::Closed
    }

    pub fn select_next_session(&mut self) {
        if self.sessions.is_empty() {
            return;
        }

        self.selected = (self.selected + 1) % self.sessions.len();
        self.activate_selected_session();
    }

    pub fn select_previous_session(&mut self) {
        if self.sessions.is_empty() {
            return;
        }

        self.selected = (self.selected + self.sessions.len() - 1) % self.sessions.len();
        self.activate_selected_session();
    }

    pub fn sessions(&self) -> impl ExactSizeIterator<Item = &SessionView> {
        self.sessions.iter().map(|session| &session.view)
    }

    pub fn selected_index(&self) -> usize {
        self.selected
    }

    pub fn view(&self) -> &SessionView {
        &self.sessions[self.selected].view
    }

    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }

    pub fn exits_by_shutting_down_sessions(&self) -> bool {
        self.owns_sessions
    }

    pub fn scroll_selected(&mut self, lines: isize) {
        let Some(session) = self.sessions.get_mut(self.selected) else {
            return;
        };

        let max_offset = session.view.snapshot.visible_rows.len().saturating_sub(1);
        session.view.scroll_offset = if lines.is_negative() {
            session
                .view
                .scroll_offset
                .saturating_sub(lines.unsigned_abs())
        } else {
            session
                .view
                .scroll_offset
                .saturating_add(lines as usize)
                .min(max_offset)
        };
        self.last_error = None;
    }

    pub fn ensure_selected_styled_rows(&mut self, visible_height: usize) -> bool {
        let Some(session) = self.sessions.get(self.selected) else {
            return false;
        };
        let Some((start, end)) = visible_row_range(
            &session.view.snapshot,
            visible_height,
            session.view.scroll_offset,
        ) else {
            return false;
        };
        if snapshot_has_styled_range(&session.view.snapshot, start, end) {
            return false;
        }

        let session_id = session.view.session_id.clone();
        let output_seq = session.view.snapshot.output_seq;
        match self.manager.styled_rows(StyledRowsRequest {
            session_id,
            start,
            end,
        }) {
            Ok(response) => {
                let Some(session) = self.sessions.get_mut(self.selected) else {
                    return false;
                };
                if session.view.snapshot.output_seq == output_seq
                    && response.start == start
                    && styled_rows_match_visible_text(
                        &response.rows,
                        &session.view.snapshot.visible_rows[start..end],
                    )
                    && response_matches_snapshot(output_seq, response.output_seq)
                {
                    session.view.snapshot.styled_rows_start = response.start;
                    session.view.snapshot.styled_rows = response.rows;
                    self.last_error = None;
                    true
                } else {
                    false
                }
            }
            Err(error) => {
                self.last_error = Some(format!("loading styled terminal history: {error}"));
                true
            }
        }
    }

    pub fn reset_selected_scroll(&mut self) {
        if let Some(session) = self.sessions.get_mut(self.selected) {
            session.view.scroll_offset = 0;
        }
    }

    pub fn drain_events(&mut self) -> bool {
        let mut changed = false;
        for session in &mut self.sessions {
            let mut refresh_snapshot = false;

            for _ in 0..MAX_EVENTS_PER_SESSION_TICK {
                match session.events.try_recv() {
                    Ok(envelope) => {
                        refresh_snapshot |= apply_event_to_view(&mut session.view, envelope.event);
                        changed = true;
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        if !session.view.snapshot.exited {
                            self.last_error = Some(format!(
                                "session {} event stream closed",
                                session.view.session_id
                            ));
                            changed = true;
                        }
                        break;
                    }
                }
            }

            if refresh_snapshot {
                let session_id = session.view.session_id.clone();
                match self.manager.snapshot_session(session_id) {
                    Ok(snapshot) => {
                        replace_snapshot_preserving_scroll(&mut session.view, snapshot);
                        changed = true;
                    }
                    Err(error) => {
                        self.last_error = Some(format!(
                            "refreshing session snapshot after output events: {error}"
                        ));
                        changed = true;
                    }
                }
            }
        }
        changed
    }

    pub fn write_input(&mut self, bytes: Vec<u8>) {
        let Some(session) = self.sessions.get_mut(self.selected) else {
            return;
        };

        if bytes.is_empty() || session.view.snapshot.exited {
            return;
        }

        if let Err(error) = self.manager.write_input(WriteInputRequest {
            session_id: session.view.session_id.clone(),
            client_id: self.client_id.clone(),
            bytes,
        }) {
            self.last_error = Some(error.to_string());
        } else {
            self.last_error = None;
        }
    }

    pub fn refresh_selected_snapshot(&mut self) -> bool {
        let Some(session) = self.sessions.get_mut(self.selected) else {
            return false;
        };
        let session_id = session.view.session_id.clone();
        match self.manager.snapshot_session(session_id) {
            Ok(snapshot) => {
                replace_snapshot_preserving_scroll(&mut session.view, snapshot);
                self.last_error = None;
                true
            }
            Err(error) => {
                self.last_error = Some(format!("refreshing selected session snapshot: {error}"));
                true
            }
        }
    }

    pub fn resize(&mut self, size: SessionSize) {
        self.current_size = size;
        self.resize_sessions();
    }

    pub fn shutdown(self) -> Result<Vec<CompletedSession>> {
        if !self.owns_sessions {
            for session in self.sessions {
                let _ = self
                    .manager
                    .release_input_lease(session.view.session_id, self.client_id.clone());
            }
            return Ok(Vec::new());
        }

        let mut completed_sessions = Vec::new();
        let mut result = Ok(());

        for session in self.sessions {
            match self.manager.shutdown_session(session.view.session_id) {
                Ok(completed) => completed_sessions.push(completed),
                Err(error) if result.is_ok() => result = Err(error),
                Err(_) => {}
            }
        }

        result?;
        Ok(completed_sessions)
    }

    fn activate_selected_session(&mut self) {
        self.acquire_selected_input_lease();
        self.resize_selected_session();
    }

    fn acquire_selected_input_lease(&mut self) {
        let Some(session) = self.sessions.get_mut(self.selected) else {
            return;
        };
        if session.view.snapshot.exited
            || session
                .view
                .lease
                .holder
                .as_ref()
                .is_some_and(|holder| holder.client_id == self.client_id)
        {
            return;
        }

        match self
            .manager
            .acquire_input_lease(argus_core::session::InputLeaseRequest {
                session_id: session.view.session_id.clone(),
                client_id: self.client_id.clone(),
                kind: argus_core::session::InputControllerKind::Interactive,
            }) {
            Ok(change) => {
                session.view.lease = InputLeaseState {
                    holder: change.current,
                    generation: change.generation,
                };
                self.last_error = None;
            }
            Err(error) => self.last_error = Some(format!("acquiring input lease: {error}")),
        }
    }

    fn resize_selected_session(&mut self) {
        let Some(session) = self.sessions.get_mut(self.selected) else {
            return;
        };
        if session.view.snapshot.exited || session.view.snapshot.size == self.current_size {
            return;
        }

        match self.manager.resize_session(ResizeSessionRequest {
            session_id: session.view.session_id.clone(),
            size: self.current_size.clone(),
        }) {
            Ok(snapshot) => {
                session.view.snapshot = snapshot;
                self.last_error = None;
            }
            Err(error) => self.last_error = Some(format!("resizing selected session: {error}")),
        }
    }

    fn resize_sessions(&mut self) {
        let mut resize_error = None;
        let mut resized_any = false;

        for session in &mut self.sessions {
            if session.view.snapshot.exited || session.view.snapshot.size == self.current_size {
                continue;
            }

            match self.manager.resize_session(ResizeSessionRequest {
                session_id: session.view.session_id.clone(),
                size: self.current_size.clone(),
            }) {
                Ok(snapshot) => {
                    session.view.snapshot = snapshot;
                    resized_any = true;
                }
                Err(error) => {
                    resize_error.get_or_insert_with(|| {
                        format!("resizing session {}: {error}", session.view.session_id)
                    });
                }
            }
        }

        if let Some(error) = resize_error {
            self.last_error = Some(error);
        } else if resized_any {
            self.last_error = None;
        }
    }
}

fn attach_existing_sessions(
    manager: &dyn SessionApi,
    client_id: &ClientId,
) -> Result<Vec<SessionRuntime>> {
    let mut sessions = Vec::new();

    for session_id in manager.list_sessions()? {
        let session = attach_existing_session(manager, client_id, session_id)?;
        sessions.push(session);
    }

    Ok(sessions)
}

fn attach_existing_session(
    manager: &dyn SessionApi,
    client_id: &ClientId,
    session_id: SessionId,
) -> Result<SessionRuntime> {
    let events = manager.subscribe_session_events(session_id.clone())?;
    let attached = manager.attach_session(AttachSessionRequest {
        session_id: session_id.clone(),
        client_id: client_id.clone(),
        mode: AttachMode::Observer,
    })?;

    Ok(SessionRuntime {
        events,
        view: SessionView {
            session_id,
            snapshot: attached.snapshot,
            lease: attached.lease,
            last_completed: None,
            scroll_offset: 0,
        },
    })
}

fn start_local_session(
    manager: &dyn SessionApi,
    client_id: &ClientId,
    size: SessionSize,
    cwd: Option<PathBuf>,
) -> Result<SessionRuntime> {
    let mut request = default_shell_request();
    request.size = size;
    request.cwd = cwd;

    let session_id = manager.start_session(request)?;
    let events = match manager.subscribe_session_events(session_id.clone()) {
        Ok(events) => events,
        Err(error) => {
            let _ = manager.shutdown_session(session_id);
            return Err(error);
        }
    };
    let attached = match manager.attach_session(AttachSessionRequest {
        session_id: session_id.clone(),
        client_id: client_id.clone(),
        mode: AttachMode::InteractiveController,
    }) {
        Ok(attached) => attached,
        Err(error) => {
            let _ = manager.shutdown_session(session_id);
            return Err(error);
        }
    };

    Ok(SessionRuntime {
        events,
        view: SessionView {
            session_id,
            snapshot: attached.snapshot,
            lease: attached.lease,
            last_completed: None,
            scroll_offset: 0,
        },
    })
}

pub fn apply_event_to_view(view: &mut SessionView, event: SessionEvent) -> bool {
    match event {
        SessionEvent::ResyncRequired {
            session_id,
            snapshot,
            ..
        } if session_id == view.session_id => {
            replace_snapshot_preserving_scroll(view, snapshot);
            false
        }
        SessionEvent::Output { session_id, .. } if session_id == view.session_id => true,
        SessionEvent::Snapshot {
            session_id,
            snapshot,
        } if session_id == view.session_id => {
            replace_snapshot_preserving_scroll(view, snapshot);
            false
        }
        SessionEvent::LeaseChanged { session_id, change } if session_id == view.session_id => {
            view.lease = InputLeaseState {
                holder: change.current,
                generation: change.generation,
            };
            false
        }
        SessionEvent::Exited {
            session_id,
            completed,
        } if session_id == view.session_id => {
            view.snapshot.output_seq = completed.output_seq;
            view.snapshot.bytes_logged = completed.bytes_logged;
            view.snapshot.visible_rows = completed.visible_rows.clone();
            view.snapshot.styled_rows_start = 0;
            view.snapshot.styled_rows.clear();
            view.snapshot.exited = true;
            view.last_completed = Some(completed);
            true
        }
        _ => false,
    }
}

fn replace_snapshot_preserving_scroll(view: &mut SessionView, snapshot: SessionSnapshot) {
    if view.scroll_offset > 0 {
        let previous_rows = view.snapshot.visible_rows.len();
        let next_rows = snapshot.visible_rows.len();
        view.scroll_offset = match next_rows.cmp(&previous_rows) {
            std::cmp::Ordering::Greater => view
                .scroll_offset
                .saturating_add(next_rows - previous_rows)
                .min(next_rows.saturating_sub(1)),
            std::cmp::Ordering::Less => view
                .scroll_offset
                .saturating_sub(previous_rows - next_rows)
                .min(next_rows.saturating_sub(1)),
            std::cmp::Ordering::Equal => view.scroll_offset.min(next_rows.saturating_sub(1)),
        };
    }
    view.snapshot = snapshot;
}

fn visible_row_range(
    snapshot: &SessionSnapshot,
    visible_height: usize,
    scroll_offset: usize,
) -> Option<(usize, usize)> {
    if visible_height == 0 {
        return None;
    }
    let start = snapshot
        .visible_rows
        .len()
        .saturating_sub(visible_height)
        .saturating_sub(scroll_offset);
    let end = start
        .saturating_add(visible_height)
        .min(snapshot.visible_rows.len());
    (start < end).then_some((start, end))
}

fn snapshot_has_styled_range(snapshot: &SessionSnapshot, start: usize, end: usize) -> bool {
    let styled_start = snapshot.styled_rows_start;
    let Some(styled_end) = styled_start.checked_add(snapshot.styled_rows.len()) else {
        return false;
    };
    start >= styled_start && end <= styled_end
}

fn response_matches_snapshot(snapshot_output_seq: u64, response_output_seq: u64) -> bool {
    response_output_seq >= snapshot_output_seq
}

fn styled_rows_match_visible_text(styled_rows: &[StyledRow], visible_rows: &[String]) -> bool {
    styled_rows.len() == visible_rows.len()
        && styled_rows
            .iter()
            .zip(visible_rows)
            .all(|(styled, visible)| styled_row_text(styled).trim_end() == visible)
}

fn styled_row_text(row: &StyledRow) -> String {
    row.spans
        .iter()
        .map(|span| span.text.as_str())
        .collect::<String>()
}

pub fn session_size_from_terminal(rows: u16, cols: u16) -> SessionSize {
    SessionSize {
        rows: usize::from(rows.max(1)),
        cols: usize::from(cols.max(1)),
        pixel_width: usize::from(cols.max(1)) * 10,
        pixel_height: usize::from(rows.max(1)) * 20,
        dpi: 96,
    }
}

fn default_tui_log_dir() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(std::env::temp_dir);
            home.join(".local/state")
        })
        .join("argus/tui-sessions")
}

fn local_tui_client_id() -> Result<ClientId> {
    static NEXT_CLIENT_SEQUENCE: AtomicU64 = AtomicU64::new(1);

    ClientId::new(format!(
        "local-tui-{}-{}",
        std::process::id(),
        NEXT_CLIENT_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ))
}

#[cfg(windows)]
fn default_shell_request() -> StartSessionRequest {
    StartSessionRequest::new("cmd.exe")
}

#[cfg(not(windows))]
fn default_shell_request() -> StartSessionRequest {
    let mut request = StartSessionRequest::new("/bin/sh");
    request.args = vec![
        "-lc".to_string(),
        "stty sane echo; export ARGUS_PROMPT_COMMAND=\"$PROMPT_COMMAND\"; export PROMPT_COMMAND='__argus_pwd=$(printf \"%s\" \"$PWD\" | sed \"s/%/%25/g; s/ /%20/g; s/#/%23/g\"); printf \"\\033]7;file://%s%s\\033\\\\\" \"${HOSTNAME:-localhost}\" \"$__argus_pwd\"; unset __argus_pwd; if [ -n \"$ARGUS_PROMPT_COMMAND\" ]; then eval \"$ARGUS_PROMPT_COMMAND\"; fi'; exec \"${SHELL:-/bin/sh}\""
            .to_string(),
    ];
    request
}

#[cfg(test)]
mod tests {
    use super::*;
    use argus_core::session::TerminalCursor;
    use argus_core::session::{
        AttachSessionResponse, InputControllerKind, InputLeaseHolder, InputLeaseRequest,
        LeaseChange, LeaseChangeAction, ResizeSessionRequest, SessionEventEnvelope,
        StartSessionRequest, StyledRow, StyledRowsResponse, StyledSpan, TerminalColor,
        TerminalStyle,
    };
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    #[test]
    fn lease_event_updates_view_holder() {
        let session_id = SessionId::new("session-1").expect("session id");
        let client_id = ClientId::new("local-tui").expect("client id");
        let mut view = test_view(session_id.clone());

        apply_event_to_view(
            &mut view,
            SessionEvent::LeaseChanged {
                session_id,
                change: LeaseChange {
                    generation: 7,
                    previous: None,
                    current: Some(InputLeaseHolder {
                        client_id: client_id.clone(),
                        kind: InputControllerKind::Interactive,
                    }),
                    action: LeaseChangeAction::Acquired,
                },
            },
        );

        assert_eq!(view.lease.generation, 7);
        assert_eq!(view.lease.holder.as_ref().unwrap().client_id, client_id);
    }

    #[test]
    fn exited_event_marks_snapshot_exited() {
        let session_id = SessionId::new("session-1").expect("session id");
        let mut view = test_view(session_id.clone());
        view.snapshot.styled_rows = vec![argus_core::session::StyledRow { spans: Vec::new() }];

        assert!(apply_event_to_view(
            &mut view,
            SessionEvent::Exited {
                session_id,
                completed: CompletedSession {
                    output_seq: 3,
                    bytes_logged: 21,
                    visible_rows: vec!["done".to_string()],
                },
            },
        ));

        assert!(view.snapshot.exited);
        assert_eq!(view.snapshot.output_seq, 3);
        assert_eq!(view.snapshot.visible_rows, ["done"]);
        assert!(view.snapshot.styled_rows.is_empty());
        assert!(view.last_completed.is_some());
    }

    #[test]
    fn exited_events_refresh_final_styled_snapshot() {
        let session_id = SessionId::new("session-7").expect("session id");
        let (event_tx, event_rx) = std::sync::mpsc::channel();
        event_tx
            .send(SessionEventEnvelope {
                event_seq: 1,
                event: SessionEvent::Exited {
                    session_id: session_id.clone(),
                    completed: CompletedSession {
                        output_seq: 4,
                        bytes_logged: 9,
                        visible_rows: vec!["red".to_string()],
                    },
                },
            })
            .expect("queue exit event");
        drop(event_tx);

        let final_snapshot = SessionSnapshot {
            output_seq: 4,
            bytes_logged: 9,
            size: SessionSize::default(),
            visible_rows: vec!["red".to_string()],
            styled_rows_start: 0,
            styled_rows: vec![argus_core::session::StyledRow {
                spans: vec![argus_core::session::StyledSpan {
                    text: "red".to_string(),
                    style: argus_core::session::TerminalStyle {
                        foreground: Some(argus_core::session::TerminalColor {
                            red: 255,
                            green: 0,
                            blue: 0,
                        }),
                        ..Default::default()
                    },
                }],
            }],
            cursor: TerminalCursor {
                row: 0,
                col: 0,
                visible: false,
            },
            current_working_directory: None,
            context: None,
            bracketed_paste_enabled: false,
            exited: true,
        };

        let mut app = LocalSessionApp::start_with_manager(
            Box::new(ExitSnapshotSessionApi {
                session_id: session_id.clone(),
                event_rx: Mutex::new(Some(event_rx)),
                final_snapshot: final_snapshot.clone(),
            }),
            SessionSize::default(),
            false,
        )
        .expect("start daemon-backed app");

        assert!(app.drain_events());

        assert!(app.view().snapshot.exited);
        assert_eq!(app.view().snapshot.styled_rows, final_snapshot.styled_rows);
    }

    #[test]
    #[cfg(not(windows))]
    fn default_shell_prompt_command_percent_encodes_osc7_paths() {
        let request = default_shell_request();
        let command = request.args.get(1).expect("shell command");

        assert!(command.contains("sed \"s/%/%25/g; s/ /%20/g; s/#/%23/g\""));
        assert!(command.contains("\"$__argus_pwd\""));
        assert!(!command.contains("\"$PWD\"; if"));
        assert!(!command.contains("${PWD//"));
        assert!(!command.contains("${__argus_pwd//"));
    }

    #[test]
    #[cfg(not(windows))]
    fn default_shell_bootstrap_is_posix_shell_syntax() {
        let request = default_shell_request();
        let command = request.args.get(1).expect("shell command");

        let status = std::process::Command::new("/bin/sh")
            .args(["-n", "-c", command])
            .status()
            .expect("check default shell bootstrap syntax");

        assert!(status.success());
    }

    #[test]
    fn output_events_request_snapshot_refresh() {
        let session_id = SessionId::new("session-1").expect("session id");
        let mut view = test_view(session_id.clone());

        assert!(apply_event_to_view(
            &mut view,
            SessionEvent::Output {
                session_id,
                output_seq: 1,
                bytes: b"hello".to_vec(),
            },
        ));

        let snapshot_session_id = view.session_id.clone();
        let snapshot = view.snapshot.clone();
        assert!(!apply_event_to_view(
            &mut view,
            SessionEvent::Snapshot {
                session_id: snapshot_session_id,
                snapshot,
            },
        ));
    }

    #[test]
    fn snapshot_events_keep_scrolled_back_content_anchored() {
        let session_id = SessionId::new("session-1").expect("session id");
        let mut view = test_view(session_id.clone());
        view.snapshot.visible_rows = vec!["a".into(), "b".into(), "c".into(), "d".into()];
        view.scroll_offset = 2;

        let mut snapshot = view.snapshot.clone();
        snapshot.visible_rows = vec![
            "a".into(),
            "b".into(),
            "c".into(),
            "d".into(),
            "e".into(),
            "f".into(),
        ];

        apply_event_to_view(
            &mut view,
            SessionEvent::Snapshot {
                session_id,
                snapshot,
            },
        );

        assert_eq!(view.scroll_offset, 4);
    }

    #[test]
    fn snapshot_events_keep_bottom_following_when_not_scrolled_back() {
        let session_id = SessionId::new("session-1").expect("session id");
        let mut view = test_view(session_id.clone());
        view.snapshot.visible_rows = vec!["a".into(), "b".into()];
        view.scroll_offset = 0;

        let mut snapshot = view.snapshot.clone();
        snapshot.visible_rows = vec!["a".into(), "b".into(), "c".into()];

        apply_event_to_view(
            &mut view,
            SessionEvent::Snapshot {
                session_id,
                snapshot,
            },
        );

        assert_eq!(view.scroll_offset, 0);
    }

    #[test]
    fn snapshot_events_shrink_scroll_offset_when_rows_disappear() {
        let session_id = SessionId::new("session-1").expect("session id");
        let mut view = test_view(session_id.clone());
        view.snapshot.visible_rows = vec!["a".into(), "b".into(), "c".into(), "d".into()];
        view.scroll_offset = 3;

        let mut snapshot = view.snapshot.clone();
        snapshot.visible_rows = vec!["c".into(), "d".into()];

        apply_event_to_view(
            &mut view,
            SessionEvent::Snapshot {
                session_id,
                snapshot,
            },
        );

        assert_eq!(view.scroll_offset, 1);
    }

    #[test]
    fn ensure_selected_styled_rows_loads_scrolled_visible_range() {
        let session_id = SessionId::new("session-1").expect("session id");
        let mut snapshot = test_view(session_id.clone()).snapshot;
        snapshot.output_seq = 7;
        snapshot.visible_rows = vec!["red".into(), "green".into(), "blue".into(), "white".into()];
        snapshot.styled_rows_start = 2;
        snapshot.styled_rows = vec![
            StyledRow { spans: Vec::new() },
            StyledRow { spans: Vec::new() },
        ];
        let (tx, rx) = std::sync::mpsc::channel();
        drop(tx);
        let request = Arc::new(Mutex::new(None));
        let mut app = LocalSessionApp {
            manager: Box::new(StyledRowsSessionApi {
                request: request.clone(),
                output_seq: 7,
            }),
            client_id: ClientId::new("local-tui").expect("client id"),
            owns_sessions: false,
            sessions: vec![SessionRuntime {
                events: rx,
                view: SessionView {
                    session_id,
                    snapshot,
                    lease: InputLeaseState::default(),
                    last_completed: None,
                    scroll_offset: 2,
                },
            }],
            selected: 0,
            current_size: SessionSize::default(),
            last_error: None,
        };

        assert!(app.ensure_selected_styled_rows(2));
        assert_eq!(
            *request.lock().expect("request lock"),
            Some((0usize, 2usize))
        );
        assert_eq!(app.view().snapshot.styled_rows_start, 0);
        assert_eq!(app.view().snapshot.styled_rows.len(), 2);
        assert_eq!(app.view().snapshot.styled_rows[0].spans[0].text, "red");
    }

    #[test]
    fn ensure_selected_styled_rows_accepts_newer_matching_scrollback_response() {
        let session_id = SessionId::new("session-1").expect("session id");
        let mut snapshot = test_view(session_id.clone()).snapshot;
        snapshot.output_seq = 7;
        snapshot.visible_rows = vec!["red".into(), "green".into(), "blue".into(), "white".into()];
        let (tx, rx) = std::sync::mpsc::channel();
        drop(tx);
        let request = Arc::new(Mutex::new(None));
        let mut app = LocalSessionApp {
            manager: Box::new(StyledRowsSessionApi {
                request: request.clone(),
                output_seq: 8,
            }),
            client_id: ClientId::new("local-tui").expect("client id"),
            owns_sessions: false,
            sessions: vec![SessionRuntime {
                events: rx,
                view: SessionView {
                    session_id,
                    snapshot,
                    lease: InputLeaseState::default(),
                    last_completed: None,
                    scroll_offset: 2,
                },
            }],
            selected: 0,
            current_size: SessionSize::default(),
            last_error: None,
        };

        assert!(app.ensure_selected_styled_rows(2));
        assert_eq!(app.view().snapshot.styled_rows_start, 0);
        assert_eq!(app.view().snapshot.styled_rows.len(), 2);
    }

    #[test]
    fn ensure_selected_styled_rows_rejects_newer_mismatched_scrollback_response() {
        let session_id = SessionId::new("session-1").expect("session id");
        let mut snapshot = test_view(session_id.clone()).snapshot;
        snapshot.output_seq = 7;
        snapshot.visible_rows = vec![
            "changed".into(),
            "green".into(),
            "blue".into(),
            "white".into(),
        ];
        let (tx, rx) = std::sync::mpsc::channel();
        drop(tx);
        let request = Arc::new(Mutex::new(None));
        let mut app = LocalSessionApp {
            manager: Box::new(StyledRowsSessionApi {
                request: request.clone(),
                output_seq: 8,
            }),
            client_id: ClientId::new("local-tui").expect("client id"),
            owns_sessions: false,
            sessions: vec![SessionRuntime {
                events: rx,
                view: SessionView {
                    session_id,
                    snapshot,
                    lease: InputLeaseState::default(),
                    last_completed: None,
                    scroll_offset: 2,
                },
            }],
            selected: 0,
            current_size: SessionSize::default(),
            last_error: None,
        };

        assert!(!app.ensure_selected_styled_rows(2));
        assert!(app.view().snapshot.styled_rows.is_empty());
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY behavior needs a dedicated Windows lifecycle test"
    )]
    fn local_app_writes_input_and_refreshes_visible_rows() {
        let log_dir = unique_log_dir();
        let mut app = LocalSessionApp::start_with_log_dir(SessionSize::default(), log_dir.clone())
            .expect("start local session app");
        app.write_input(b"printf 'tui-ready\\r\\n'\n".to_vec());

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            app.drain_events();
            if app
                .view()
                .snapshot
                .visible_rows
                .iter()
                .any(|row| row.contains("tui-ready"))
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for tui-ready; latest rows: {:?}; error: {:?}",
                app.view().snapshot.visible_rows,
                app.last_error()
            );
            std::thread::sleep(Duration::from_millis(20));
        }

        app.shutdown().expect("shutdown local session app");
        let _ = std::fs::remove_dir_all(log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY behavior needs a dedicated Windows lifecycle test"
    )]
    fn local_app_shows_echo_before_enter() {
        let log_dir = unique_log_dir();
        let mut app = LocalSessionApp::start_with_log_dir(SessionSize::default(), log_dir.clone())
            .expect("start local session app");
        app.write_input(b"echo-before-enter".to_vec());

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            app.drain_events();
            if app
                .view()
                .snapshot
                .visible_rows
                .iter()
                .any(|row| row.contains("echo-before-enter"))
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for input echo; latest rows: {:?}; error: {:?}",
                app.view().snapshot.visible_rows,
                app.last_error()
            );
            std::thread::sleep(Duration::from_millis(20));
        }

        app.shutdown().expect("shutdown local session app");
        let _ = std::fs::remove_dir_all(log_dir);
    }

    #[test]
    #[cfg_attr(
        windows,
        ignore = "portable-pty ConPTY behavior needs a dedicated Windows lifecycle test"
    )]
    fn local_app_creates_selects_and_closes_sessions() {
        let log_dir = unique_log_dir();
        let mut app = LocalSessionApp::start_with_log_dir(SessionSize::default(), log_dir.clone())
            .expect("start local session app");
        let first_session = app.view().session_id.clone();
        let first_cwd = app.view().snapshot.current_working_directory.clone();

        app.create_session(SessionSize::default());

        assert_eq!(app.sessions().len(), 2);
        assert_eq!(app.selected_index(), 1);
        assert_ne!(app.view().session_id, first_session);
        assert_eq!(app.view().snapshot.current_working_directory, first_cwd);

        app.select_previous_session();
        assert_eq!(app.selected_index(), 0);
        assert_eq!(app.view().session_id, first_session);

        app.select_next_session();
        assert_eq!(app.close_selected_session(), CloseSessionOutcome::Closed);

        assert_eq!(app.sessions().len(), 1);
        assert_eq!(app.selected_index(), 0);
        assert_eq!(app.view().session_id, first_session);

        app.shutdown().expect("shutdown local session app");
        let _ = std::fs::remove_dir_all(log_dir);
    }

    #[test]
    fn daemon_backed_app_detaches_without_shutting_down_sessions() {
        let counts = Arc::new(Mutex::new(RecordingCounts::default()));
        let app = LocalSessionApp::start_with_manager(
            Box::new(RecordingSessionApi {
                counts: counts.clone(),
                session_ids: Vec::new(),
            }),
            SessionSize::default(),
            false,
        )
        .expect("start daemon-backed app");

        assert!(!app.exits_by_shutting_down_sessions());
        app.shutdown().expect("detach daemon-backed app");

        let counts = counts.lock().expect("counts lock");
        assert_eq!(counts.releases, 1);
        assert_eq!(counts.shutdowns, 0);
    }

    #[test]
    fn daemon_backed_app_reattaches_existing_sessions_before_starting_new_one() {
        let counts = Arc::new(Mutex::new(RecordingCounts::default()));
        let app = LocalSessionApp::start_with_manager(
            Box::new(RecordingSessionApi {
                counts: counts.clone(),
                session_ids: vec![
                    SessionId::new("session-7").expect("session id"),
                    SessionId::new("session-8").expect("session id"),
                ],
            }),
            SessionSize::default(),
            false,
        )
        .expect("start daemon-backed app");

        assert_eq!(app.sessions().len(), 2);
        assert_eq!(app.selected_index(), 0);
        assert_eq!(app.view().session_id, SessionId::new("session-7").unwrap());
        let counts = counts.lock().expect("counts lock");
        assert_eq!(counts.starts, 0);
        assert_eq!(counts.acquires, 1);
    }

    #[test]
    fn daemon_backed_app_reacquires_input_lease_after_closing_selected_session() {
        let counts = Arc::new(Mutex::new(RecordingCounts::default()));
        let mut app = LocalSessionApp::start_with_manager(
            Box::new(RecordingSessionApi {
                counts: counts.clone(),
                session_ids: vec![
                    SessionId::new("session-7").expect("session id"),
                    SessionId::new("session-8").expect("session id"),
                ],
            }),
            SessionSize::default(),
            false,
        )
        .expect("start daemon-backed app");

        assert_eq!(app.close_selected_session(), CloseSessionOutcome::Closed);

        assert_eq!(app.sessions().len(), 1);
        assert_eq!(app.selected_index(), 0);
        assert_eq!(app.view().session_id, SessionId::new("session-8").unwrap());
        let counts = counts.lock().expect("counts lock");
        assert_eq!(counts.shutdowns, 1);
        assert_eq!(counts.acquires, 2);
    }

    #[test]
    fn daemon_backed_app_closing_last_session_requests_tui_exit() {
        let counts = Arc::new(Mutex::new(RecordingCounts::default()));
        let mut app = LocalSessionApp::start_with_manager(
            Box::new(RecordingSessionApi {
                counts: counts.clone(),
                session_ids: vec![SessionId::new("session-7").expect("session id")],
            }),
            SessionSize::default(),
            false,
        )
        .expect("start daemon-backed app");

        assert_eq!(
            app.close_selected_session(),
            CloseSessionOutcome::ClosedLastSession
        );
        assert_eq!(app.sessions().len(), 0);

        let counts = counts.lock().expect("counts lock");
        assert_eq!(counts.shutdowns, 1);
    }

    #[test]
    fn close_selected_session_reports_not_closed_without_selection() {
        let counts = Arc::new(Mutex::new(RecordingCounts::default()));
        let mut app = LocalSessionApp {
            manager: Box::new(RecordingSessionApi {
                counts: counts.clone(),
                session_ids: Vec::new(),
            }),
            client_id: ClientId::new("local-tui").expect("client id"),
            owns_sessions: false,
            sessions: Vec::new(),
            selected: 0,
            current_size: SessionSize::default(),
            last_error: None,
        };

        assert_eq!(app.close_selected_session(), CloseSessionOutcome::NotClosed);
        assert_eq!(app.last_error(), Some("no selected session to close"));

        let counts = counts.lock().expect("counts lock");
        assert_eq!(counts.shutdowns, 0);
    }

    #[test]
    fn terminal_resize_updates_inactive_sessions() {
        let first_id = SessionId::new("session-7").expect("session id");
        let second_id = SessionId::new("session-8").expect("session id");
        let requests = Arc::new(Mutex::new(Vec::new()));
        let new_size = SessionSize {
            rows: 50,
            cols: 120,
            ..SessionSize::default()
        };
        let mut app = LocalSessionApp {
            manager: Box::new(ResizeRecordingSessionApi {
                requests: requests.clone(),
            }),
            client_id: ClientId::new("local-tui").expect("client id"),
            owns_sessions: false,
            sessions: vec![
                SessionRuntime {
                    events: closed_event_receiver(),
                    view: test_view(first_id.clone()),
                },
                SessionRuntime {
                    events: closed_event_receiver(),
                    view: test_view(second_id.clone()),
                },
            ],
            selected: 0,
            current_size: SessionSize::default(),
            last_error: Some("stale resize error".to_string()),
        };

        app.resize(new_size.clone());

        let requests = requests.lock().expect("requests lock");
        assert_eq!(
            *requests,
            vec![
                (first_id.clone(), new_size.clone()),
                (second_id.clone(), new_size.clone()),
            ]
        );
        assert_eq!(app.sessions[0].view.snapshot.size, new_size);
        assert_eq!(app.sessions[1].view.snapshot.size, new_size);
        assert_eq!(app.last_error(), None);
    }

    #[test]
    fn daemon_backed_apps_use_unique_client_ids() {
        let first = LocalSessionApp::start_with_manager(
            Box::new(RecordingSessionApi {
                counts: Arc::new(Mutex::new(RecordingCounts::default())),
                session_ids: vec![SessionId::new("session-1").expect("session id")],
            }),
            SessionSize::default(),
            false,
        )
        .expect("start first daemon-backed app");
        let second = LocalSessionApp::start_with_manager(
            Box::new(RecordingSessionApi {
                counts: Arc::new(Mutex::new(RecordingCounts::default())),
                session_ids: vec![SessionId::new("session-2").expect("session id")],
            }),
            SessionSize::default(),
            false,
        )
        .expect("start second daemon-backed app");

        assert_ne!(first.client_id, second.client_id);
        assert!(first.client_id.as_str().starts_with("local-tui-"));
        assert!(second.client_id.as_str().starts_with("local-tui-"));
    }

    fn test_view(session_id: SessionId) -> SessionView {
        SessionView {
            session_id,
            snapshot: SessionSnapshot {
                output_seq: 0,
                bytes_logged: 0,
                size: SessionSize::default(),
                visible_rows: Vec::new(),
                styled_rows_start: 0,
                styled_rows: Vec::new(),
                cursor: TerminalCursor {
                    row: 0,
                    col: 0,
                    visible: true,
                },
                current_working_directory: None,
                context: None,
                bracketed_paste_enabled: false,
                exited: false,
            },
            lease: InputLeaseState::default(),
            last_completed: None,
            scroll_offset: 0,
        }
    }

    fn unique_log_dir() -> PathBuf {
        std::env::temp_dir().join(format!(
            "argus-tui-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ))
    }

    fn closed_event_receiver() -> SessionEventReceiver {
        let (_tx, rx) = std::sync::mpsc::channel();
        rx
    }

    #[derive(Default)]
    struct RecordingCounts {
        starts: usize,
        acquires: usize,
        releases: usize,
        shutdowns: usize,
    }

    struct RecordingSessionApi {
        counts: Arc<Mutex<RecordingCounts>>,
        session_ids: Vec<SessionId>,
    }

    struct ExitSnapshotSessionApi {
        session_id: SessionId,
        event_rx: Mutex<Option<SessionEventReceiver>>,
        final_snapshot: SessionSnapshot,
    }

    struct StyledRowsSessionApi {
        request: Arc<Mutex<Option<(usize, usize)>>>,
        output_seq: u64,
    }

    struct ResizeRecordingSessionApi {
        requests: Arc<Mutex<Vec<(SessionId, SessionSize)>>>,
    }

    impl SessionApi for RecordingSessionApi {
        fn list_sessions(&self) -> Result<Vec<SessionId>> {
            Ok(self.session_ids.clone())
        }

        fn start_session(&self, _request: StartSessionRequest) -> Result<SessionId> {
            self.counts.lock().expect("counts lock").starts += 1;
            SessionId::new("session-1")
        }

        fn attach_session(&self, request: AttachSessionRequest) -> Result<AttachSessionResponse> {
            Ok(AttachSessionResponse {
                snapshot: SessionSnapshot {
                    output_seq: 0,
                    bytes_logged: 0,
                    size: SessionSize::default(),
                    visible_rows: Vec::new(),
                    styled_rows_start: 0,
                    styled_rows: Vec::new(),
                    cursor: TerminalCursor {
                        row: 0,
                        col: 0,
                        visible: true,
                    },
                    current_working_directory: None,
                    context: None,
                    bracketed_paste_enabled: false,
                    exited: false,
                },
                lease: InputLeaseState {
                    holder: request.mode.controller_kind().map(|kind| InputLeaseHolder {
                        client_id: request.client_id,
                        kind,
                    }),
                    generation: 1,
                },
            })
        }

        fn subscribe_session_events(&self, _session_id: SessionId) -> Result<SessionEventReceiver> {
            let (_tx, rx) = std::sync::mpsc::channel();
            Ok(rx)
        }

        fn acquire_input_lease(&self, request: InputLeaseRequest) -> Result<LeaseChange> {
            self.counts.lock().expect("counts lock").acquires += 1;
            Ok(LeaseChange {
                generation: 2,
                previous: None,
                current: Some(InputLeaseHolder {
                    client_id: request.client_id,
                    kind: request.kind,
                }),
                action: LeaseChangeAction::Acquired,
            })
        }

        fn release_input_lease(
            &self,
            _session_id: SessionId,
            _client_id: ClientId,
        ) -> Result<LeaseChange> {
            self.counts.lock().expect("counts lock").releases += 1;
            Ok(LeaseChange {
                generation: 2,
                previous: None,
                current: None,
                action: LeaseChangeAction::Released,
            })
        }

        fn write_input(&self, _request: WriteInputRequest) -> Result<()> {
            unreachable!("test does not write input")
        }

        fn resize_session(&self, _request: ResizeSessionRequest) -> Result<SessionSnapshot> {
            unreachable!("test does not resize sessions")
        }

        fn snapshot_session(&self, _session_id: SessionId) -> Result<SessionSnapshot> {
            unreachable!("test does not snapshot sessions")
        }

        fn styled_rows(&self, _request: StyledRowsRequest) -> Result<StyledRowsResponse> {
            unreachable!("test does not load styled rows")
        }

        fn shutdown_session(&self, _session_id: SessionId) -> Result<CompletedSession> {
            self.counts.lock().expect("counts lock").shutdowns += 1;
            Ok(CompletedSession {
                output_seq: 0,
                bytes_logged: 0,
                visible_rows: Vec::new(),
            })
        }
    }

    impl SessionApi for ExitSnapshotSessionApi {
        fn list_sessions(&self) -> Result<Vec<SessionId>> {
            Ok(vec![self.session_id.clone()])
        }

        fn start_session(&self, _request: StartSessionRequest) -> Result<SessionId> {
            unreachable!("test attaches an existing session")
        }

        fn attach_session(&self, request: AttachSessionRequest) -> Result<AttachSessionResponse> {
            Ok(AttachSessionResponse {
                snapshot: SessionSnapshot {
                    output_seq: 0,
                    bytes_logged: 0,
                    size: SessionSize::default(),
                    visible_rows: Vec::new(),
                    styled_rows_start: 0,
                    styled_rows: Vec::new(),
                    cursor: TerminalCursor {
                        row: 0,
                        col: 0,
                        visible: true,
                    },
                    current_working_directory: None,
                    context: None,
                    bracketed_paste_enabled: false,
                    exited: false,
                },
                lease: InputLeaseState {
                    holder: request.mode.controller_kind().map(|kind| InputLeaseHolder {
                        client_id: request.client_id,
                        kind,
                    }),
                    generation: 1,
                },
            })
        }

        fn subscribe_session_events(&self, _session_id: SessionId) -> Result<SessionEventReceiver> {
            self.event_rx
                .lock()
                .expect("event receiver lock")
                .take()
                .ok_or_else(|| anyhow::anyhow!("event receiver already taken"))
        }

        fn acquire_input_lease(&self, request: InputLeaseRequest) -> Result<LeaseChange> {
            Ok(LeaseChange {
                generation: 2,
                previous: None,
                current: Some(InputLeaseHolder {
                    client_id: request.client_id,
                    kind: request.kind,
                }),
                action: LeaseChangeAction::Acquired,
            })
        }

        fn release_input_lease(
            &self,
            _session_id: SessionId,
            _client_id: ClientId,
        ) -> Result<LeaseChange> {
            Ok(LeaseChange {
                generation: 2,
                previous: None,
                current: None,
                action: LeaseChangeAction::Released,
            })
        }

        fn write_input(&self, _request: WriteInputRequest) -> Result<()> {
            unreachable!("test does not write input")
        }

        fn resize_session(&self, _request: ResizeSessionRequest) -> Result<SessionSnapshot> {
            unreachable!("test does not resize sessions")
        }

        fn snapshot_session(&self, _session_id: SessionId) -> Result<SessionSnapshot> {
            Ok(self.final_snapshot.clone())
        }

        fn styled_rows(&self, _request: StyledRowsRequest) -> Result<StyledRowsResponse> {
            unreachable!("test does not load styled rows")
        }

        fn shutdown_session(&self, _session_id: SessionId) -> Result<CompletedSession> {
            unreachable!("test does not shut down sessions")
        }
    }

    impl SessionApi for StyledRowsSessionApi {
        fn list_sessions(&self) -> Result<Vec<SessionId>> {
            unreachable!("test does not list sessions")
        }

        fn start_session(&self, _request: StartSessionRequest) -> Result<SessionId> {
            unreachable!("test does not start sessions")
        }

        fn attach_session(&self, _request: AttachSessionRequest) -> Result<AttachSessionResponse> {
            unreachable!("test does not attach sessions")
        }

        fn subscribe_session_events(&self, _session_id: SessionId) -> Result<SessionEventReceiver> {
            unreachable!("test does not subscribe")
        }

        fn acquire_input_lease(&self, _request: InputLeaseRequest) -> Result<LeaseChange> {
            unreachable!("test does not acquire leases")
        }

        fn release_input_lease(
            &self,
            _session_id: SessionId,
            _client_id: ClientId,
        ) -> Result<LeaseChange> {
            unreachable!("test does not release leases")
        }

        fn write_input(&self, _request: WriteInputRequest) -> Result<()> {
            unreachable!("test does not write input")
        }

        fn resize_session(&self, _request: ResizeSessionRequest) -> Result<SessionSnapshot> {
            unreachable!("test does not resize sessions")
        }

        fn snapshot_session(&self, _session_id: SessionId) -> Result<SessionSnapshot> {
            unreachable!("test does not snapshot sessions")
        }

        fn styled_rows(&self, request: StyledRowsRequest) -> Result<StyledRowsResponse> {
            *self.request.lock().expect("request lock") = Some((request.start, request.end));
            Ok(StyledRowsResponse {
                output_seq: self.output_seq,
                start: request.start,
                rows: vec![
                    StyledRow {
                        spans: vec![StyledSpan {
                            text: "red".to_string(),
                            style: TerminalStyle {
                                foreground: Some(TerminalColor {
                                    red: 255,
                                    green: 0,
                                    blue: 0,
                                }),
                                ..TerminalStyle::default()
                            },
                        }],
                    },
                    StyledRow {
                        spans: vec![StyledSpan {
                            text: "green".to_string(),
                            style: TerminalStyle {
                                foreground: Some(TerminalColor {
                                    red: 0,
                                    green: 255,
                                    blue: 0,
                                }),
                                ..TerminalStyle::default()
                            },
                        }],
                    },
                ],
            })
        }

        fn shutdown_session(&self, _session_id: SessionId) -> Result<CompletedSession> {
            unreachable!("test does not shut down sessions")
        }
    }

    impl SessionApi for ResizeRecordingSessionApi {
        fn list_sessions(&self) -> Result<Vec<SessionId>> {
            unreachable!("test does not list sessions")
        }

        fn start_session(&self, _request: StartSessionRequest) -> Result<SessionId> {
            unreachable!("test does not start sessions")
        }

        fn attach_session(&self, _request: AttachSessionRequest) -> Result<AttachSessionResponse> {
            unreachable!("test does not attach sessions")
        }

        fn subscribe_session_events(&self, _session_id: SessionId) -> Result<SessionEventReceiver> {
            unreachable!("test does not subscribe")
        }

        fn acquire_input_lease(&self, _request: InputLeaseRequest) -> Result<LeaseChange> {
            unreachable!("test does not acquire leases")
        }

        fn release_input_lease(
            &self,
            _session_id: SessionId,
            _client_id: ClientId,
        ) -> Result<LeaseChange> {
            unreachable!("test does not release leases")
        }

        fn write_input(&self, _request: WriteInputRequest) -> Result<()> {
            unreachable!("test does not write input")
        }

        fn resize_session(&self, request: ResizeSessionRequest) -> Result<SessionSnapshot> {
            self.requests
                .lock()
                .expect("requests lock")
                .push((request.session_id.clone(), request.size.clone()));

            let mut view = test_view(request.session_id);
            view.snapshot.size = request.size;
            Ok(view.snapshot)
        }

        fn snapshot_session(&self, _session_id: SessionId) -> Result<SessionSnapshot> {
            unreachable!("test does not snapshot sessions")
        }

        fn styled_rows(&self, _request: StyledRowsRequest) -> Result<StyledRowsResponse> {
            unreachable!("test does not load styled rows")
        }

        fn shutdown_session(&self, _session_id: SessionId) -> Result<CompletedSession> {
            unreachable!("test does not shut down sessions")
        }
    }
}
