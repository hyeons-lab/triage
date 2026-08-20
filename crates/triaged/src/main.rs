#![cfg_attr(unix, allow(unsafe_code))]

use std::ffi::OsString;
use std::sync::Arc;
use triaged::session::SessionManager;
use triaged::ws;

#[cfg(any(unix, windows))]
use triaged::ipc::{IpcConfig, IpcServer, default_socket_path};

fn main() -> anyhow::Result<()> {
    #[cfg(unix)]
    if std::env::args_os().nth(1).as_deref()
        == Some(std::ffi::OsStr::new(triaged::session::PTY_CHILD_EXEC_ARG))
    {
        return exec_pty_child(std::env::args_os().skip(2));
    }

    // Arguments are parsed, and help/version answered, *before* logging is
    // initialized: `logging::init` resolves a state directory and fails when
    // neither HOME nor USERPROFILE is set, and `triaged --help` failing because
    // the log directory is unwritable would be absurd.
    let invocation = parse_args(std::env::args_os().skip(1))?;
    match invocation {
        Invocation::Help => {
            println!("{HELP}");
            return Ok(());
        }
        Invocation::Version => {
            println!("triaged {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Invocation::Reload => return triaged::service::reload_daemon(),
        Invocation::Service(_) | Invocation::Daemon { .. } => {}
    }

    // Before any handover work: make job control unable to stop us, and make a
    // terminating signal something we can answer rather than die on. Both are set up
    // here, ahead of the long startup, because from the moment this process adopts a
    // predecessor's sessions it owns PTYs that its death would destroy.
    #[cfg(unix)]
    ignore_terminal_job_control_signals();
    // Daemon invocations only. `triaged service <action>` is a short-lived CLI with
    // no rescue thread to consume the pipe, so installing the handler there would
    // turn Ctrl-C into a signal that is caught, queued, and never acted on.
    #[cfg(unix)]
    if matches!(invocation, Invocation::Daemon { .. }) {
        triaged::shutdown::install_signal_handlers();
    }

    // Keep this binding alive for the lifetime of the process: dropping the
    // WorkerGuard flushes the non-blocking tracing appender thread.
    let _flush_guard = triage_core::logging::init(triage_core::logging::default_config()?)?;

    // Start consuming those signals now, before the long startup work. Until
    // `arm_rescue` hands it a manager there is nothing to hand over, so it answers a
    // signal by exiting, exactly as the default disposition would have. That matters:
    // a caught signal with no consumer would make the daemon unstoppable for the
    // whole of startup.
    #[cfg(unix)]
    if matches!(invocation, Invocation::Daemon { .. }) {
        triaged::shutdown::spawn_rescue_thread();
    }

    run(invocation)
}

/// Stops the terminal job-control signals from ever suspending this process.
///
/// Handover teardown calls `tcsetattr`, and for a process in a *background*
/// process group that raises `SIGTTOU` unconditionally; TOSTOP does not gate it.
/// A daemon launched from an interactive shell (including from inside a Triage
/// session, the most natural place to test a build) is exactly such a process, so
/// it would stop itself partway through the swap, holding every PTY master, the
/// control socket and the TCP listener. Those sessions are then hostage: the
/// process cannot be killed without destroying them, and `SIGCONT` alone does not
/// help because it re-stops on the next `tcsetattr`.
///
/// Ignoring the signal makes the background `tcsetattr` proceed instead of
/// stopping us, which is what POSIX specifies for an ignored (or blocked)
/// `SIGTTOU`. `SIGTTIN` is ignored for the same reason on the read side; a daemon
/// has no business reading a terminal it merely inherited.
///
/// This does not detach the controlling terminal (no `setsid`), because a
/// successor adopted through a handover must keep serving the sessions it
/// inherited regardless of how it was launched. The goal is only that job
/// control can never freeze the owner of live PTYs.
#[cfg(unix)]
fn ignore_terminal_job_control_signals() {
    // SAFETY: `signal` with SIG_IGN carries no handler to run, so there is no
    // async-signal-safety obligation; the only effect is on this process's
    // disposition table. Errors are deliberately ignored: a failure here is not
    // worth refusing to start over, and the daemon simply keeps the default
    // behaviour it has always had.
    unsafe {
        libc::signal(libc::SIGTTOU, libc::SIG_IGN);
        libc::signal(libc::SIGTTIN, libc::SIG_IGN);
    }
    triaged::session::mark_job_control_signals_ignored();
}

/// Resets the daemon-only ignored job-control dispositions in the forked PTY
/// child, then replaces the shim with the configured session program.
#[cfg(unix)]
fn exec_pty_child(args: impl IntoIterator<Item = OsString>) -> anyhow::Result<()> {
    use std::os::unix::process::CommandExt;

    let mut args = args.into_iter();
    let program = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("missing program after internal PTY child marker"))?;
    // SAFETY: this is the single-threaded child produced by portable-pty's fork,
    // immediately before exec. Restoring default dispositions here prevents the
    // configured shell/job from inheriting the daemon's process-wide ignores.
    unsafe {
        libc::signal(libc::SIGTTOU, libc::SIG_DFL);
        libc::signal(libc::SIGTTIN, libc::SIG_DFL);
    }
    let error = std::process::Command::new(&program).args(args).exec();
    Err(anyhow::anyhow!(
        "executing PTY child program {}: {error}",
        program.to_string_lossy()
    ))
}

/// Whether a daemon already owns the IPC socket, used to decide adopt-vs-fresh
/// at launch.
#[cfg(unix)]
enum DaemonSocketState {
    /// A process is accepting connections on the socket — adopt it via handover.
    Live,
    /// No socket, or a stale one (connection refused / not found) that
    /// `bind_owner_socket` will clear — start fresh.
    Absent,
    /// The socket exists but couldn't be probed (e.g. a permission/IO error).
    /// We can't prove nothing is there, so treat it like `Live` rather than risk
    /// clobbering a running daemon; the handover path falls back to a fresh start
    /// if nothing actually answers.
    Unverifiable,
}

/// Probe the IPC socket without committing to a handover. Mirrors
/// `bind_owner_socket`'s error-kind handling: a refused/missing socket is stale
/// (not live), while an unexpected connect error is reported as `Unverifiable`
/// rather than silently treated as "no daemon".
#[cfg(unix)]
fn probe_daemon_socket(socket_path: &std::path::Path) -> DaemonSocketState {
    use std::io::ErrorKind;
    if !socket_path.exists() {
        return DaemonSocketState::Absent;
    }
    match std::os::unix::net::UnixStream::connect(socket_path) {
        Ok(_) => DaemonSocketState::Live,
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::ConnectionRefused | ErrorKind::NotFound
            ) =>
        {
            DaemonSocketState::Absent
        }
        Err(error) => {
            tracing::warn!(
                %error,
                socket_path = %socket_path.display(),
                "could not probe daemon socket; assuming a daemon is present"
            );
            DaemonSocketState::Unverifiable
        }
    }
}

