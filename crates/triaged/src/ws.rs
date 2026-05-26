use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;
use triage_transport_ws::WebSocketSessionConnection;

use crate::session::SessionManager;

/// Start the WebSocket server using a dedicated Tokio runtime and pre-bound std::net::TcpListener.
pub fn start_websocket_server(
    manager: Arc<SessionManager>,
    listener: std::net::TcpListener,
) -> Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("triage-ws-runtime")
        .build()
        .context("building Tokio runtime for WebSocket server")?;

    rt.block_on(async {
        let listener = TcpListener::from_std(listener)
            .context("converting std TcpListener to Tokio TcpListener")?;
        let bind_addr = listener.local_addr().ok();
        tracing::info!(bind_addr = ?bind_addr, "WebSocket server listening");
        tracing::info!("triage remote web client UI is typically served at http://127.0.0.1:8080");

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
    let mut conn =
        WebSocketSessionConnection::with_authenticator(Arc::clone(&manager), Arc::clone(&manager));

    let mut next_msg = ws_receiver.next();

    loop {
        tokio::select! {
            maybe_msg = &mut next_msg => {
                match maybe_msg {
                    Some(Ok(msg)) => {
                        match msg {
                            Message::Text(text) => {
                                let response = conn.handle_text_message(&text);
                                if ws_sender.send(Message::Text(response)).await.is_err() {
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
                next_msg = ws_receiver.next();
            }
            _ = tokio::time::sleep(Duration::from_millis(10)) => {
                let messages = conn.drain_events();
                let mut send_failed = false;
                for msg in messages {
                    let serialized = serde_json::to_string(&msg)
                        .context("serializing session event")?;
                    if ws_sender.send(Message::Text(serialized)).await.is_err() {
                        send_failed = true;
                        break;
                    }
                }
                if send_failed {
                    break;
                }
            }
        }
    }

    Ok(())
}
