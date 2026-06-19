use std::ffi::{OsStr, OsString};
use std::io::{self, Stdout};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use base64::Engine;
use crossterm::event::{
    self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
    Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};
use triage::{
    CloseSessionOutcome, LocalSessionApp, SessionView, session_size_from_terminal,
    styled_rows_match_visible_text,
};
use triage_core::session::{
    InputControllerKind, SessionSize, StyledRow, TerminalColor, TerminalCursor, TerminalStyle,
    path_leaf_name,
};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

const SIDEBAR_COLS: u16 = 28;
const UI_EVENT_POLL: Duration = Duration::from_millis(8);

fn main() -> Result<()> {
    let startup_mode = StartupMode::from_args(std::env::args_os().skip(1))?;
    if startup_mode == StartupMode::Help {
        println!("{}", StartupMode::HELP);
        return Ok(());
    }

    if startup_mode == StartupMode::Pair {
        run_pairing_display()?;
        return Ok(());
    }

    if let StartupMode::ClientReload {
        socket_path: _socket_path,
    } = &startup_mode
    {
        #[cfg(any(unix, windows))]
        {
            println!("Sending ReloadClientAssets command to triaged daemon...");
            notify_daemon_reload(_socket_path.clone(), true)?;
            return Ok(());
        }
        #[cfg(not(any(unix, windows)))]
        {
            bail!("Client asset reloading is not supported on this platform.");
        }
    }

    if let StartupMode::ClientUpgrade {
        socket_path: _socket_path,
        src,
    } = &startup_mode
    {
        if !src.exists() || !src.is_dir() {
            bail!(
                "Source directory does not exist or is not a directory: {}",
                src.display()
            );
        }

        let dest = triaged::http::default_override_dir()
            .context("failed to resolve web override directory")?;

        println!(
            "Upgrading web client assets from {} to {}...",
            src.display(),
            dest.display()
        );

        copy_dir_all(src, &dest).context("failed to copy client assets")?;
        println!("Assets successfully copied.");

        #[cfg(any(unix, windows))]
        {
            println!("Notifying triaged daemon to reload web cache...");
            notify_daemon_reload(_socket_path.clone(), false)?;
        }
        return Ok(());
    }

    let size = initial_session_size()?;
    let mut app = start_app(size, startup_mode).context("starting local session")?;
    let mut terminal = match TerminalSession::enter().context("starting terminal UI") {
        Ok(terminal) => terminal,
        Err(error) => {
            let _ = app.shutdown();
            return Err(error);
        }
    };

    let result = run(&mut terminal.terminal, &mut app);
    let shutdown_result = app.shutdown();
    terminal.restore()?;

    result?;
    shutdown_result.context("shutting down local session")?;
    Ok(())
}

fn copy_dir_all(src: impl AsRef<Path>, dst: impl AsRef<Path>) -> io::Result<()> {
    std::fs::create_dir_all(&dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        if ty.is_dir() {
            copy_dir_all(entry.path(), dst.as_ref().join(entry.file_name()))?;
        } else {
            std::fs::copy(entry.path(), dst.as_ref().join(entry.file_name()))?;
        }
    }
    Ok(())
}

fn run_pairing_display() -> Result<()> {
    let config_path = triage_core::config::Config::default_path().unwrap_or_else(|_| {
        let home = std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        home.join(".config/triage/config.toml")
    });
    let config = if config_path.exists() {
        triage_core::config::Config::load_from_path(&config_path).unwrap_or_default()
    } else {
        triage_core::config::Config::default()
    };
    let bind_addr = config.remote.bind_addr()?;
    let verification_url = pairing_url_for_bind(bind_addr);

    println!("\x1b[1;36m====================================================\x1b[0m");
    println!("\x1b[1;36m               TRIAGE REMOTE PAIRING                \x1b[0m");
    println!("\x1b[1;36m====================================================\x1b[0m");
    println!();
    println!("  Verification URL: \x1b[1;33m{}\x1b[0m", verification_url);
    println!();
    println!("  Open the Triage client. If it is not paired, it will show a device code.");
    println!("  Enter that device code at the verification URL to get a pairing PIN.");
    println!("  Then enter the PIN back in that same Triage client.");
    println!("\x1b[1;36m====================================================\x1b[0m");

    Ok(())
}

fn pairing_url_for_bind(bind_addr: std::net::SocketAddr) -> String {
    let ip = match bind_addr.ip() {
        std::net::IpAddr::V4(ip) if ip.is_unspecified() => "127.0.0.1".to_string(),
        std::net::IpAddr::V6(ip) if ip.is_unspecified() => "[::1]".to_string(),
        std::net::IpAddr::V4(ip) => ip.to_string(),
        std::net::IpAddr::V6(ip) => format!("[{ip}]"),
    };
    format!("http://{}:{}/pair", ip, bind_addr.port())
}

#[cfg(any(unix, windows))]
fn start_app(size: SessionSize, startup_mode: StartupMode) -> Result<LocalSessionApp> {
    match startup_mode {
        StartupMode::Daemon { socket_path } => LocalSessionApp::connect(&socket_path, size)
            .with_context(|| {
                format!(
                    "connecting to the Triage daemon at {}; start triaged or pass --embedded for development mode",
                    triaged::ipc::display_endpoint(&socket_path)
                )
            }),
        StartupMode::Embedded => {
            tracing::warn!("starting embedded local session manager");
            LocalSessionApp::start(size)
        }
        StartupMode::Pair => unreachable!("pair mode exits before startup"),
        StartupMode::Help => unreachable!("help mode exits before startup"),
        StartupMode::ClientReload { .. } | StartupMode::ClientUpgrade { .. } => {
            unreachable!("client subcommands exit before starting app")
        }
    }
}

#[cfg(not(any(unix, windows)))]
fn start_app(size: SessionSize, startup_mode: StartupMode) -> Result<LocalSessionApp> {
    match startup_mode {
        StartupMode::Daemon { .. } => {
            bail!(
                "daemon socket mode requires the local IPC transport, which is unavailable on this platform; pass --embedded for development mode"
            )
        }
        StartupMode::Embedded => LocalSessionApp::start(size),
        StartupMode::Pair => unreachable!("pair mode exits before startup"),
        StartupMode::Help => unreachable!("help mode exits before startup"),
        StartupMode::ClientReload { .. } | StartupMode::ClientUpgrade { .. } => {
            unreachable!("client subcommands exit before starting app")
        }
    }
}

