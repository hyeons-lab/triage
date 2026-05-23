use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use argus_transport_ws::WebSocketSessionConnection;
use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;

use crate::session::SessionManager;

/// Start the WebSocket server using a dedicated Tokio runtime.
pub fn start_websocket_server(manager: Arc<SessionManager>, bind_addr: SocketAddr) -> Result<()> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .thread_name("argus-ws-runtime")
        .build()
        .context("building Tokio runtime for WebSocket server")?;

    rt.block_on(async {
        let listener = TcpListener::bind(bind_addr)
            .await
            .context("binding WebSocket TCP listener")?;
        tracing::info!(bind_addr = %bind_addr, "WebSocket server listening");

        loop {
            match listener.accept().await {
                Ok((stream, addr)) => {
                    let manager = Arc::clone(&manager);
                    tokio::spawn(async move {
                        if let Err(error) = handle_ws_connection(manager, stream, addr).await {
                            tracing::warn!(error = ?error, client_addr = %addr, "WebSocket connection failed");
                        }
                    });
                }
                Err(error) => {
                    tracing::warn!(error = ?error, "failed to accept TCP connection");
                }
            }
        }
    })
}

async fn handle_ws_connection(
    manager: Arc<SessionManager>,
    stream: TcpStream,
    addr: SocketAddr,
) -> Result<()> {
    let ws_stream = tokio_tungstenite::accept_async(stream)
        .await
        .context("WebSocket handshake failed")?;

    tracing::info!(client_addr = %addr, "WebSocket client connected");

    let (mut ws_sender, mut ws_receiver) = ws_stream.split();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Message>();

    // Spawn a dedicated write task to safely serialize socket writes and avoid cancellation safety issues
    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if let Err(err) = ws_sender.send(msg).await {
                tracing::warn!("failed to send WebSocket message: {:?}", err);
                break;
            }
        }
    });

    let mut conn = WebSocketSessionConnection::new(manager);
    let mut interval = tokio::time::interval(Duration::from_millis(10));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            maybe_msg = ws_receiver.next() => {
                match maybe_msg {
                    Some(Ok(msg)) => {
                        match msg {
                            Message::Text(text) => {
                                let response = conn.handle_text_message(&text);
                                if tx.send(Message::Text(response)).is_err() {
                                    break;
                                }
                            }
                            Message::Close(_) => {
                                tracing::info!(client_addr = %addr, "WebSocket client disconnected");
                                break;
                            }
                            _ => {}
                        }
                    }
                    Some(Err(err)) => {
                        tracing::info!(client_addr = %addr, error = ?err, "WebSocket client connection error");
                        break;
                    }
                    None => {
                        tracing::info!(client_addr = %addr, "WebSocket client connection closed");
                        break;
                    }
                }
            }
            _ = interval.tick() => {
                let messages = conn.drain_events();
                for msg in messages {
                    let serialized = serde_json::to_string(&msg)
                        .context("serializing session event")?;
                    if tx.send(Message::Text(serialized)).is_err() {
                        break;
                    }
                }
            }
        }
    }

    // Drop sender to signal writer task to finish, then await final flush
    drop(tx);
    let _ = write_task.await;
    Ok(())
}
