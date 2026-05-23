use argus_daemon::session::SessionManager;
use argus_daemon::ws;
use std::sync::Arc;

#[cfg(unix)]
use argus_daemon::ipc::{UnixSocketConfig, UnixSocketServer, default_socket_path};

fn main() -> anyhow::Result<()> {
    // Keep this binding alive for the lifetime of the process: dropping the
    // WorkerGuard flushes the non-blocking tracing appender thread.
    let _flush_guard = argus_core::logging::init(argus_core::logging::default_config()?)?;
    run()
}

fn run() -> anyhow::Result<()> {
    let manager = Arc::new(SessionManager::default());

    // Load configuration
    let config = if let Ok(path) = argus_core::config::Config::default_path() {
        if path.exists() {
            argus_core::config::Config::load_from_path(&path).unwrap_or_default()
        } else {
            argus_core::config::Config::default()
        }
    } else {
        argus_core::config::Config::default()
    };

    let bind_addr = config.remote.bind_addr()?;

    // Spawn WebSocket Server in a background thread
    let ws_manager = Arc::clone(&manager);
    std::thread::Builder::new()
        .name("argus-websocket-server".to_string())
        .spawn(move || {
            if let Err(error) = ws::start_websocket_server(ws_manager, bind_addr) {
                tracing::error!(error = ?error, "WebSocket server failed");
            }
        })?;

    // Run Unix Socket Server on Unix
    #[cfg(unix)]
    {
        let socket_path = default_socket_path();
        tracing::info!(socket_path = %socket_path.display(), "argus-daemon starting Unix socket server");
        UnixSocketServer::new(manager, UnixSocketConfig::new(socket_path)).serve()?;
        Ok(())
    }

    // On non-Unix, block the main thread by parking to keep the daemon alive
    #[cfg(not(unix))]
    {
        tracing::info!("argus-daemon starting (no Unix socket server available)");
        loop {
            std::thread::park();
        }
    }
}