/// Tell a running daemon to reload its in-memory web-asset cache.
///
/// `required` controls failure handling and matches the two call sites: `client
/// reload` is an explicit request, so a failure is a hard error with an "is the
/// daemon running?" hint; `client upgrade` notifies best-effort after copying
/// assets, so a failure is a benign note (the daemon picks up the new assets when
/// it next starts). This attempts the connect on both platforms rather than
/// pre-checking the path, because on Windows the endpoint is a named pipe with no
/// filesystem entry to stat — the connect itself is the only honest liveness test.
#[cfg(any(unix, windows))]
fn notify_daemon_reload(socket_path: Option<PathBuf>, required: bool) -> Result<()> {
    let path = socket_path.unwrap_or_else(triaged::ipc::default_socket_path);
    let endpoint = triaged::ipc::display_endpoint(&path);
    let client = triaged::ipc::IpcClient::new(path);
    match client.reload_client_assets() {
        Ok(()) => {
            println!("Successfully reloaded the daemon web-asset cache at {endpoint}.");
            Ok(())
        }
        Err(error) if required => Err(error.context(format!(
            "failed to reach the Triage daemon at {endpoint}. Is the daemon running?"
        ))),
        Err(error) => {
            println!(
                "Daemon at {endpoint} not reachable ({error}); new assets will load when it next starts."
            );
            Ok(())
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum StartupMode {
    Daemon {
        socket_path: PathBuf,
    },
    Embedded,
    Pair,
    ClientReload {
        socket_path: Option<PathBuf>,
    },
    ClientUpgrade {
        socket_path: Option<PathBuf>,
        src: PathBuf,
    },
    Help,
}

impl StartupMode {
    const HELP: &'static str = "\
usage: triage [--socket <path>] [--embedded] [pair] [client reload] [client upgrade --src <dir>]

Options:
  pair              Display remote client pairing instructions
  client reload     Reload in-memory web asset cache inside running daemon
  client upgrade    Upgrade web client assets from a source directory
  --src <dir>       Source directory for web client upgrade (required for client upgrade)
  --socket <path>   Connect to a daemon control socket at <path>
                    (Unix domain socket on Unix, named pipe on Windows)
  --embedded        Run an isolated in-process session manager
  -h, --help        Print this help text

By default triage connects to the running daemon (Unix domain socket on Unix,
named pipe on Windows). Use --embedded for an isolated in-process session
manager when no daemon is running.";

    fn from_args(args: impl IntoIterator<Item = OsString>) -> Result<Self> {
        let mut mode = None;
        let mut socket_path = None;
        let mut src_path = None;
        let mut args = args.into_iter();

        while let Some(arg) = args.next() {
            match arg.to_str() {
                Some("pair") | Some("--pair") => {
                    if mode.replace(StartupMode::Pair).is_some() {
                        bail!("cannot combine multiple modes; pass --help for usage");
                    }
                }
                Some("client") => {
                    let Some(subcmd) = args.next() else {
                        bail!(
                            "client requires a subcommand (reload or upgrade); pass --help for usage"
                        );
                    };
                    match subcmd.to_str() {
                        Some("reload") => {
                            if mode
                                .replace(StartupMode::ClientReload { socket_path: None })
                                .is_some()
                            {
                                bail!("cannot combine multiple modes; pass --help for usage");
                            }
                        }
                        Some("upgrade") => {
                            if mode
                                .replace(StartupMode::ClientUpgrade {
                                    socket_path: None,
                                    src: PathBuf::new(),
                                })
                                .is_some()
                            {
                                bail!("cannot combine multiple modes; pass --help for usage");
                            }
                        }
                        Some(other) => {
                            bail!("unknown client subcommand {other}; reload or upgrade")
                        }
                        None => bail!("unexpected non-UTF-8 client subcommand"),
                    }
                }
                Some("--src") => {
                    let Some(val) = args.next() else {
                        bail!("--src option requires a source directory path");
                    };
                    src_path = Some(PathBuf::from(val));
                }
                Some("--embedded") => {
                    if mode.replace(StartupMode::Embedded).is_some() {
                        bail!("--embedded can only be passed once; pass --help for usage");
                    }
                }
                Some("--socket") => {
                    if socket_path.is_some() {
                        bail!("--socket can only be passed once; pass --help for usage");
                    }
                    let Some(path) = args.next() else {
                        bail!("--socket requires a path; pass --help for usage");
                    };
                    socket_path = Some(PathBuf::from(path));
                }
                Some("--help") | Some("-h") => return Ok(StartupMode::Help),
                Some(flag) if flag.starts_with('-') => {
                    bail!("unknown option {flag}; pass --help for usage")
                }
                Some(value) => bail!("unexpected argument {value}; pass --help for usage"),
                None => bail!(
                    "unexpected non-UTF-8 argument {}; pass socket paths with --socket or pass --help for usage",
                    display_os_str(&arg)
                ),
            }
        }

        if mode == Some(StartupMode::Pair) && socket_path.is_some() {
            bail!("pair mode cannot be combined with --socket; pass --help for usage");
        }

        if mode == Some(StartupMode::Embedded) && socket_path.is_some() {
            bail!("--embedded cannot be combined with --socket; pass --help for usage");
        }

        match mode {
            Some(StartupMode::ClientReload { .. }) => Ok(StartupMode::ClientReload { socket_path }),
            Some(StartupMode::ClientUpgrade { .. }) => {
                let Some(src) = src_path else {
                    bail!("client upgrade requires a source directory via --src <path>");
                };
                Ok(StartupMode::ClientUpgrade { socket_path, src })
            }
            Some(other) => {
                if socket_path.is_some() && other == StartupMode::Embedded {
                    bail!("--embedded cannot be combined with --socket; pass --help for usage");
                }
                Ok(other)
            }
            None => {
                if let Some(socket_path) = socket_path {
                    Ok(StartupMode::Daemon { socket_path })
                } else {
                    Ok(default_startup_mode())
                }
            }
        }
    }
}

#[cfg(any(unix, windows))]
fn default_startup_mode() -> StartupMode {
    StartupMode::Daemon {
        socket_path: triaged::ipc::default_socket_path(),
    }
}

#[cfg(not(any(unix, windows)))]
fn default_startup_mode() -> StartupMode {
    StartupMode::Embedded
}

fn display_os_str(value: &OsStr) -> String {
    value.to_string_lossy().into_owned()
}

fn run(terminal: &mut Terminal<CrosstermBackend<Stdout>>, app: &mut LocalSessionApp) -> Result<()> {
    let mut sidebar_visible = true;
    let mut pending_confirmation = None;
    let mut terminal_area = Rect::default();
    let mut selection = None;
    let mut needs_draw = true;
    let mut sidebar_scroll_offset = 0usize;
    let mut last_sidebar_scroll_tick = Instant::now();

    loop {
        if sidebar_visible
            && selected_sidebar_context_overflows(app, usize::from(SIDEBAR_COLS.saturating_sub(1)))
            && last_sidebar_scroll_tick.elapsed() >= Duration::from_millis(250)
        {
            sidebar_scroll_offset = sidebar_scroll_offset.saturating_add(1);
            last_sidebar_scroll_tick = Instant::now();
            needs_draw = true;
        }

        needs_draw |= app.drain_events();
        if needs_draw {
            if terminal_area.height > 0 {
                app.ensure_selected_styled_rows(usize::from(terminal_area.height));
            }
            terminal.draw(|frame| {
                terminal_area = draw(
                    frame,
                    app,
                    sidebar_visible,
                    pending_confirmation,
                    selection,
                    sidebar_scroll_offset,
                );
            })?;
            needs_draw = false;
        }

        if !event::poll(UI_EVENT_POLL)? {
            continue;
        }

        // The `Event::Mouse` arm's inner `if` can't become a match guard (it
        // uses `?`), so this newer-clippy collapse suggestion doesn't apply.
        #[allow(clippy::collapsible_match)]
        match event::read()? {
            Event::Key(key) if key.kind != KeyEventKind::Press => {}
            Event::Key(key) if should_exit(key) => {
                needs_draw = true;
                if app.exits_by_shutting_down_sessions() {
                    if pending_confirmation == Some(Confirmation::Exit) {
                        return Ok(());
                    }
                    pending_confirmation = Some(Confirmation::Exit);
                    continue;
                }
                return Ok(());
            }
            Event::Key(key) => match key_to_command(key) {
                Some(AppCommand::New) => {
                    needs_draw = true;
                    sidebar_scroll_offset = 0;
                    last_sidebar_scroll_tick = Instant::now();
                    pending_confirmation = None;
                    selection = None;
                    app.create_session(current_session_size(sidebar_visible)?);
                }
                Some(AppCommand::Close) => {
                    needs_draw = true;
                    if pending_confirmation != Some(Confirmation::CloseSession) {
                        pending_confirmation = Some(Confirmation::CloseSession);
                        continue;
                    }
                    pending_confirmation = None;
                    selection = None;
                    match app.close_selected_session() {
                        CloseSessionOutcome::ClosedLastSession => return Ok(()),
                        CloseSessionOutcome::Closed => {
                            sidebar_scroll_offset = 0;
                            last_sidebar_scroll_tick = Instant::now();
                        }
                        CloseSessionOutcome::NotClosed => {}
                    }
                }
                Some(AppCommand::Next) => {
                    needs_draw = true;
                    sidebar_scroll_offset = 0;
                    last_sidebar_scroll_tick = Instant::now();
                    pending_confirmation = None;
                    selection = None;
                    app.select_next_session();
                }
                Some(AppCommand::Previous) => {
                    needs_draw = true;
                    sidebar_scroll_offset = 0;
                    last_sidebar_scroll_tick = Instant::now();
                    pending_confirmation = None;
                    selection = None;
                    app.select_previous_session();
                }
                Some(AppCommand::ToggleSidebar) => {
                    needs_draw = true;
                    pending_confirmation = None;
                    selection = None;
                    sidebar_visible = !sidebar_visible;
                    app.resize(current_session_size(sidebar_visible)?);
                }
                Some(AppCommand::ScrollUp) => {
                    needs_draw = true;
                    pending_confirmation = None;
                    selection = None;
                    app.scroll_selected(terminal_page_scroll_lines(terminal_area));
                }
                Some(AppCommand::ScrollDown) => {
                    needs_draw = true;
                    pending_confirmation = None;
                    selection = None;
                    app.scroll_selected(-terminal_page_scroll_lines(terminal_area));
                }
                None => {
                    needs_draw = true;
                    pending_confirmation = None;
                    if copy_selection_on_control_c(
                        key,
                        app.view(),
                        terminal_area,
                        &mut selection,
                        terminal.backend_mut(),
                    )? {
                        continue;
                    }
                    selection = None;
                    if let Some(bytes) = key_to_input(key) {
                        app.write_input(bytes);
                    }
                }
            },
            Event::Resize(cols, rows) => {
                needs_draw = true;
                pending_confirmation = None;
                selection = None;
                app.resize(session_size_from_app_terminal(rows, cols, sidebar_visible));
            }
            Event::Paste(text) => {
                needs_draw = true;
                pending_confirmation = None;
                selection = None;
                app.refresh_selected_snapshot();
                app.write_input(paste_input(
                    &text,
                    app.view().snapshot.bracketed_paste_enabled,
                ));
            }
            Event::Mouse(mouse) => {
                if handle_mouse_event(
                    mouse,
                    terminal_area,
                    app,
                    &mut selection,
                    terminal.backend_mut(),
                )? {
                    needs_draw = true;
                    pending_confirmation = None;
                }
            }
            _ => {}
        }
    }
}

fn draw(
    frame: &mut ratatui::Frame<'_>,
    app: &LocalSessionApp,
    sidebar_visible: bool,
    pending_confirmation: Option<Confirmation>,
    selection: Option<TerminalSelection>,
    sidebar_scroll_offset: usize,
) -> Rect {
    let root = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(frame.area());

    let terminal_area = if sidebar_visible {
        let body = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(SIDEBAR_COLS), Constraint::Min(20)])
            .split(root[0]);
        draw_sidebar(frame, body[0], app, sidebar_scroll_offset);
        draw_terminal(frame, body[1], app.view(), selection);
        body[1]
    } else {
        draw_terminal(frame, root[0], app.view(), selection);
        root[0]
    };

    draw_status(
        frame,
        root[1],
        app.view(),
        app.last_error(),
        pending_confirmation,
    );
    terminal_area
}

fn draw_sidebar(
    frame: &mut ratatui::Frame<'_>,
    area: Rect,
    app: &LocalSessionApp,
    scroll_offset: usize,
) {
    let content_width = sidebar_content_width(area);
    let rows = sidebar_visible_rows(
        app.sessions(),
        app.selected_index(),
        content_width,
        scroll_offset,
        usize::from(area.height),
    );

    frame.render_widget(
        Paragraph::new(rows).block(Block::default().borders(Borders::RIGHT)),
        area,
    );
}

fn sidebar_visible_rows<'a>(
    sessions: impl Iterator<Item = &'a SessionView>,
    selected: usize,
    width: usize,
    scroll_offset: usize,
    visible_height: usize,
) -> Vec<Line<'static>> {
    if visible_height == 0 {
        return Vec::new();
    }

    let mut selected_start = 0usize;
    let mut selected_end = 0usize;
    let rows = sessions
        .enumerate()
        .fold(Vec::<Line<'static>>::new(), |mut rows, (index, view)| {
            let start = rows.len();
            rows.extend(session_sidebar_rows(
                index,
                selected,
                view,
                width,
                scroll_offset,
            ));
            if index == selected {
                selected_start = start;
                selected_end = rows.len();
            }
            rows
        });

    let start = sidebar_viewport_start(rows.len(), selected_start, selected_end, visible_height);
    rows.into_iter().skip(start).take(visible_height).collect()
}

