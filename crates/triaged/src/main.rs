#![cfg_attr(unix, allow(unsafe_code))]

use std::ffi::OsString;
use std::sync::Arc;
use triaged::session::SessionManager;
use triaged::ws;

#[cfg(any(unix, windows))]
use triaged::ipc::{IpcConfig, IpcServer, default_socket_path};

fn main() -> anyhow::Result<()> {
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
        Invocation::Service(_) | Invocation::Daemon { .. } => {}
    }

    // Keep this binding alive for the lifetime of the process: dropping the
    // WorkerGuard flushes the non-blocking tracing appender thread.
    let _flush_guard = triage_core::logging::init(triage_core::logging::default_config()?)?;
    run(invocation)
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
       triaged service <action>
       triaged --help | --version

Options:
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
    // adoption byte, which is why `HANDOVER_ADOPTION_TIMEOUT` has to cover it.
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

    // Start recording each live session's working directory into the manifest as
    // it changes, so a daemon kill restores sessions where they left off rather
    // than at their launch dir. Always on, independent of the summarizer.
    manager.start_cwd_persistence();

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

    // Bind TCP listener (either inherited or brand new)
    let tcp_listener = {
        #[cfg(unix)]
        {
            if has_inherited_sessions {
                if let Some(listener) = triaged::handover::take_inherited_tcp_listener() {
                    tracing::info!("Successfully adopted inherited TCP listener socket");
                    use std::os::unix::io::AsRawFd;
                    triaged::handover::set_active_tcp_listener_fd(listener.as_raw_fd());
                    listener
                } else {
                    let listener = std::net::TcpListener::bind(bind_addr)?;
                    use std::os::unix::io::AsRawFd;
                    triaged::handover::set_active_tcp_listener_fd(listener.as_raw_fd());
                    listener
                }
            } else {
                let listener = std::net::TcpListener::bind(bind_addr)?;
                use std::os::unix::io::AsRawFd;
                triaged::handover::set_active_tcp_listener_fd(listener.as_raw_fd());
                listener
            }
        }
        #[cfg(not(unix))]
        {
            std::net::TcpListener::bind(bind_addr)?
        }
    };

    // If we have inherited sessions, adopt them!
    #[cfg(unix)]
    {
        if has_inherited_sessions {
            let state_str = triaged::handover::INHERITED_STATE.lock().unwrap().take();
            if let Some(state_str) = state_str {
                let state: triaged::handover::HandoverState = serde_json::from_str(&state_str)?;
                let fds = triaged::handover::INHERITED_FDS.lock().unwrap().take();
                if let Some(fds) = fds {
                    use triaged::handover::TeardownOutcome;

                    // Complete the Phase 2/3 sync FIRST, before starting any PTY
                    // readers, so our readers start as late as possible relative to
                    // the outgoing daemon's exit. (That exit — not this handshake —
                    // is what makes the handoff exclusive; see
                    // HANDOVER_TEARDOWN_TIMEOUT.)
                    // The outcome says whether the old daemon actually committed to
                    // teardown (Adopt) or aborted while still owning its sessions
                    // (Refuse) — see complete_handover_adoption / teardown_outcome.
                    match triaged::handover::complete_handover_adoption(
                        &default_socket_path(),
                        state.sends_teardown_commit,
                    )? {
                        TeardownOutcome::Refuse => {
                            // The old daemon aborted and kept its sessions, so it is
                            // still serving them on its own copies of the masters and
                            // listener. Adopting our dup'd copies would put a second
                            // destructive reader on each. Exit and let the OS close
                            // our copies; the old daemon is unaffected, and launchd
                            // respawns us to retry a clean handover. Exit here is
                            // before the WS/IPC servers start, so nothing is torn
                            // down that the old daemon isn't already running.
                            //
                            // Return rather than `process::exit`: exiting here would
                            // skip main's WorkerGuard drop, which is the only thing
                            // that flushes the non-blocking tracing appender — so
                            // the very message explaining this exit would likely
                            // never reach the log. Returning unwinds normally, the
                            // guard flushes, and `main`'s `Result` still yields a
                            // non-zero status so a manual deploy can tell a refused
                            // swap from a clean one. launchd respawns us either way
                            // (KeepAlive: true, not SuccessfulExit), so the retry
                            // path is unaffected. Our dup'd listener and masters
                            // close as their owners drop; the old daemon keeps its
                            // own copies and keeps serving.
                            tracing::error!(
                                "outgoing daemon did not commit its teardown; it still owns its \
                                 sessions. Exiting without adopting so a retry can hand over \
                                 cleanly (the daemon keeps serving in the meantime)."
                            );
                            return Err(anyhow::anyhow!(
                                "handover refused: outgoing daemon did not commit its teardown \
                                 and still owns its sessions"
                            ));
                        }
                        TeardownOutcome::Adopt => {}
                    }

                    tracing::info!("Adopting {} inherited live sessions", state.sessions.len());
                    // complete_handover_adoption() above sent the 0x01 commit
                    // byte and the old daemon committed, so it has detached and
                    // no longer owns these sessions. adopt_sessions inserts each
                    // session as it goes, so a mid-loop failure (a rotated log
                    // file, thread-spawn EAGAIN under fd pressure) still leaves
                    // the ones already adopted live in this manager. Propagating
                    // with `?` here would exit the successor too and close *every*
                    // adopted master, orphaning the sessions that did adopt
                    // cleanly — the exact loss handover exists to avoid. Keep the
                    // daemon up and owning what it got instead.
                    if let Err(error) = manager.adopt_sessions(state, fds) {
                        tracing::error!(
                            %error,
                            "failed to fully adopt inherited sessions after the handover commit; \
                             continuing with those already adopted so the daemon still owns them"
                        );
                    }
                    // Seed snippets now that adopted sessions are live, so the
                    // rail shows a description for each immediately after handover.
                    manager.seed_session_snippets();
                }
            }
        }
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
    std::thread::Builder::new()
        .name("triage-websocket-server".to_string())
        .spawn(move || {
            if let Err(error) = ws::start_websocket_server(
                ws_manager,
                tcp_listener,
                ws_cache,
                pair_approval_tailnet_users,
                pair_approval_trust_local_peers,
            ) {
                tracing::error!(error = ?error, "Multiplexed HTTP + WebSocket server failed");
            }
        })?;

    // Run the local IPC control server. This is a Unix domain socket on Unix and
    // a named pipe on Windows; both speak the same protocol. The call blocks the
    // main thread for the daemon's lifetime.
    #[cfg(unix)]
    {
        let socket_path = default_socket_path();
        tracing::info!(socket_path = %socket_path.display(), "triaged starting Unix socket server");
        // Having adopted sessions, this process owns live PTY masters, so failing
        // the bind would take them all down. The predecessor can still be finishing
        // its teardown here — it releases us at the commit byte and only then
        // detaches and exits — so wait that out rather than die holding everything.
        // A fresh start keeps the zero grace: a socket genuinely owned by another
        // daemon should fail immediately and loudly.
        let config = IpcConfig::new(socket_path);
        let config = if has_inherited_sessions {
            config.with_bind_grace(triaged::handover::HANDOVER_TEARDOWN_TIMEOUT)
        } else {
            config
        };
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
}
