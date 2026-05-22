#[cfg(unix)]
use std::sync::Arc;

#[cfg(unix)]
use argus_daemon::ipc::{UnixSocketConfig, UnixSocketServer, default_socket_path};
#[cfg(unix)]
use argus_daemon::session::SessionManager;
#[cfg(unix)]
use argus_transport_ws::serve_blocking as serve_websocket_blocking;

fn main() -> anyhow::Result<()> {
    // Keep this binding alive for the lifetime of the process: dropping the
    // WorkerGuard flushes the non-blocking tracing appender thread.
    let _flush_guard = argus_core::logging::init(argus_core::logging::default_config()?)?;
    run()
}

#[cfg(unix)]
fn run() -> anyhow::Result<()> {
    let socket_path = default_socket_path();
    tracing::info!(socket_path = %socket_path.display(), "argus-daemon starting");
    let manager = Arc::new(SessionManager::default());
    if let Ok(addr) = std::env::var("ARGUS_WS_LISTEN")
        && !addr.trim().is_empty()
    {
        let websocket_manager = Arc::clone(&manager);
        std::thread::spawn(move || {
            if let Err(error) = serve_websocket_blocking(addr, websocket_manager) {
                tracing::error!(error = ?error, "argus websocket transport stopped");
            }
        });
    }
    UnixSocketServer::new(manager, UnixSocketConfig::new(socket_path)).serve()
}

#[cfg(not(unix))]
fn run() -> anyhow::Result<()> {
    anyhow::bail!("argus-daemon Unix socket API is only available on Unix platforms")
}