fn sidebar_viewport_start(
    total_rows: usize,
    selected_start: usize,
    selected_end: usize,
    visible_height: usize,
) -> usize {
    if visible_height == 0 || total_rows <= visible_height {
        return 0;
    }

    let max_start = total_rows - visible_height;
    if selected_end.saturating_sub(selected_start) >= visible_height {
        return selected_start.min(max_start);
    }
    selected_end.saturating_sub(visible_height).min(max_start)
}

fn sidebar_content_width(area: Rect) -> usize {
    usize::from(area.width.saturating_sub(1))
}

fn session_sidebar_rows(
    index: usize,
    selected: usize,
    view: &SessionView,
    width: usize,
    scroll_offset: usize,
) -> Vec<Line<'static>> {
    let holder = view
        .lease
        .holder
        .as_ref()
        .map(|holder| match holder.kind {
            InputControllerKind::Interactive => "interactive",
            InputControllerKind::Agent => "agent",
        })
        .unwrap_or("observer");
    let state = if view.snapshot.exited {
        "exited"
    } else {
        "running"
    };
    let marker = if index == selected { ">" } else { " " };
    let style = if index == selected {
        Style::default()
            .fg(Color::Yellow)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default()
    };

    let mut rows = vec![
        Line::from(Span::styled(
            truncate_to_width(format!("{marker} {}  {state}", view.session_id), width),
            style,
        )),
        Line::from(truncate_to_width(
            format!(
                "  {holder}  {}x{}",
                view.snapshot.size.cols, view.snapshot.size.rows
            ),
            width,
        )),
    ];
    rows.extend(session_context_rows(
        view,
        width,
        index == selected,
        scroll_offset,
    ));
    rows.push(Line::from(""));
    rows
}

fn session_context_rows(
    view: &SessionView,
    width: usize,
    selected: bool,
    scroll_offset: usize,
) -> Vec<Line<'static>> {
    let context = view.snapshot.context.as_ref();

    let mut rows = Vec::with_capacity(3);
    if let Some(context) = context {
        if let Some(root) = context
            .repository_root
            .as_ref()
            .or(context.worktree_root.as_ref())
        {
            rows.push(context_path_row("r", root, width, selected, scroll_offset));
        } else {
            rows.push(Line::from(""));
        }

        if let Some(worktree_root) = context.distinct_worktree_root() {
            rows.push(context_path_row(
                "w",
                worktree_root,
                width,
                selected,
                scroll_offset,
            ));
        }
    } else {
        let cwd = view.snapshot.current_working_directory.as_ref();
        if let Some(cwd) = cwd {
            rows.push(context_path_row("c", cwd, width, selected, scroll_offset));
        } else {
            rows.push(Line::from(""));
        }
    }

    if let Some(branch) = context.and_then(|context| context.branch.as_ref()) {
        let branch_width = width.saturating_sub(4);
        let branch_name = if selected {
            scrolling_value(branch, branch_width, scroll_offset)
        } else {
            compact_value(branch.rsplit('/').next().unwrap_or(branch), branch_width)
        };
        rows.push(Line::from(truncate_to_width(
            format!("  b {branch_name}"),
            width,
        )));
    } else {
        rows.push(Line::from(""));
    }
    rows
}

fn context_path_row(
    label: &str,
    path: &Path,
    width: usize,
    selected: bool,
    scroll_offset: usize,
) -> Line<'static> {
    let name = context_path_display_name(path);
    let value_width = width.saturating_sub(label.len() + 3);
    let value = if selected {
        scrolling_value(&name, value_width, scroll_offset)
    } else {
        compact_value(&name, value_width)
    };
    Line::from(truncate_to_width(format!("  {label} {value}"), width))
}

/// Collects the longest leading run of `value` whose terminal display width
/// fits within `budget` cells.
fn take_prefix_width(value: &str, budget: usize) -> String {
    let mut out = String::new();
    let mut used = 0;
    for ch in value.chars() {
        let w = UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + w > budget {
            break;
        }
        used += w;
        out.push(ch);
    }
    out
}

/// Like [`take_prefix_width`] but keeps the trailing run instead.
fn take_suffix_width(value: &str, budget: usize) -> String {
    let mut tail: Vec<char> = Vec::new();
    let mut used = 0;
    for ch in value.chars().rev() {
        let w = UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + w > budget {
            break;
        }
        used += w;
        tail.push(ch);
    }
    tail.into_iter().rev().collect()
}

fn truncate_to_width(value: String, width: usize) -> String {
    if width == 0 {
        return String::new();
    }
    if UnicodeWidthStr::width(value.as_str()) <= width {
        return value;
    }
    if width == 1 {
        return "~".to_string();
    }

    let mut truncated = take_prefix_width(&value, width - 1);
    truncated.push('~');
    truncated
}

fn compact_value(value: &str, width: usize) -> String {
    if width == 0 {
        return String::new();
    }
    if UnicodeWidthStr::width(value) <= width {
        return value.to_string();
    }
    if width <= 3 {
        return take_prefix_width(value, width);
    }

    let budget = width - 1;
    let head_budget = budget / 2;
    let tail_budget = budget - head_budget;
    let head = take_prefix_width(value, head_budget);
    let tail = take_suffix_width(value, tail_budget);
    format!("{head}~{tail}")
}

fn scrolling_value(value: &str, width: usize, offset: usize) -> String {
    if width == 0 {
        return String::new();
    }
    let chars = value.chars().collect::<Vec<_>>();
    if chars.len() <= width {
        return value.to_string();
    }

    let mut cycle = chars;
    cycle.extend([' ', ' ', ' ']);
    let offset = offset % cycle.len();
    (0..width)
        .map(|index| cycle[(offset + index) % cycle.len()])
        .collect()
}

fn selected_sidebar_context_overflows(app: &LocalSessionApp, width: usize) -> bool {
    session_context_overflows(app.view(), width)
}

fn session_context_overflows(view: &SessionView, width: usize) -> bool {
    let context = view.snapshot.context.as_ref();
    let location_overflows = if let Some(context) = context {
        let repo_overflows = context
            .repository_root
            .as_ref()
            .or(context.worktree_root.as_ref())
            .is_some_and(|root| context_path_overflows(root, width));
        let worktree_overflows = context
            .distinct_worktree_root()
            .is_some_and(|worktree_root| context_path_overflows(worktree_root, width));
        repo_overflows || worktree_overflows
    } else {
        view.snapshot
            .current_working_directory
            .as_ref()
            .is_some_and(|cwd| context_path_overflows(cwd, width))
    };
    let branch_overflows = context
        .and_then(|context| context.branch.as_ref())
        .map(|branch| UnicodeWidthStr::width(branch.as_str()) > width.saturating_sub(4))
        .unwrap_or(false);
    location_overflows || branch_overflows
}

fn context_path_overflows(path: &Path, width: usize) -> bool {
    UnicodeWidthStr::width(context_path_display_name(path).as_str()) > width.saturating_sub(4)
}

fn context_path_display_name(path: &Path) -> String {
    // Shared leaf extraction with triage-core; fall back to the full path when
    // there's no final component (e.g. `/`) so the row is never blank.
    path_leaf_name(path).unwrap_or_else(|| path.display().to_string())
}