const HELP: &str = "\
usage: triaged [--handover]
       triaged reload
       triaged service <action>
       triaged --help | --version

Options:
  reload            Gracefully reload a running daemon with zero downtime (on Unix)
  --handover, -U    Take over sessions from a running daemon. Optional: a live
                    daemon is always handed over from, flag or not.
  service <action>  Manage the per-user login service and exit
  -h, --help        Print this help text (also `triaged help`)
  -V, --version     Print version information (also `triaged version`)

Running triaged with no arguments starts the daemon. If a daemon is already
running it is handed over from and then shuts down, so an unrecognized
argument is rejected rather than silently displacing the running daemon.";

/// What a `triaged` invocation asked for. Parsed up front so that argument
/// handling can't fall through into starting a daemon — a bare `triaged
/// --help` used to be treated as a plain launch, which hands over from (and
/// thereby shuts down) the running daemon as a side effect of asking for help.
#[derive(Debug, PartialEq, Eq)]
enum Invocation {
    Help,
    Version,
    Reload,
    /// `triaged service <action>` — action is validated by `service::run_cli`.
    Service(String),
    /// Start the daemon. `handover` records whether `--handover`/`-U` was
    /// passed; it is advisory only (see `HELP`).
    Daemon {
        handover: bool,
    },
}

