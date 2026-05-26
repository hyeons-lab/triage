use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use hyper::server::conn::http1;
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;
use triage_transport_ws::WebSocketSessionConnection;

use crate::http::WebAssetCache;
use crate::session::SessionManager;

/// Start the multiplexed HTTP and WebSocket server using a dedicated Tokio runtime.
pub fn start_websocket_server(
    manager: Arc<SessionManager>,
    listener: std::net::TcpListener,
    cache: Arc<WebAssetCache>,
) -> Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("triage-ws-runtime")
        .build()
        .context("building Tokio runtime for multiplexed HTTP server")?;

    rt.block_on(async {
        let listener = TcpListener::from_std(listener)
            .context("converting std TcpListener to Tokio TcpListener")?;
        let bind_addr = listener.local_addr().ok();
        tracing::info!(bind_addr = ?bind_addr, "Multiplexed HTTP + WebSocket server listening");

        loop {
            match listener.accept().await {
                Ok((stream, addr)) => {
                    let manager = Arc::clone(&manager);
                    let cache = Arc::clone(&cache);
                    tokio::spawn(async move {
                        let io = TokioIo::new(stream);
                        let service = hyper::service::service_fn(move |req| {
                            let cache = Arc::clone(&cache);
                            let manager = Arc::clone(&manager);
                            crate::http::serve_http(req, cache, manager)
                        });

                        if let Err(error) = http1::Builder::new()
                            .serve_connection(io, service)
                            .with_upgrades()
                            .await
                        {
                            // A connection drop or reset is normal and should not clutter logs at WARN/ERROR.
                            tracing::debug!(error = ?error, client_addr = %addr, "HTTP/WebSocket connection finished or closed");
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

/// Handle upgraded WebSocket connections on the Hyper multiplexed port.
pub async fn handle_upgraded_ws<S>(
    manager: Arc<SessionManager>,
    ws_stream: tokio_tungstenite::WebSocketStream<S>,
    format: triage_transport_ws::ProtocolFormat,
) -> Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    tracing::info!(?format, "Upgraded WebSocket client connected");

    let (mut ws_sender, mut ws_receiver) = ws_stream.split();
    let mut conn =
        WebSocketSessionConnection::with_authenticator(Arc::clone(&manager), Arc::clone(&manager))
            .with_format(format);

    let mut next_msg = ws_receiver.next();

    loop {
        tokio::select! {
            maybe_msg = &mut next_msg => {
                match maybe_msg {
                    Some(Ok(msg)) => {
                        match msg {
                            Message::Text(text) => {
                                if format == triage_transport_ws::ProtocolFormat::Json {
                                    let response = conn.handle_text_message(&text);
                                    if ws_sender.send(Message::Text(response)).await.is_err() {
                                        break;
                                    }
                                }
                            }
                            Message::Binary(bytes) => {
                                if format == triage_transport_ws::ProtocolFormat::Flatbuffers {
                                    let response = conn.handle_binary_message(&bytes);
                                    if ws_sender.send(Message::Binary(response)).await.is_err() {
                                        break;
                                    }
                                }
                            }
                            Message::Close(_) => {
                                tracing::info!("WebSocket client disconnected");
                                break;
                            }
                            _ => {}
                        }
                    }
                    Some(Err(err)) => {
                        tracing::info!(error = ?err, "WebSocket client connection error");
                        break;
                    }
                    None => {
                        tracing::info!("WebSocket client connection closed");
                        break;
                    }
                }
                next_msg = ws_receiver.next();
            }
            _ = tokio::time::sleep(Duration::from_millis(10)) => {
                let messages = conn.drain_events();
                let mut send_failed = false;
                for msg in messages {
                    match format {
                        triage_transport_ws::ProtocolFormat::Json => {
                            let serialized = serde_json::to_string(&msg)
                                .context("serializing session event")?;
                            if ws_sender.send(Message::Text(serialized)).await.is_err() {
                                send_failed = true;
                                break;
                            }
                        }
                        triage_transport_ws::ProtocolFormat::Flatbuffers => {
                            let serialized = triage_transport_ws::flatbuffers_proto::serialize_server_message(&msg);
                            if ws_sender.send(Message::Binary(serialized)).await.is_err() {
                                send_failed = true;
                                break;
                            }
                        }
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