fn draw_terminal(
    frame: &mut ratatui::Frame<'_>,
    area: Rect,
    view: &SessionView,
    selection: Option<TerminalSelection>,
) {
    let visible_height = usize::from(area.height);
    let start = view
        .snapshot
        .visible_rows
        .len()
        .saturating_sub(visible_height)
        .saturating_sub(view.scroll_offset);
    let end = start
        .saturating_add(visible_height)
        .min(view.snapshot.visible_rows.len());
    let render_cols = terminal_render_cols(area);
    let selection = selection
        .filter(|selection| selection.is_active())
        .map(|selection| selection.to_visible_range(start));
    let rows = if let Some(selection) = selection {
        if let Some(styled_rows) = styled_rows_for_visible_range(&view.snapshot, start, end) {
            styled_selected_rows_to_lines(styled_rows, render_cols, start, selection)
        } else {
            selected_rows_to_lines(
                &view.snapshot.visible_rows[start..end],
                render_cols,
                start,
                selection,
            )
        }
    } else if let Some(styled_rows) = styled_rows_for_visible_range(&view.snapshot, start, end) {
        styled_rows_to_lines(styled_rows, render_cols)
    } else {
        view.snapshot.visible_rows[start..end]
            .iter()
            .map(|row| Line::from(row.as_str()))
            .collect::<Vec<_>>()
    };

    frame.render_widget(Paragraph::new(rows), area);
    if let Some(position) = terminal_cursor_position(area, start, &view.snapshot.cursor) {
        frame.set_cursor_position(position);
    }
}

fn terminal_render_cols(area: Rect) -> usize {
    usize::from(area.width)
}

fn terminal_cursor_position(
    area: Rect,
    start_row: usize,
    cursor: &TerminalCursor,
) -> Option<Position> {
    if !cursor.visible || cursor.row < start_row {
        return None;
    }

    let inner_width = usize::from(area.width);
    let inner_height = usize::from(area.height);
    let row = cursor.row - start_row;
    if cursor.col >= inner_width || row >= inner_height {
        return None;
    }

    Some(Position::new(
        area.x + u16::try_from(cursor.col).ok()?,
        area.y + u16::try_from(row).ok()?,
    ))
}