/// Parse the arguments *after* the program name. Takes `OsString` so a
/// non-UTF-8 argument is reported as a usage error rather than panicking inside
/// `env::args()` — the whole point of this function is that a bad argument can't
/// reach the daemon-start path.
fn parse_args(args: impl IntoIterator<Item = OsString>) -> anyhow::Result<Invocation> {
    let rest = args
        .into_iter()
        .map(|arg| {
            arg.into_string().map_err(|arg| {
                anyhow::anyhow!(
                    "argument is not valid UTF-8: {}\n\n{HELP}",
                    arg.to_string_lossy()
                )
            })
        })
        .collect::<anyhow::Result<Vec<String>>>()?;
    let rest = rest.as_slice();

    // `triaged service <action>` manages the per-user login service (LaunchAgent
    // / systemd user unit / Windows logon task) and exits, rather than running
    // the daemon in this process. It is a mode of its own — launch flags do not
    // combine with it — and anything past the action is rejected rather than
    // ignored, so `service install --hanover` can't look like it worked.
    //
    // Matched *before* the help and version flags because the action is the
    // service CLI's to interpret: `service::run_cli` prints its own usage for
    // "", "help", "-h", and "--help", and answering those here would shadow it
    // with the daemon's help instead.
    if rest.first().map(String::as_str) == Some("service") {
        if let Some(extra) = rest.get(2) {
            anyhow::bail!("unexpected argument `{extra}` after `service`\n\n{HELP}");
        }
        return Ok(Invocation::Service(
            rest.get(1).cloned().unwrap_or_default(),
        ));
    }

    if rest.first().map(String::as_str) == Some("reload")
        || rest.iter().any(|arg| arg == "--reload" || arg == "-r")
    {
        if let Some(extra) = rest.get(1) {
            anyhow::bail!("unexpected argument `{extra}` after `reload`\n\n{HELP}");
        }
        return Ok(Invocation::Reload);
    }

    // The flag forms are position-independent, but the bare words are only a
    // request as the first token — anywhere else they are a stray word, and
    // treating one as a request would mask a typo.
    if rest.first().map(String::as_str) == Some("help")
        || rest.iter().any(|arg| arg == "--help" || arg == "-h")
    {
        return Ok(Invocation::Help);
    }
    if rest.first().map(String::as_str) == Some("version")
        || rest.iter().any(|arg| arg == "--version" || arg == "-V")
    {
        return Ok(Invocation::Version);
    }

    let mut handover = false;
    for arg in rest {
        match arg.as_str() {
            "--handover" | "-U" => handover = true,
            other => anyhow::bail!("unrecognized argument `{other}`\n\n{HELP}"),
        }
    }

    Ok(Invocation::Daemon { handover })
}

