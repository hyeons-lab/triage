#![cfg_attr(unix, allow(unsafe_code))]

use std::sync::Arc;
use triaged::session::SessionManager;
use triaged::ws;

#[cfg(any(unix, windows))]
use triaged::ipc::{IpcConfig, IpcServer, default_socket_path};

fn main() -> anyhow::Result<()> {
    // Keep this binding alive for the lifetime of the process: dropping the
    // WorkerGuard flushes the non-blocking tracing appender thread.
    let _flush_guard = triage_core::logging::init(triage_core::logging::default_config()?)?;
    run()
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

fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();

    // `triaged service <action>` manages the per-user login service (LaunchAgent
    // / systemd user unit / Windows logon task) and exits, rather than running
    // the daemon in this process.
    if args.get(1).map(String::as_str) == Some("service") {
        let action = args.get(2).map(String::as_str).unwrap_or("");
        return triaged::service::run_cli(action);
    }

    let is_handover = args.contains(&"--handover".to_string()) || args.contains(&"-U".to_string());

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
        let socket_path = default_socket_path();
        match probe_daemon_socket(&socket_path) {
            DaemonSocketState::Live | DaemonSocketState::Unverifiable => {
                tracing::info!(
                    socket_path = %socket_path.display(),
                    "existing daemon detected; initiating zero-downtime process handover"
                );
                // The handover client bounds its own wait; if the peer never
                // completes the protocol (a hung daemon, or a non-triaged process
                // on the socket), fall back to a fresh start rather than aborting
                // launch. A fresh start that then finds the socket genuinely held
                // will fail to bind with a clear error.
                match triaged::handover::perform_handover_client(&socket_path) {
                    Ok(()) => has_inherited_sessions = true,
                    Err(error) => tracing::warn!(
                        %error,
                        "handover to existing daemon failed; starting fresh"
                    ),
                }
            }
            DaemonSocketState::Absent => {
                if is_handover {
                    tracing::warn!(
                        socket_path = %socket_path.display(),
                        "--handover requested but no running daemon found; starting fresh"
                    );
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
                    // Complete Phase 2/3 sync FIRST before starting any PTY readers!
                    // This shuts down the old daemon's readers before we start ours.
                    triaged::handover::complete_handover_adoption()?;

                    tracing::info!("Adopting {} inherited live sessions", state.sessions.len());
                    manager.adopt_sessions(state, fds)?;
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
        IpcServer::new(manager, web_cache, IpcConfig::new(socket_path)).serve()?;
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