fn terminal_page_scroll_lines(area: Rect) -> isize {
    isize::try_from(area.height.saturating_sub(1).max(1)).unwrap_or(1)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TerminalSelection {
    start: TerminalPoint,
    end: TerminalPoint,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TerminalPoint {
    col: usize,
    row: usize,
}

impl TerminalSelection {
    fn new(point: TerminalPoint) -> Self {
        Self {
            start: point,
            end: point,
        }
    }

    fn update(&mut self, point: TerminalPoint) {
        self.end = point;
    }

    fn is_active(self) -> bool {
        self.start != self.end
    }

    fn to_visible_range(self, first_visible_row: usize) -> VisibleSelection {
        let (start, end) = ordered_terminal_points(self.start, self.end);
        VisibleSelection {
            start: TerminalPoint {
                col: start.col,
                row: first_visible_row + start.row,
            },
            end: TerminalPoint {
                col: end.col,
                row: first_visible_row + end.row,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct VisibleSelection {
    start: TerminalPoint,
    end: TerminalPoint,
}

fn handle_mouse_event(
    mouse: MouseEvent,
    terminal_area: Rect,
    app: &mut LocalSessionApp,
    selection: &mut Option<TerminalSelection>,
    output: &mut CrosstermBackend<Stdout>,
) -> Result<bool> {
    match mouse.kind {
        MouseEventKind::ScrollUp
            if terminal_area_contains(terminal_area, mouse.column, mouse.row) =>
        {
            *selection = None;
            app.scroll_selected(3);
            Ok(true)
        }
        MouseEventKind::ScrollDown
            if terminal_area_contains(terminal_area, mouse.column, mouse.row) =>
        {
            *selection = None;
            app.scroll_selected(-3);
            Ok(true)
        }
        MouseEventKind::Down(MouseButton::Left) => {
            if !terminal_area_contains(terminal_area, mouse.column, mouse.row) {
                return Ok(false);
            }
            let Some(point) = terminal_point_from_mouse(terminal_area, mouse) else {
                return Ok(false);
            };
            *selection = Some(TerminalSelection::new(point));
            Ok(true)
        }
        MouseEventKind::Drag(MouseButton::Left) => {
            if selection.is_none()
                && !terminal_area_contains(terminal_area, mouse.column, mouse.row)
            {
                return Ok(false);
            }
            let Some(point) = terminal_point_from_mouse(terminal_area, mouse) else {
                return Ok(false);
            };
            if let Some(selection) = selection {
                selection.update(point);
            } else {
                *selection = Some(TerminalSelection::new(point));
            }
            Ok(true)
        }
        MouseEventKind::Up(MouseButton::Left) => {
            let Some(mut selected) = *selection else {
                return Ok(false);
            };
            if let Some(point) = terminal_point_from_mouse(terminal_area, mouse) {
                selected.update(point);
                *selection = Some(selected);
            }
            if !selected.is_active() {
                *selection = None;
                return Ok(true);
            }
            let text = selected_text(app.view(), terminal_area, selected);
            if !text.trim().is_empty() {
                write_osc52_clipboard(output, &text)?;
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}

fn terminal_area_contains(area: Rect, col: u16, row: u16) -> bool {
    col >= area.x
        && row >= area.y
        && col < area.x.saturating_add(area.width)
        && row < area.y.saturating_add(area.height)
}

fn terminal_point_from_mouse(area: Rect, mouse: MouseEvent) -> Option<TerminalPoint> {
    if area.width == 0 || area.height == 0 {
        return None;
    }

    let max_col = area.x.saturating_add(area.width.saturating_sub(1));
    let max_row = area.y.saturating_add(area.height.saturating_sub(1));
    let col = mouse.column.clamp(area.x, max_col).saturating_sub(area.x);
    let row = mouse.row.clamp(area.y, max_row).saturating_sub(area.y);

    Some(TerminalPoint {
        col: usize::from(col),
        row: usize::from(row),
    })
}

fn selected_text(view: &SessionView, area: Rect, selection: TerminalSelection) -> String {
    let visible_height = usize::from(area.height);
    let first_visible_row = view
        .snapshot
        .visible_rows
        .len()
        .saturating_sub(visible_height)
        .saturating_sub(view.scroll_offset);
    let selection = selection.to_visible_range(first_visible_row);

    view.snapshot
        .visible_rows
        .iter()
        .enumerate()
        .skip(selection.start.row)
        .take(selection.end.row.saturating_sub(selection.start.row) + 1)
        .filter_map(|(row_index, row)| selected_row_text(row, row_index, selection))
        .collect::<Vec<_>>()
        .join("\n")
}

fn copy_selection_on_control_c(
    key: KeyEvent,
    view: &SessionView,
    area: Rect,
    selection: &mut Option<TerminalSelection>,
    output: &mut CrosstermBackend<Stdout>,
) -> Result<bool> {
    if !is_control_c(key) {
        return Ok(false);
    }

    let Some(selected) = *selection else {
        return Ok(false);
    };
    if !selected.is_active() {
        *selection = None;
        return Ok(false);
    }

    let text = selected_text(view, area, selected);
    if !text.trim().is_empty() {
        write_osc52_clipboard(output, &text)?;
    }
    *selection = None;
    Ok(true)
}

fn styled_rows_for_visible_range(
    snapshot: &triage_core::session::SessionSnapshot,
    start: usize,
    end: usize,
) -> Option<&[StyledRow]> {
    let styled_start = snapshot.styled_rows_start;
    let styled_end = styled_start.checked_add(snapshot.styled_rows.len())?;
    if start < styled_start || end > styled_end {
        return None;
    }

    let styled_rows = &snapshot.styled_rows[start - styled_start..end - styled_start];
    let visible_rows = snapshot.visible_rows.get(start..end)?;
    styled_rows_match_visible_text(styled_rows, visible_rows).then_some(styled_rows)
}

fn selected_rows_to_lines(
    rows: &[String],
    cols: usize,
    first_visible_row: usize,
    selection: VisibleSelection,
) -> Vec<Line<'static>> {
    rows.iter()
        .enumerate()
        .map(|(index, row)| {
            let visible_row_index = first_visible_row + index;
            selected_row_to_line(row, cols, visible_row_index, selection)
        })
        .collect()
}

fn selected_row_to_line(
    row: &str,
    cols: usize,
    row_index: usize,
    selection: VisibleSelection,
) -> Line<'static> {
    let Some((start, end)) = selected_row_bounds(row, row_index, selection) else {
        return Line::from(row.to_string());
    };

    let padded = pad_to_cols(row, cols);
    let before = slice_chars(&padded, 0, start);
    let selected = slice_chars(&padded, start, end);
    let after = slice_chars(&padded, end, padded.chars().count());
    Line::from(vec![
        Span::raw(before),
        Span::styled(selected, Style::default().add_modifier(Modifier::REVERSED)),
        Span::raw(after),
    ])
}

fn selected_row_text(row: &str, row_index: usize, selection: VisibleSelection) -> Option<String> {
    let (start, end) = selected_row_bounds(row, row_index, selection)?;
    Some(slice_chars(row, start, end.min(row.chars().count())))
}

fn selected_row_bounds(
    row: &str,
    row_index: usize,
    selection: VisibleSelection,
) -> Option<(usize, usize)> {
    selected_row_bounds_for_width(row.chars().count(), row_index, selection)
}

fn selected_row_bounds_for_width(
    row_width: usize,
    row_index: usize,
    selection: VisibleSelection,
) -> Option<(usize, usize)> {
    if row_index < selection.start.row || row_index > selection.end.row {
        return None;
    }

    let start = if row_index == selection.start.row {
        selection.start.col
    } else {
        0
    };
    let end = if row_index == selection.end.row {
        selection.end.col.saturating_add(1)
    } else {
        row_width
    };

    if start >= end {
        None
    } else {
        Some((start, end))
    }
}

fn ordered_terminal_points(
    start: TerminalPoint,
    end: TerminalPoint,
) -> (TerminalPoint, TerminalPoint) {
    if (end.row, end.col) < (start.row, start.col) {
        (end, start)
    } else {
        (start, end)
    }
}

fn pad_to_cols(row: &str, cols: usize) -> String {
    let width = row.chars().count();
    if width >= cols {
        row.to_string()
    } else {
        format!("{row}{}", " ".repeat(cols - width))
    }
}

fn slice_chars(value: &str, start: usize, end: usize) -> String {
    value
        .chars()
        .skip(start)
        .take(end.saturating_sub(start))
        .collect()
}

fn write_osc52_clipboard(output: &mut CrosstermBackend<Stdout>, text: &str) -> Result<()> {
    use std::io::Write;

    #[cfg(target_os = "macos")]
    {
        use std::process::{Command, Stdio};
        if let Ok(mut child) = Command::new("/usr/bin/pbcopy")
            .stdin(Stdio::piped())
            .spawn()
        {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(text.as_bytes());
            }
            let _ = child.wait();
        }
    }

    write!(
        output,
        "\x1b]52;c;{}\x07",
        base64::engine::general_purpose::STANDARD.encode(text.as_bytes())
    )
    .context("writing terminal clipboard selection")?;
    output
        .flush()
        .context("flushing terminal clipboard selection")
}

fn styled_rows_to_lines(rows: &[StyledRow], cols: usize) -> Vec<Line<'static>> {
    rows.iter()
        .map(|row| styled_row_to_line(row, cols))
        .collect()
}

fn styled_selected_rows_to_lines(
    rows: &[StyledRow],
    cols: usize,
    first_visible_row: usize,
    selection: VisibleSelection,
) -> Vec<Line<'static>> {
    rows.iter()
        .enumerate()
        .map(|(index, row)| {
            let visible_row_index = first_visible_row + index;
            styled_selected_row_to_line(row, cols, visible_row_index, selection)
        })
        .collect()
}

fn trailing_cell_style(row: &StyledRow) -> Style {
    row.spans
        .last()
        .filter(|span| span.style.background.is_some() || span.style.reverse)
        .map(|span| ratatui_style(&span.style))
        .unwrap_or_default()
}

fn styled_row_to_line(row: &StyledRow, cols: usize) -> Line<'static> {
    let mut width = 0;
    let mut spans = row
        .spans
        .iter()
        .map(|span| {
            width += span.text.chars().count();
            Span::styled(span.text.clone(), ratatui_style(&span.style))
        })
        .collect::<Vec<_>>();
    if let Some(last_span) = row.spans.last()
        && (last_span.style.background.is_some() || last_span.style.reverse)
        && width < cols
    {
        spans.push(Span::styled(
            " ".repeat(cols - width),
            ratatui_style(&last_span.style),
        ));
    }
    Line::from(spans)
}

fn styled_selected_row_to_line(
    row: &StyledRow,
    cols: usize,
    row_index: usize,
    selection: VisibleSelection,
) -> Line<'static> {
    let row_width = row.spans.iter().map(|span| span.text.chars().count()).sum();
    let Some((start, end)) = selected_row_bounds_for_width(row_width, row_index, selection) else {
        return styled_row_to_line(row, cols);
    };

    let mut spans = Vec::new();
    let mut offset = 0;
    for span in &row.spans {
        let style = ratatui_style(&span.style);
        push_selected_styled_segments(&mut spans, &span.text, style, offset, start, end);
        offset += span.text.chars().count();
    }

    if offset < cols {
        push_selected_styled_segments(
            &mut spans,
            &" ".repeat(cols - offset),
            trailing_cell_style(row),
            offset,
            start,
            end,
        );
    }

    Line::from(spans)
}

fn push_selected_styled_segments(
    spans: &mut Vec<Span<'static>>,
    text: &str,
    style: Style,
    offset: usize,
    selection_start: usize,
    selection_end: usize,
) {
    let width = text.chars().count();
    if width == 0 {
        return;
    }
    let segment_start = offset;
    let segment_end = offset + width;
    let selected_start = selection_start.clamp(segment_start, segment_end) - segment_start;
    let selected_end = selection_end.clamp(segment_start, segment_end) - segment_start;

    if selected_start > 0 {
        spans.push(Span::styled(slice_chars(text, 0, selected_start), style));
    }
    if selected_start < selected_end {
        spans.push(Span::styled(
            slice_chars(text, selected_start, selected_end),
            style.add_modifier(Modifier::REVERSED),
        ));
    }
    if selected_end < width {
        spans.push(Span::styled(slice_chars(text, selected_end, width), style));
    }
}

fn ratatui_style(style: &TerminalStyle) -> Style {
    let mut output = Style::default();
    if let Some(color) = style.foreground {
        output = output.fg(ratatui_color(color));
    }
    if let Some(color) = style.background {
        output = output.bg(ratatui_color(color));
    }
    if style.bold {
        output = output.add_modifier(Modifier::BOLD);
    }
    if style.dim {
        output = output.add_modifier(Modifier::DIM);
    }
    if style.italic {
        output = output.add_modifier(Modifier::ITALIC);
    }
    if style.underline {
        output = output.add_modifier(Modifier::UNDERLINED);
    }
    if style.reverse {
        output = output.add_modifier(Modifier::REVERSED);
    }
    output
}

fn ratatui_color(color: TerminalColor) -> Color {
    Color::Rgb(color.red, color.green, color.blue)
}

fn draw_status(
    frame: &mut ratatui::Frame<'_>,
    area: Rect,
    view: &SessionView,
    last_error: Option<&str>,
    pending_confirmation: Option<Confirmation>,
) {
    let status = if let Some(error) = last_error {
        Line::from(vec![
            Span::styled("error ", Style::default().fg(Color::Red)),
            Span::raw(error),
        ])
    } else if let Some(confirmation) = pending_confirmation {
        Line::from(Span::styled(
            confirmation.message(),
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        ))
    } else {
        Line::from(format!(
            "seq {}  bytes {}  PgUp/PgDn scroll  Ctrl-N new  Ctrl-W close  F2 tabs  Alt/Ctrl-Alt arrows, F3/F4 switch  Ctrl-Q exit",
            view.snapshot.output_seq, view.snapshot.bytes_logged
        ))
    };
    frame.render_widget(Paragraph::new(status), area);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Confirmation {
    CloseSession,
    Exit,
}

impl Confirmation {
    fn message(self) -> &'static str {
        match self {
            Confirmation::CloseSession => "press Ctrl-W again to close this terminal",
            Confirmation::Exit => "press Ctrl-Q again to exit and close all embedded terminals",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AppCommand {
    New,
    Close,
    Next,
    Previous,
    ToggleSidebar,
    ScrollUp,
    ScrollDown,
}

fn key_to_command(key: KeyEvent) -> Option<AppCommand> {
    match key.code {
        KeyCode::Char('n') | KeyCode::Char('N')
            if key.modifiers.contains(KeyModifiers::CONTROL) =>
        {
            Some(AppCommand::New)
        }
        KeyCode::Char('w') | KeyCode::Char('W')
            if key.modifiers.contains(KeyModifiers::CONTROL) =>
        {
            Some(AppCommand::Close)
        }
        KeyCode::Down | KeyCode::Right if key.modifiers.contains(KeyModifiers::ALT) => {
            Some(AppCommand::Next)
        }
        KeyCode::Up | KeyCode::Left if key.modifiers.contains(KeyModifiers::ALT) => {
            Some(AppCommand::Previous)
        }
        KeyCode::F(2) => Some(AppCommand::ToggleSidebar),
        KeyCode::F(3) => Some(AppCommand::Next),
        KeyCode::F(4) => Some(AppCommand::Previous),
        KeyCode::PageUp => Some(AppCommand::ScrollUp),
        KeyCode::PageDown => Some(AppCommand::ScrollDown),
        _ => None,
    }
}

fn should_exit(key: KeyEvent) -> bool {
    key.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(key.code, KeyCode::Char('q') | KeyCode::Char('Q'))
}

fn is_control_c(key: KeyEvent) -> bool {
    key.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(key.code, KeyCode::Char('c') | KeyCode::Char('C'))
}

fn key_to_input(key: KeyEvent) -> Option<Vec<u8>> {
    match key.code {
        KeyCode::Char(character) if key.modifiers.contains(KeyModifiers::CONTROL) => {
            control_byte(character).map(|byte| vec![byte])
        }
        KeyCode::Char(character) => Some(character.to_string().into_bytes()),
        KeyCode::Enter => Some(b"\r".to_vec()),
        KeyCode::Backspace => Some(vec![0x7f]),
        KeyCode::Tab if key.modifiers.contains(KeyModifiers::SHIFT) => Some(b"\x1b[Z".to_vec()),
        KeyCode::BackTab => Some(b"\x1b[Z".to_vec()),
        KeyCode::Tab => Some(b"\t".to_vec()),
        KeyCode::Left => Some(b"\x1b[D".to_vec()),
        KeyCode::Right => Some(b"\x1b[C".to_vec()),
        KeyCode::Up => Some(b"\x1b[A".to_vec()),
        KeyCode::Down => Some(b"\x1b[B".to_vec()),
        KeyCode::Home => Some(b"\x1b[H".to_vec()),
        KeyCode::End => Some(b"\x1b[F".to_vec()),
        KeyCode::Delete => Some(b"\x1b[3~".to_vec()),
        KeyCode::Esc => Some(b"\x1b".to_vec()),
        _ => None,
    }
}

fn paste_input(text: &str, bracketed_paste_enabled: bool) -> Vec<u8> {
    if !bracketed_paste_enabled {
        return text.as_bytes().to_vec();
    }

    let sanitized = text.replace("\x1b[201~", "");
    let mut bytes = Vec::with_capacity(b"\x1b[200~".len() + sanitized.len() + b"\x1b[201~".len());
    bytes.extend_from_slice(b"\x1b[200~");
    bytes.extend_from_slice(sanitized.as_bytes());
    bytes.extend_from_slice(b"\x1b[201~");
    bytes
}

fn control_byte(character: char) -> Option<u8> {
    let upper = character.to_ascii_uppercase();
    if upper.is_ascii_alphabetic() {
        Some((upper as u8) - b'A' + 1)
    } else {
        None
    }
}

fn initial_session_size() -> Result<SessionSize> {
    current_session_size(true)
}

fn current_session_size(sidebar_visible: bool) -> Result<SessionSize> {
    let (cols, rows) = crossterm::terminal::size()?;
    Ok(session_size_from_app_terminal(rows, cols, sidebar_visible))
}

fn session_size_from_app_terminal(rows: u16, cols: u16, sidebar_visible: bool) -> SessionSize {
    let horizontal_chrome = if sidebar_visible { SIDEBAR_COLS } else { 0 };
    session_size_from_terminal(
        rows.saturating_sub(1),
        cols.saturating_sub(horizontal_chrome),
    )
}

struct TerminalSession {
    terminal: Terminal<CrosstermBackend<Stdout>>,
    restored: bool,
}

impl TerminalSession {
    fn enter() -> Result<Self> {
        enable_raw_mode()?;
        let mut stdout = io::stdout();
        execute!(
            stdout,
            EnterAlternateScreen,
            EnableMouseCapture,
            EnableBracketedPaste
        )?;
        let backend = CrosstermBackend::new(stdout);
        let mut terminal = Terminal::new(backend)?;
        terminal.clear()?;

        Ok(Self {
            terminal,
            restored: false,
        })
    }

    fn restore(&mut self) -> Result<()> {
        if self.restored {
            return Ok(());
        }

        disable_raw_mode()?;
        execute!(
            self.terminal.backend_mut(),
            DisableBracketedPaste,
            DisableMouseCapture,
            LeaveAlternateScreen
        )?;
        self.terminal.show_cursor()?;
        self.restored = true;
        Ok(())
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use triage_core::session::{StyledSpan, TerminalStyle};

    #[test]
    fn truncate_to_width_measures_terminal_cell_width() {
        // ASCII: one cell per char, behaves like the char-count path.
        assert_eq!(truncate_to_width("abcdef".to_string(), 4), "abc~");
        assert_eq!(truncate_to_width("abc".to_string(), 4), "abc");

        // Wide CJK glyphs occupy two cells each, so four of them already
        // exceed a 5-cell budget and must be truncated.
        let cjk = "字字字字";
        assert!(UnicodeWidthStr::width(cjk) > 5);
        let truncated = truncate_to_width(cjk.to_string(), 5);
        assert!(UnicodeWidthStr::width(truncated.as_str()) <= 5);
        assert_eq!(truncated, "字字~");
    }

    #[test]
    fn compact_value_keeps_head_and_tail_within_cell_width() {
        assert_eq!(compact_value("abcdefghij", 7), "abc~hij");

        let wide = "字字字字字字";
        let compacted = compact_value(wide, 7);
        assert!(UnicodeWidthStr::width(compacted.as_str()) <= 7);
        assert!(compacted.contains('~'));
    }

    #[test]
    fn context_path_overflows_uses_display_name_for_roots() {
        let root = Path::new("/");

        assert!(!context_path_overflows(root, 5));
        assert!(context_path_overflows(root, 4));
    }

    #[test]
    fn printable_keys_are_forwarded_to_session() {
        assert_eq!(
            key_to_input(KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)),
            Some(b"q".to_vec())
        );
        assert_eq!(
            key_to_input(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)),
            Some(b"\r".to_vec())
        );
        assert_eq!(
            key_to_input(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)),
            Some(b"\x1b".to_vec())
        );
        assert_eq!(
            key_to_input(KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)),
            Some(b"\t".to_vec())
        );
    }

    #[test]
    fn shift_tab_is_forwarded_as_reverse_tab() {
        assert_eq!(
            key_to_input(KeyEvent::new(KeyCode::BackTab, KeyModifiers::SHIFT)),
            Some(b"\x1b[Z".to_vec())
        );
        assert_eq!(
            key_to_input(KeyEvent::new(KeyCode::Tab, KeyModifiers::SHIFT)),
            Some(b"\x1b[Z".to_vec())
        );
    }

    #[test]
    fn local_exit_uses_control_q() {
        assert!(!should_exit(KeyEvent::new(
            KeyCode::Esc,
            KeyModifiers::NONE
        )));
        assert!(should_exit(KeyEvent::new(
            KeyCode::Char('q'),
            KeyModifiers::CONTROL,
        )));
        assert!(!should_exit(KeyEvent::new(
            KeyCode::Char('q'),
            KeyModifiers::NONE,
        )));
    }

    #[test]
    fn control_c_is_detected_for_selection_copy() {
        assert!(is_control_c(KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::CONTROL,
        )));
        assert!(is_control_c(KeyEvent::new(
            KeyCode::Char('C'),
            KeyModifiers::CONTROL,
        )));
        assert!(!is_control_c(KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::NONE,
        )));
    }

    #[test]
    fn reserved_control_keys_become_app_commands() {
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::CONTROL)),
            Some(AppCommand::New)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::Char('w'), KeyModifiers::CONTROL)),
            Some(AppCommand::Close)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::Down, KeyModifiers::ALT)),
            Some(AppCommand::Next)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::Up, KeyModifiers::ALT)),
            Some(AppCommand::Previous)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(
                KeyCode::Down,
                KeyModifiers::CONTROL | KeyModifiers::ALT
            )),
            Some(AppCommand::Next)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(
                KeyCode::Up,
                KeyModifiers::CONTROL | KeyModifiers::ALT
            )),
            Some(AppCommand::Previous)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::F(2), KeyModifiers::NONE)),
            Some(AppCommand::ToggleSidebar)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::F(3), KeyModifiers::NONE)),
            Some(AppCommand::Next)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::F(4), KeyModifiers::NONE)),
            Some(AppCommand::Previous)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::PageUp, KeyModifiers::NONE)),
            Some(AppCommand::ScrollUp)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::PageDown, KeyModifiers::NONE)),
            Some(AppCommand::ScrollDown)
        );
        assert_eq!(
            key_to_command(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)),
            None
        );
    }

    #[test]
    fn paste_input_preserves_raw_text_without_bracketed_paste_mode() {
        assert_eq!(
            paste_input("echo one\necho two", false),
            b"echo one\necho two"
        );
    }

    #[test]
    fn paste_input_preserves_bracketed_paste_boundaries_when_enabled() {
        assert_eq!(
            paste_input("echo one\necho two", true),
            b"\x1b[200~echo one\necho two\x1b[201~"
        );
    }

    #[test]
    fn paste_input_strips_embedded_bracketed_paste_end_marker() {
        assert_eq!(
            paste_input("safe\x1b[201~still pasted", true),
            b"\x1b[200~safestill pasted\x1b[201~"
        );
    }

    #[test]
    fn session_size_matches_terminal_pane_inner_area() {
        let size = session_size_from_app_terminal(24, 100, true);

        assert_eq!(size.rows, 23);
        assert_eq!(size.cols, 72);
    }

    #[test]
    fn session_size_expands_when_sidebar_is_hidden() {
        let size = session_size_from_app_terminal(24, 100, false);

        assert_eq!(size.rows, 23);
        assert_eq!(size.cols, 100);
    }

    #[test]
    fn sidebar_rows_include_git_session_context() {
        let view = SessionView {
            session_id: triage_core::session::SessionId::new("session-1").expect("session id"),
            snapshot: triage_core::session::SessionSnapshot {
                output_seq: 0,
                bytes_logged: 0,
                size: SessionSize::default(),
                visible_rows: Vec::new(),
                styled_rows_start: 0,
                styled_rows: Vec::new(),
                cursor: triage_core::session::TerminalCursor {
                    row: 0,
                    col: 0,
                    visible: false,
                },
                current_working_directory: Some(PathBuf::from("/workspace/triage/crates")),
                context: Some(triage_core::session::SessionContext {
                    repository_root: Some(PathBuf::from("/workspace/triage")),
                    worktree_root: Some(PathBuf::from(
                        "/workspace/triage/worktrees/websocket-session-api",
                    )),
                    branch: Some("feat/session-context".to_string()),
                }),
                bracketed_paste_enabled: false,
                exited: false,
                raw_output: Vec::new(),
                raw_output_start: 0,
                snippet: None,
                snippet_detail: None,
            },
            lease: triage_core::session::InputLeaseState::default(),
            last_completed: None,
            scroll_offset: 0,
        };

        let rows =
            session_sidebar_rows(0, 1, &view, usize::from(SIDEBAR_COLS.saturating_sub(1)), 0);

        assert_eq!(rows[2].spans[0].content.as_ref(), "  r triage");
        assert_eq!(
            rows[3].spans[0].content.as_ref(),
            "  w websocket-session-api"
        );
        assert_eq!(rows[4].spans[0].content.as_ref(), "  b session-context");
    }

    #[test]
    fn selected_sidebar_context_scrolls_overflowing_branch_text() {
        let view = SessionView {
            session_id: triage_core::session::SessionId::new("session-1").expect("session id"),
            snapshot: triage_core::session::SessionSnapshot {
                output_seq: 0,
                bytes_logged: 0,
                size: SessionSize::default(),
                visible_rows: Vec::new(),
                styled_rows_start: 0,
                styled_rows: Vec::new(),
                cursor: triage_core::session::TerminalCursor {
                    row: 0,
                    col: 0,
                    visible: false,
                },
                current_working_directory: Some(PathBuf::from("/workspace/triage")),
                context: Some(triage_core::session::SessionContext {
                    repository_root: Some(PathBuf::from("/workspace/triage")),
                    worktree_root: Some(PathBuf::from("/workspace/triage")),
                    branch: Some("feat/very-long-session-context-label".to_string()),
                }),
                bracketed_paste_enabled: false,
                exited: false,
                raw_output: Vec::new(),
                raw_output_start: 0,
                snippet: None,
                snippet_detail: None,
            },
            lease: triage_core::session::InputLeaseState::default(),
            last_completed: None,
            scroll_offset: 0,
        };

        let first = session_sidebar_rows(0, 0, &view, 20, 0);
        let later = session_sidebar_rows(0, 0, &view, 20, 5);

        assert_ne!(first[3].spans[0].content, later[3].spans[0].content);
        assert!(first[3].spans[0].content.starts_with("  b "));
        assert_eq!(first[3].width(), 20);
        assert_eq!(later[3].width(), 20);
    }

    #[test]
    fn selected_sidebar_context_overflows_when_worktree_name_overflows() {
        let view = SessionView {
            session_id: triage_core::session::SessionId::new("session-1").expect("session id"),
            snapshot: triage_core::session::SessionSnapshot {
                output_seq: 0,
                bytes_logged: 0,
                size: SessionSize::default(),
                visible_rows: Vec::new(),
                styled_rows_start: 0,
                styled_rows: Vec::new(),
                cursor: triage_core::session::TerminalCursor {
                    row: 0,
                    col: 0,
                    visible: false,
                },
                current_working_directory: Some(PathBuf::from(
                    "/workspace/triage/worktrees/websocket-session-api",
                )),
                context: Some(triage_core::session::SessionContext {
                    repository_root: Some(PathBuf::from("/workspace/triage")),
                    worktree_root: Some(PathBuf::from(
                        "/workspace/triage/worktrees/very-long-websocket-session-api",
                    )),
                    branch: Some("feat/ws".to_string()),
                }),
                bracketed_paste_enabled: false,
                exited: false,
                raw_output: Vec::new(),
                raw_output_start: 0,
                snippet: None,
                snippet_detail: None,
            },
            lease: triage_core::session::InputLeaseState::default(),
            last_completed: None,
            scroll_offset: 0,
        };

        assert!(session_context_overflows(&view, 20));
    }

    #[test]
    fn sidebar_visible_rows_keep_selected_session_in_view() {
        let sessions = (1..=4)
            .map(|index| sidebar_test_view(&format!("session-{index}")))
            .collect::<Vec<_>>();

        let rows = sidebar_visible_rows(sessions.iter(), 3, 20, 0, 5);

        assert_eq!(rows.len(), 5);
        assert_eq!(rows[0].spans[0].content.as_ref(), "> session-4  running");
        assert_eq!(rows[1].spans[0].content.as_ref(), "  observer  80x24");
    }

    #[test]
    fn sidebar_viewport_start_keeps_selected_group_visible_when_pane_has_slack() {
        assert_eq!(sidebar_viewport_start(20, 15, 20, 6), 14);
    }

    #[test]
    fn sidebar_viewport_start_anchors_oversized_selected_group_at_top() {
        assert_eq!(sidebar_viewport_start(20, 8, 16, 5), 8);
    }

    #[test]
    fn terminal_selection_extracts_only_visible_terminal_text() {
        let view = SessionView {
            session_id: triage_core::session::SessionId::new("session-1").expect("session id"),
            snapshot: triage_core::session::SessionSnapshot {
                output_seq: 0,
                bytes_logged: 0,
                size: SessionSize::default(),
                visible_rows: vec![
                    "ignored".to_string(),
                    "alpha beta".to_string(),
                    "gamma delta".to_string(),
                ],
                styled_rows_start: 0,
                styled_rows: Vec::new(),
                cursor: triage_core::session::TerminalCursor {
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
                snippet: None,
                snippet_detail: None,
            },
            lease: triage_core::session::InputLeaseState::default(),
            last_completed: None,
            scroll_offset: 0,
        };
        let area = Rect {
            x: 28,
            y: 0,
            width: 20,
            height: 2,
        };
        let selection = TerminalSelection {
            start: TerminalPoint { col: 2, row: 0 },
            end: TerminalPoint { col: 4, row: 1 },
        };

        assert_eq!(selected_text(&view, area, selection), "pha beta\ngamma");
    }

    #[test]
    fn terminal_selection_preserves_selected_trailing_spaces() {
        let view = SessionView {
            session_id: triage_core::session::SessionId::new("session-1").expect("session id"),
            snapshot: triage_core::session::SessionSnapshot {
                output_seq: 0,
                bytes_logged: 0,
                size: SessionSize::default(),
                visible_rows: vec!["cmd   ".to_string(), "next".to_string()],
                styled_rows_start: 0,
                styled_rows: Vec::new(),
                cursor: triage_core::session::TerminalCursor {
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
                snippet: None,
                snippet_detail: None,
            },
            lease: triage_core::session::InputLeaseState::default(),
            last_completed: None,
            scroll_offset: 0,
        };
        let area = Rect {
            x: SIDEBAR_COLS,
            y: 0,
            width: 20,
            height: 2,
        };
        let selection = TerminalSelection {
            start: TerminalPoint { col: 0, row: 0 },
            end: TerminalPoint { col: 1, row: 1 },
        };

        assert_eq!(selected_text(&view, area, selection), "cmd   \nne");
    }

    #[test]
    fn terminal_selection_middle_rows_stop_at_row_text() {
        let row_index = 1;
        let selection = VisibleSelection {
            start: TerminalPoint { col: 2, row: 0 },
            end: TerminalPoint { col: 8, row: 2 },
        };

        assert_eq!(
            selected_row_bounds("abc", row_index, selection),
            Some((0, 3))
        );
    }

    #[test]
    fn terminal_selection_is_active_only_after_dragging() {
        let mut selection = TerminalSelection::new(TerminalPoint { col: 4, row: 2 });

        assert!(!selection.is_active());

        selection.update(TerminalPoint { col: 4, row: 2 });
        assert!(!selection.is_active());

        selection.update(TerminalPoint { col: 5, row: 2 });
        assert!(selection.is_active());
    }

    #[test]
    fn terminal_point_clamps_to_terminal_pane() {
        let area = Rect {
            x: 28,
            y: 1,
            width: 10,
            height: 4,
        };
        let point = terminal_point_from_mouse(
            area,
            MouseEvent {
                kind: MouseEventKind::Drag(MouseButton::Left),
                column: 3,
                row: 99,
                modifiers: KeyModifiers::NONE,
            },
        )
        .expect("terminal point");

        assert_eq!(point, TerminalPoint { col: 0, row: 3 });
    }

    #[test]
    fn terminal_render_cols_expands_to_terminal_pane_width() {
        let area = Rect::new(0, 0, 102, 24);

        assert_eq!(terminal_render_cols(area), 102);
    }

    #[test]
    fn terminal_render_cols_uses_terminal_pane_width_when_snapshot_is_wider() {
        let area = Rect::new(0, 0, 72, 24);

        assert_eq!(terminal_render_cols(area), 72);
    }

    #[test]
    fn styled_row_pads_trailing_background_to_session_width() {
        let row = StyledRow {
            spans: vec![StyledSpan {
                text: "input".to_string(),
                style: TerminalStyle {
                    background: Some(TerminalColor {
                        red: 10,
                        green: 20,
                        blue: 30,
                    }),
                    ..TerminalStyle::default()
                },
            }],
        };

        let line = styled_row_to_line(&row, 8);

        assert_eq!(line.width(), 8);
        // The trailing background must be carried by explicit spans only, never
        // by a line-wide base style: a line-wide background bleeds onto leading
        // cells whose own style has no background (regression seen as a grey
        // wash over Claude Code's input box).
        assert!(line.style.bg.is_none());
        assert_eq!(line.spans.len(), 2);
        assert!(line.spans[0].style.bg.is_some());
        assert_eq!(line.spans[1].content.as_ref(), "   ");
        assert!(line.spans[1].style.bg.is_some());
    }

    #[test]
    fn styled_selected_row_pads_trailing_background_without_line_style() {
        let row = StyledRow {
            spans: vec![StyledSpan {
                text: "input".to_string(),
                style: TerminalStyle {
                    background: Some(TerminalColor {
                        red: 10,
                        green: 20,
                        blue: 30,
                    }),
                    ..TerminalStyle::default()
                },
            }],
        };

        let line = styled_selected_row_to_line(
            &row,
            8,
            0,
            VisibleSelection {
                start: TerminalPoint { col: 1, row: 0 },
                end: TerminalPoint { col: 3, row: 0 },
            },
        );

        assert_eq!(line.width(), 8);
        assert!(line.style.bg.is_none());
        assert_eq!(
            line.spans.last().expect("trailing span").content.as_ref(),
            "   "
        );
        assert!(line.spans.last().expect("trailing span").style.bg.is_some());
    }

    #[test]
    fn styled_rows_preserve_blank_rows() {
        let rows = vec![
            StyledRow {
                spans: vec![StyledSpan {
                    text: "top".to_string(),
                    style: TerminalStyle::default(),
                }],
            },
            StyledRow { spans: Vec::new() },
            StyledRow {
                spans: vec![StyledSpan {
                    text: "bottom".to_string(),
                    style: TerminalStyle::default(),
                }],
            },
        ];

        let lines = styled_rows_to_lines(&rows, 8);

        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0].spans[0].content.as_ref(), "top");
        assert!(lines[1].spans.is_empty());
        assert_eq!(lines[2].spans[0].content.as_ref(), "bottom");
    }

    #[test]
    fn styled_selection_preserves_span_colors() {
        let red = TerminalColor {
            red: 200,
            green: 10,
            blue: 10,
        };
        let blue = TerminalColor {
            red: 10,
            green: 40,
            blue: 220,
        };
        let row = StyledRow {
            spans: vec![
                StyledSpan {
                    text: "red".to_string(),
                    style: TerminalStyle {
                        foreground: Some(red),
                        background: Some(TerminalColor {
                            red: 20,
                            green: 20,
                            blue: 20,
                        }),
                        ..TerminalStyle::default()
                    },
                },
                StyledSpan {
                    text: "green".to_string(),
                    style: TerminalStyle {
                        foreground: Some(blue),
                        ..TerminalStyle::default()
                    },
                },
            ],
        };

        let line = styled_selected_row_to_line(
            &row,
            8,
            0,
            VisibleSelection {
                start: TerminalPoint { col: 1, row: 0 },
                end: TerminalPoint { col: 4, row: 0 },
            },
        );

        assert_eq!(line.spans[0].content.as_ref(), "r");
        assert_eq!(line.spans[1].content.as_ref(), "ed");
        assert_eq!(line.spans[2].content.as_ref(), "gr");
        assert_eq!(line.spans[3].content.as_ref(), "een");
        assert_eq!(line.spans[1].style.fg, Some(ratatui_color(red)));
        assert!(line.spans[1].style.bg.is_some());
        assert_eq!(line.spans[2].style.fg, Some(ratatui_color(blue)));
        assert!(
            line.spans[1]
                .style
                .add_modifier
                .contains(Modifier::REVERSED)
        );
        assert!(
            line.spans[2]
                .style
                .add_modifier
                .contains(Modifier::REVERSED)
        );
    }

    #[test]
    fn styled_rows_are_selected_from_full_snapshot_range() {
        let snapshot = triage_core::session::SessionSnapshot {
            output_seq: 0,
            bytes_logged: 0,
            size: SessionSize::default(),
            visible_rows: vec![
                "history".to_string(),
                "visible-1".to_string(),
                "visible-2".to_string(),
            ],
            styled_rows_start: 0,
            styled_rows: vec![
                StyledRow {
                    spans: vec![StyledSpan {
                        text: "history".to_string(),
                        style: TerminalStyle::default(),
                    }],
                },
                StyledRow {
                    spans: vec![StyledSpan {
                        text: "visible-1".to_string(),
                        style: TerminalStyle::default(),
                    }],
                },
                StyledRow {
                    spans: vec![StyledSpan {
                        text: "visible-2".to_string(),
                        style: TerminalStyle::default(),
                    }],
                },
            ],
            cursor: TerminalCursor {
                row: 2,
                col: 0,
                visible: true,
            },
            current_working_directory: None,
            context: None,
            bracketed_paste_enabled: false,
            exited: false,
            raw_output: Vec::new(),
            raw_output_start: 0,
            snippet: None,
            snippet_detail: None,
        };

        assert!(styled_rows_for_visible_range(&snapshot, 0, 2).is_some());
        assert!(styled_rows_for_visible_range(&snapshot, 1, 3).is_some());
    }

    #[test]
    fn stale_styled_rows_are_rejected_when_text_no_longer_matches_visible_rows() {
        let snapshot = triage_core::session::SessionSnapshot {
            output_seq: 0,
            bytes_logged: 0,
            size: SessionSize::default(),
            visible_rows: vec!["".to_string()],
            styled_rows_start: 0,
            styled_rows: vec![StyledRow {
                spans: vec![StyledSpan {
                    text: "submitted prompt".to_string(),
                    style: TerminalStyle::default(),
                }],
            }],
            cursor: TerminalCursor {
                row: 0,
                col: 0,
                visible: true,
            },
            current_working_directory: None,
            context: None,
            bracketed_paste_enabled: false,
            exited: false,
            raw_output: Vec::new(),
            raw_output_start: 0,
            snippet: None,
            snippet_detail: None,
        };

        assert!(styled_rows_for_visible_range(&snapshot, 0, 1).is_none());
    }

    #[test]
    fn terminal_cursor_position_maps_visible_screen_to_terminal_area() {
        let area = Rect::new(10, 5, 82, 24);
        let cursor = TerminalCursor {
            row: 20,
            col: 7,
            visible: true,
        };

        assert_eq!(
            terminal_cursor_position(area, 3, &cursor),
            Some(Position::new(17, 22))
        );
    }

    #[test]
    fn dim_terminal_style_maps_to_ratatui_modifier() {
        let style = ratatui_style(&TerminalStyle {
            dim: true,
            ..TerminalStyle::default()
        });

        assert!(style.add_modifier.contains(Modifier::DIM));
    }

    fn sidebar_test_view(session_id: &str) -> SessionView {
        SessionView {
            session_id: triage_core::session::SessionId::new(session_id).expect("session id"),
            snapshot: triage_core::session::SessionSnapshot {
                output_seq: 0,
                bytes_logged: 0,
                size: SessionSize::default(),
                visible_rows: Vec::new(),
                styled_rows_start: 0,
                styled_rows: Vec::new(),
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
                snippet: None,
                snippet_detail: None,
            },
            lease: triage_core::session::InputLeaseState::default(),
            last_completed: None,
            scroll_offset: 0,
        }
    }

    #[test]
    fn terminal_cursor_position_hides_out_of_view_cursor() {
        let area = Rect::new(0, 0, 82, 24);
        let cursor = TerminalCursor {
            row: 2,
            col: 7,
            visible: true,
        };

        assert_eq!(terminal_cursor_position(area, 3, &cursor), None);
    }

    #[test]
    fn startup_mode_defaults_to_daemon_socket() {
        let startup_mode = StartupMode::from_args(Vec::<OsString>::new()).expect("startup mode");

        // Wherever the daemon's local IPC transport exists (Unix + Windows), a
        // bare `triage` defaults to attaching to the running daemon.
        #[cfg(any(unix, windows))]
        assert!(matches!(startup_mode, StartupMode::Daemon { .. }));
        #[cfg(not(any(unix, windows)))]
        assert_eq!(startup_mode, StartupMode::Embedded);
    }

    #[test]
    fn startup_mode_accepts_explicit_socket() {
        assert_eq!(
            StartupMode::from_args([
                OsString::from("--socket"),
                OsString::from("/tmp/triage.sock")
            ])
            .expect("startup mode"),
            StartupMode::Daemon {
                socket_path: PathBuf::from("/tmp/triage.sock")
            }
        );
    }

    #[test]
    fn startup_mode_accepts_explicit_embedded_mode() {
        assert_eq!(
            StartupMode::from_args([OsString::from("--embedded")]).expect("startup mode"),
            StartupMode::Embedded
        );
    }

    #[test]
    fn startup_mode_rejects_ambiguous_mode() {
        let error = StartupMode::from_args([
            OsString::from("--embedded"),
            OsString::from("--socket"),
            OsString::from("/tmp/triage.sock"),
        ])
        .expect_err("ambiguous mode should fail");

        assert!(error.to_string().contains("--embedded cannot be combined"));
    }

    #[test]
    fn startup_mode_rejects_reverse_ambiguous_mode() {
        let error = StartupMode::from_args([
            OsString::from("--socket"),
            OsString::from("/tmp/triage.sock"),
            OsString::from("--embedded"),
        ])
        .expect_err("ambiguous mode should fail");

        assert!(error.to_string().contains("--embedded cannot be combined"));
    }

    #[test]
    fn startup_mode_accepts_help() {
        assert_eq!(
            StartupMode::from_args([OsString::from("--help")]).expect("startup mode"),
            StartupMode::Help
        );
        assert_eq!(
            StartupMode::from_args([OsString::from("-h")]).expect("startup mode"),
            StartupMode::Help
        );
    }
}