/// Run whatever the command line asked for. `Help` and `Version` are answered
/// in `main` before logging is initialized, so they never reach here.
fn run(invocation: Invocation) -> anyhow::Result<()> {
    let is_handover = match invocation {
        Invocation::Reload => return triaged::service::reload_daemon(),
        Invocation::Service(action) => return triaged::service::run_cli(&action),
        Invocation::Daemon { handover } => handover,
        // Answered in `main`; reachable only if that guard is refactored away.
        // An error beats a panic for something this recoverable.
        Invocation::Help | Invocation::Version => {
            anyhow::bail!("help and version must be answered before logging init")
        }
    };

    #[cfg(unix)]
    let mut has_inherited_sessions = false;

    // Decide whether to adopt a running daemon. Handover is the right move
    // whenever a *live* daemon already owns the socket — regardless of whether
    // `--handover` was passed. Keying off "is one actually running?" rather than
    // the flag is what makes the daemon safe to run under a KeepAlive supervisor
    // (the launchd LaunchAgent / systemd unit):
    //   - Cold start, nothing running: start fresh. `--handover` no longer bails
    //     ("No running daemon socket found"), so a KeepAlive respawn after the
    //     last daemon exits can't crash-loop.
    //   - A live daemon already owns the socket: hand over (zero session loss)
    //     instead of bailing "already in use", so a supervised respawn doesn't
    //     fight an in-flight manual deploy.
    #[cfg(unix)]
    {
        use triaged::handover::HandoverClientOutcome;

        let socket_path = default_socket_path();
        // A daemon already serving a handover refuses ours with a "busy" signal
        // (distinct from a dead peer). Retry on busy rather than fall back: the
        // in-flight swap will finish shortly, and a fresh start would only fail to
        // bind the port the outgoing daemon still holds. The deadline covers the
        // outgoing daemon's full adoption wait so we converge instead of racing
        // launchd's respawn. A genuine failure (dead/non-triaged peer) returns Err
        // and falls back immediately — no long wait against a dead socket.
        let busy_deadline = std::time::Instant::now()
            + triaged::handover::HANDOVER_ADOPTION_TIMEOUT
            + std::time::Duration::from_secs(5);
        let mut backoff = std::time::Duration::from_millis(200);
        // Set once the peer has told us a swap is in flight. After that, an
        // *absent* socket no longer means "no daemon". The outgoing daemon leaves
        // its socket file behind, but once it exits, connecting to that file is
        // refused — which `probe_daemon_socket` reports as Absent — and the winning
        // successor only binds its own much later (after adopting sessions and
        // starting the WS server), briefly unlinking the stale file first. Falling
        // back to a fresh start inside that gap lands us exactly where the busy
        // sentinel exists to prevent — racing for a port the new daemon is about to
        // hold, then crash-looping under launchd. So once we know a swap is
        // running, keep retrying through the gap until the deadline.
        let mut swap_in_flight = false;
        loop {
            match probe_daemon_socket(&socket_path) {
                DaemonSocketState::Live | DaemonSocketState::Unverifiable => {
                    tracing::info!(
                        socket_path = %socket_path.display(),
                        "existing daemon detected; initiating zero-downtime process handover"
                    );
                    match triaged::handover::perform_handover_client(&socket_path) {
                        Ok(HandoverClientOutcome::Transferred) => {
                            has_inherited_sessions = true;
                            break;
                        }
                        Ok(HandoverClientOutcome::Busy) => {
                            swap_in_flight = true;
                            if std::time::Instant::now() >= busy_deadline {
                                tracing::warn!(
                                    "daemon stayed busy with another handover past the deadline; \
                                     starting fresh"
                                );
                                break;
                            }
                            tracing::info!(
                                "daemon is serving another handover; retrying in {}ms",
                                backoff.as_millis()
                            );
                            std::thread::sleep(backoff);
                            backoff = (backoff * 2).min(std::time::Duration::from_secs(2));
                        }
                        Err(error) => {
                            tracing::warn!(
                                %error,
                                "handover to existing daemon failed; starting fresh"
                            );
                            break;
                        }
                    }
                }
                DaemonSocketState::Absent if swap_in_flight => {
                    // The socket vanished mid-swap (see `swap_in_flight`). The
                    // successor that won will bind shortly; wait for it rather
                    // than race it, and re-probe so we hand over to it instead.
                    if std::time::Instant::now() >= busy_deadline {
                        tracing::warn!(
                            socket_path = %socket_path.display(),
                            "socket still absent after an in-flight swap passed the deadline; \
                             starting fresh"
                        );
                        break;
                    }
                    tracing::info!(
                        "socket is absent while a swap completes; retrying in {}ms",
                        backoff.as_millis()
                    );
                    std::thread::sleep(backoff);
                    backoff = (backoff * 2).min(std::time::Duration::from_secs(2));
                }
                DaemonSocketState::Absent => {
                    if is_handover {
                        tracing::warn!(
                            socket_path = %socket_path.display(),
                            "--handover requested but no running daemon found; starting fresh"
                        );
                    }
                    break;
                }
            }
        }
    }
    #[cfg(not(unix))]
    {
        if is_handover {
            anyhow::bail!(
                "Zero-downtime process handover is only supported on Unix-like operating systems (including Linux and WSL). Please use Session Restore on Windows."
            );
        }
    }

    // Restoring historical sessions replays each log through the terminal
    // emulator and shells out to git per session — measured at ~9s in June 2026
    // and ~22.6s a month later, growing with accumulated logs. On a handover
    // that time is spent while the outgoing daemon is parked waiting for our
    // adoption byte. The outgoing daemon now waits for the live successor rather
    // than timing it out and admitting a second reader; the coordination budget
    // still reflects the expected warm-up window for other starters.
    //
    // It belongs here, *above* the sync, and moving it below to shrink that wait
    // is a trap worth naming: until the adoption byte goes out the outgoing
    // daemon is still fully serving, so this is warm-up, not downtime. Below the
    // sync the same work becomes downtime — nothing reads the adopted masters,
    // so children blocking on a full PTY buffer freeze; no process answers
    // clients; and a panic in log replay strands every session with no daemon
    // left to own them, where up here it would merely abort a handover the
    // outgoing daemon survives.
    //
    // The way to shrink the wait is to make the restore itself cheaper or lazy,
    // not to move it past the commit point.
    let manager = Arc::new(SessionManager::default());

    // Arm the rescue as soon as a manager exists, which is deliberately *before*
    // adoption rather than after it. From the moment `complete_handover_adoption`
    // returns `Adopt`, this process is the sole owner of every adopted master and the
    // predecessor has already detached, so a stop signal in that window must not take
    // the unarmed "exit without a rescue" path: that would close every master and
    // SIGHUP every child, which is the loss this exists to prevent. The window is not
    // instantaneous either, since `seed_session_snippets` round-trips to each adopted
    // actor.
    //
    // Arming here costs nothing before adoption: a manager holding only restored
    // `Historical` entries reports zero live sessions, so a signal is skipped and
    // exits cleanly, exactly as an unarmed one would.
    #[cfg(unix)]
    triaged::shutdown::arm_rescue(Arc::clone(&manager));

    // Load configuration
    let config = if let Ok(path) = triage_core::config::Config::default_path() {
        if path.exists() {
            triage_core::config::Config::load_from_path(&path).unwrap_or_default()
        } else {
            triage_core::config::Config::default()
        }
    } else {
        triage_core::config::Config::default()
    };

    // Start the local-LLM session summarizer (on by default; model loads lazily
    // on first activity, so this never blocks startup). No-op when disabled.
    manager.start_summarizer(config.summarizer.clone());

    // Install the tool-call approval judge. It shares the summarizer's resident
    // model, so this only builds the rule tables and never loads anything.
    manager.start_judge(config.judge.clone());
    triaged::service::install_global_agent_hooks();

    // Start recording each live session's working directory into the manifest as
    // it changes, so a daemon kill restores sessions where they left off rather
    // than at their launch dir. Always on, independent of the summarizer.
    manager.start_cwd_persistence();

    // Start periodically recording each live session's last-output time into the
    // manifest, so the client rail's activity ordering survives a daemon kill.
    // A session that only ever produces output (a build, a running agent) never
    // triggers a manifest write on its own. Always on, independent of the
    // summarizer.
    manager.start_activity_persistence();

    // Start the background update check (on by default). Polls the release host
    // for a newer tag via `git ls-remote`; failures are silent and never block
    // startup. No-op when `[update] check` is false.
    manager.start_update_poller(config.update.clone());

    let bind_addr = config.remote.bind_addr()?;

    // The default bind is 0.0.0.0 so the client can reach the daemon from another
    // device on the LAN/tailnet. That exposes the listener to the local network;
    // access is still gated by device-code + PIN pairing (require_pairing). Warn
    // so an operator who didn't intend network exposure notices.
    if bind_addr.ip().is_unspecified() {
        if config.remote.require_pairing {
            tracing::warn!(
                %bind_addr,
                "daemon is reachable on the local network; access is gated by pairing"
            );
        } else {
            tracing::warn!(
                %bind_addr,
                "daemon is reachable on the local network with pairing DISABLED — \
                 anyone who can reach this address can control sessions"
            );
        }
    }

    // Take the inherited TCP listener early so recovery snapshots can identify
    // the same ownership lineage. If the descriptor ceiling left it behind, bind
    // a replacement only after the outgoing daemon has actually exited.
    #[cfg(unix)]
    let inherited_tcp_listener = if has_inherited_sessions {
        let listener = triaged::handover::take_inherited_tcp_listener();
        if let Some(listener) = listener.as_ref() {
            tracing::info!("Successfully adopted inherited TCP listener socket");
            use std::os::unix::io::AsRawFd;
            triaged::handover::set_active_tcp_listener_fd(listener.as_raw_fd());
        }
        listener
    } else {
        None
    };

    #[cfg(not(unix))]
    let tcp_listener = Some(std::net::TcpListener::bind(bind_addr)?);

    // If we have inherited sessions, adopt them!
    #[cfg(unix)]
    {
        let mut adopted_sessions = false;
        if has_inherited_sessions {
            let state_str = triaged::handover::INHERITED_STATE
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take();
            if let Some(state_str) = state_str {
                let mut state: triaged::handover::HandoverState = serde_json::from_str(&state_str)?;
                let fds = triaged::handover::INHERITED_FDS
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .take();
                if let Some(mut fds) = fds {
                    // Complete the Phase 2/3 sync FIRST, before starting any PTY
                    // readers, so our readers start as late as possible relative to
                    // the outgoing daemon's exit. (That exit — not this handshake —
                    // is what makes the handoff exclusive; see
                    // HANDOVER_TEARDOWN_TIMEOUT.)
                    // If the first handshake aborted, completion keeps these
                    // descriptors idle while it atomically hands over whichever
                    // daemon currently owns the socket.
                    triaged::handover::complete_handover_adoption(
                        &default_socket_path(),
                        state.sends_teardown_commit,
                    )?;
                    triaged::handover::claim_handover_socket(
                        &default_socket_path(),
                        &mut state,
                        &mut fds,
                    );

                    tracing::info!("Adopting {} inherited live sessions", state.sessions.len());
                    // Publish ownership in the manager before any fallible actor
                    // setup. A stop signal in the next instruction can then
                    // transfer these retained PTYs through another handover
                    // instead of observing an empty manager and exiting.
                    if let Err(error) = manager.queue_handover_adoptions(state, fds) {
                        tracing::error!(
                            %error,
                            "the inherited session state and PTY count did not match; retrying the mapped sessions"
                        );
                    }
                    if manager.has_unresolved_adoptions() {
                        manager.retry_pending_adoptions();
                    }
                    adopted_sessions = true;
                }
            }
            if !manager.has_unresolved_adoptions() {
                triaged::handover::finish_handover_adoption();
            }
            if adopted_sessions {
                // Snippet extraction can block on a parked actor. It is optional
                // warm-up, so never delay the IPC accept loop after publishing
                // the prebound owner socket.
                let snippet_manager = Arc::clone(&manager);
                if let Err(error) = std::thread::Builder::new()
                    .name("triage-snippet-seed".into())
                    .spawn(move || snippet_manager.seed_session_snippets())
                {
                    tracing::warn!(%error, "could not spawn session snippet seeding");
                }
            }
        }
    }

    #[cfg(unix)]
    let tcp_listener = match inherited_tcp_listener {
        Some(listener) => Some(listener),
        // Only a handover can have a live predecessor still holding the address
        // after Phase 1 omitted its listener. Preserve the background bind retry
        // for that availability gap; a cold start must report configuration or
        // address errors synchronously.
        None if has_inherited_sessions => None,
        None => Some(std::net::TcpListener::bind(bind_addr)?),
    };

    // Startup has settled: whichever path got us here (cold start, session
    // restore, or handover adoption), every session this daemon owns is now in
    // the manager. Only now is it safe to decide which logs are unreferenced —
    // doing it at manifest-load time would race adoption and could delete a live
    // session's log.
    //
    // Off-thread, though. This point is below the handover commit, where the
    // same reasoning as the restore comment above applies: nothing is serving
    // clients yet, so a directory scan plus unlinks of potentially many
    // multi-megabyte logs would be pure downtime. The purge needs no ordering
    // against anything that follows — it only ever removes logs no session
    // refers to — so let it run alongside startup. A session created by a client
    // while it is mid-scan is safe on the age check: its log was written
    // seconds ago, and nothing within the retention window is eligible.
    let purge_manager = Arc::clone(&manager);
    if let Err(error) = std::thread::Builder::new()
        .name("triage-log-purge".into())
        .spawn(move || purge_manager.purge_orphaned_logs())
    {
        // Not worth failing startup over; the next start tries again.
        tracing::warn!(%error, "could not spawn the orphaned-log purge thread");
    }

    // Initialize in-memory Web Asset Cache with custom config path or default state path overrides
    let override_dir = config
        .remote
        .web_assets_path
        .as_ref()
        .map(std::path::PathBuf::from)
        .or_else(triaged::http::default_override_dir);
    let web_cache = Arc::new(triaged::http::WebAssetCache::new(override_dir));

    // Spawn Multiplexed HTTP & WebSocket Server in a background thread
    let ws_manager = Arc::clone(&manager);
    let ws_cache = Arc::clone(&web_cache);
    let pair_approval_tailnet_users = config.remote.pair_approval_tailnet_users.clone();
    let pair_approval_trust_local_peers = config.remote.pair_approval_trust_local_peers;
    if let Err(error) = std::thread::Builder::new()
        .name("triage-websocket-server".to_string())
        .spawn(move || {
            #[cfg(unix)]
            let tcp_listener = match tcp_listener {
                Some(listener) => listener,
                None => loop {
                    match std::net::TcpListener::bind(bind_addr) {
                        Ok(listener) => {
                            use std::os::unix::io::AsRawFd;
                            triaged::handover::set_active_tcp_listener_fd(
                                listener.as_raw_fd(),
                            );
                            break listener;
                        }
                        Err(error) => {
                            tracing::warn!(
                                %error,
                                %bind_addr,
                                "TCP listener is still occupied after handover; retrying while IPC remains available."
                            );
                            std::thread::sleep(std::time::Duration::from_millis(250));
                        }
                    }
                },
            };
            #[cfg(not(unix))]
            let tcp_listener = tcp_listener
                .expect("non-Unix listener was bound before spawn");
            if let Err(error) = ws::start_websocket_server(
                ws_manager,
                tcp_listener,
                ws_cache,
                pair_approval_tailnet_users,
                pair_approval_trust_local_peers,
            ) {
                tracing::error!(error = ?error, "Multiplexed HTTP + WebSocket server failed");
            }
        })
    {
        tracing::error!(
            %error,
            "could not start the WebSocket server thread; continuing with local IPC so inherited sessions remain owned"
        );
    }

    #[cfg(unix)]
    if manager.has_unresolved_adoptions() {
        // A first retry-thread spawn can fail under the same transient resource
        // pressure as actor setup. The WebSocket spawn above is a second point at
        // which thread capacity may have recovered; if not, local IPC still lets
        // a later handover transfer the retained PTYs.
        manager.retry_pending_adoptions();
    }

    // Run the local IPC control server. This is a Unix domain socket on Unix and
    // a named pipe on Windows; both speak the same protocol. The call blocks the
    // main thread for the daemon's lifetime.
    #[cfg(unix)]
    {
        let socket_path = default_socket_path();
        tracing::info!(socket_path = %socket_path.display(), "triaged starting Unix socket server");
        // A handover start reserved this pathname before starting PTY readers;
        // `serve` consumes that listener. A fresh start binds here and fails
        // immediately if another daemon already owns it.
        let config = IpcConfig::new(socket_path);
        IpcServer::new(manager, web_cache, config).serve()?;
        Ok(())
    }

    #[cfg(windows)]
    {
        // Record our PID so `triaged service stop` can target this exact daemon
        // rather than every triaged.exe the user owns.
        triaged::service::record_running_pid();
        let pipe_name = default_socket_path();
        let endpoint = triaged::ipc::display_endpoint(&pipe_name);
        tracing::info!(pipe = %endpoint, "triaged starting named pipe server");
        IpcServer::new(manager, web_cache, IpcConfig::new(pipe_name)).serve()?;
        Ok(())
    }

    // No local IPC transport on other platforms: keep the daemon (and its
    // WS/HTTP server thread) alive by parking the main thread.
    #[cfg(not(any(unix, windows)))]
    {
        tracing::info!("triaged starting (no local IPC server available on this platform)");
        loop {
            std::thread::park();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Invocation, parse_args};
    use std::ffi::OsString;

    /// Arguments *after* the program name, matching what `main` passes.
    fn args(rest: &[&str]) -> Vec<OsString> {
        rest.iter().map(OsString::from).collect()
    }

    /// `main` passes everything after the program name, so "no arguments" and
    /// "empty argv" are the same input here — one assertion covers both.
    #[test]
    fn bare_invocation_starts_the_daemon() {
        assert_eq!(
            parse_args(args(&[])).unwrap(),
            Invocation::Daemon { handover: false }
        );
    }

    #[test]
    fn handover_flags_are_accepted() {
        for flag in ["--handover", "-U"] {
            assert_eq!(
                parse_args(args(&[flag])).unwrap(),
                Invocation::Daemon { handover: true }
            );
        }
    }

    /// The regression this module exists for: asking for help must not resolve
    /// to `Daemon`, because starting a daemon hands over from (and shuts down)
    /// the running one.
    #[test]
    fn help_never_starts_the_daemon() {
        for flag in ["--help", "-h", "help"] {
            assert_eq!(parse_args(args(&[flag])).unwrap(), Invocation::Help);
        }
    }

    #[test]
    fn version_never_starts_the_daemon() {
        for flag in ["--version", "-V", "version"] {
            assert_eq!(parse_args(args(&[flag])).unwrap(), Invocation::Version);
        }
    }

    /// A non-UTF-8 argument is a usage error, not a panic inside `env::args()`
    /// — anything that isn't understood must be rejected before the daemon path.
    ///
    /// Gated on the platforms where a non-UTF-8 `OsString` can be constructed;
    /// the crate also builds for `not(any(unix, windows))`, where it cannot.
    #[cfg(any(unix, windows))]
    #[test]
    fn non_utf8_arguments_are_rejected_without_panicking() {
        let bad = bad_utf8_arg();
        let error = parse_args(vec![bad]).unwrap_err().to_string();
        assert!(
            error.contains("not valid UTF-8"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    fn bad_utf8_arg() -> OsString {
        use std::os::unix::ffi::OsStringExt;
        OsString::from_vec(vec![0xff, 0xfe])
    }

    #[cfg(windows)]
    fn bad_utf8_arg() -> OsString {
        use std::os::windows::ffi::OsStringExt;
        // An unpaired surrogate is representable in an OsString but not in a
        // Rust String.
        OsString::from_wide(&[0xd800])
    }

    /// Help wins over an otherwise-valid launch flag so `triaged --handover
    /// --help` prints usage instead of displacing the running daemon.
    #[test]
    fn help_takes_precedence_over_launch_flags() {
        assert_eq!(
            parse_args(args(&["--handover", "--help"])).unwrap(),
            Invocation::Help
        );
    }

    /// A typo must fail loudly rather than fall through to a daemon start.
    #[test]
    fn unrecognized_arguments_are_rejected() {
        let error = parse_args(args(&["--handver"])).unwrap_err().to_string();
        assert!(
            error.contains("unrecognized argument `--handver`"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn service_subcommand_is_routed_with_its_action() {
        assert_eq!(
            parse_args(args(&["service", "install"])).unwrap(),
            Invocation::Service("install".to_string())
        );
        assert_eq!(
            parse_args(args(&["service"])).unwrap(),
            Invocation::Service(String::new())
        );
    }

    /// `service` returns early, so extras past the action would otherwise be
    /// silently dropped — the same "ignored argument" failure this module
    /// exists to prevent, just one position further along.
    #[test]
    fn service_rejects_arguments_after_the_action() {
        let error = parse_args(args(&["service", "install", "--handover"]))
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("unexpected argument `--handover` after `service`"),
            "unexpected error: {error}"
        );
    }

    /// The service CLI prints its own usage for "", "help", "-h" and "--help"
    /// (`service::run_cli`), so those must reach it rather than being answered
    /// with the daemon's help.
    #[test]
    fn service_owns_its_own_help() {
        for action in ["help", "-h", "--help"] {
            assert_eq!(
                parse_args(args(&["service", action])).unwrap(),
                Invocation::Service(action.to_string()),
                "`service {action}` should reach the service CLI"
            );
        }
    }

    /// Bare `help` is a help request only as the first token. Elsewhere it is a
    /// stray word, and silently treating it as help would mask a typo.
    #[test]
    fn bare_help_is_only_a_help_request_in_first_position() {
        assert_eq!(parse_args(args(&["help"])).unwrap(), Invocation::Help);

        let error = parse_args(args(&["--handover", "help"]))
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("unrecognized argument `help`"),
            "unexpected error: {error}"
        );

        // The flag forms stay position-independent.
        assert_eq!(
            parse_args(args(&["--handover", "-h"])).unwrap(),
            Invocation::Help
        );
    }

    #[test]
    fn reload_arguments_are_parsed() {
        assert_eq!(parse_args(args(&["reload"])).unwrap(), Invocation::Reload);
        assert_eq!(parse_args(args(&["--reload"])).unwrap(), Invocation::Reload);
        assert_eq!(parse_args(args(&["-r"])).unwrap(), Invocation::Reload);
    }
}
