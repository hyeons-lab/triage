#![cfg_attr(unix, allow(unsafe_code))]

use std::sync::Arc;
use triaged::session::SessionManager;
use triaged::ws;

#[cfg(unix)]
use triaged::ipc::{UnixSocketConfig, UnixSocketServer, default_socket_path};

fn main() -> anyhow::Result<()> {
    // Keep this binding alive for the lifetime of the process: dropping the
    // WorkerGuard flushes the non-blocking tracing appender thread.
    let _flush_guard = triage_core::logging::init(triage_core::logging::default_config()?)?;
    run()
}

fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let is_handover = args.contains(&"--handover".to_string()) || args.contains(&"-U".to_string());

    #[cfg(unix)]
    let mut has_inherited_sessions = false;

    if is_handover {
        #[cfg(unix)]
        {
            let socket_path = default_socket_path();
            if socket_path.exists() {
                tracing::info!(socket_path = %socket_path.display(), "initiating zero-downtime process handover");
                triaged::handover::perform_handover_client(&socket_path)?;
                has_inherited_sessions = true;
            } else {
                anyhow::bail!(
                    "No running daemon socket found at {}. Start the daemon normally first.",
                    socket_path.display()
                );
            }
        }
        #[cfg(not(unix))]
        {
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

    let bind_addr = config.remote.bind_addr()?;

    if config.remote.require_pairing {
        let _ = manager.generate_pairing_code()?;
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
    std::thread::Builder::new()
        .name("triage-websocket-server".to_string())
        .spawn(move || {
            if let Err(error) = ws::start_websocket_server(ws_manager, tcp_listener, ws_cache) {
                tracing::error!(error = ?error, "Multiplexed HTTP + WebSocket server failed");
            }
        })?;

    // Run Unix Socket Server on Unix
    #[cfg(unix)]
    {
        let socket_path = default_socket_path();
        tracing::info!(socket_path = %socket_path.display(), "triaged starting Unix socket server");
        UnixSocketServer::new(manager, web_cache, UnixSocketConfig::new(socket_path)).serve()?;
        Ok(())
    }

    // On non-Unix, block the main thread by parking to keep the daemon alive
    #[cfg(not(unix))]
    {
        tracing::info!("triaged starting (no Unix socket server available)");
        loop {
            std::thread::park();
        }
    }
}
