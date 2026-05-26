use anyhow::{Context, Result, anyhow};
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::time::interval;
use tokio_tungstenite::{
    connect_async, tungstenite::Message, tungstenite::client::IntoClientRequest,
};
use triage_core::generated::triage::generated as fb;
use triage_core::session::{
    AttachMode, AttachSessionRequest, ClientId, SessionId, SessionSize, StartSessionRequest,
    SubscribeSessionEventsRequest, WriteInputRequest,
};
use triage_transport_ws::{
    ClientMessage, ClientRequest, ServerMessage, ServerResult, flatbuffers_proto,
};

fn parse_args() -> (String, String, u64, u64, usize, Option<String>) {
    let mut url = "ws://127.0.0.1:8000/ws".to_string();
    let mut protocol = "json".to_string();
    let mut duration = 10;
    let mut rate = 100;
    let mut payload_size = 32;
    let mut session = None;

    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--url" => {
                if i + 1 < args.len() {
                    url = args[i + 1].clone();
                    i += 2;
                } else {
                    i += 1;
                }
            }
            "--protocol" => {
                if i + 1 < args.len() {
                    protocol = args[i + 1].clone();
                    i += 2;
                } else {
                    i += 1;
                }
            }
            "--duration" => {
                if i + 1 < args.len() {
                    duration = args[i + 1].parse().unwrap_or(10);
                    i += 2;
                } else {
                    i += 1;
                }
            }
            "--rate" => {
                if i + 1 < args.len() {
                    rate = args[i + 1].parse().unwrap_or(100);
                    i += 2;
                } else {
                    i += 1;
                }
            }
            "--payload-size" => {
                if i + 1 < args.len() {
                    payload_size = args[i + 1].parse().unwrap_or(32);
                    i += 2;
                } else {
                    i += 1;
                }
            }
            "--session" => {
                if i + 1 < args.len() {
                    session = Some(args[i + 1].clone());
                    i += 2;
                } else {
                    i += 1;
                }
            }
            _ => {
                i += 1;
            }
        }
    }
    (url, protocol, duration, rate, payload_size, session)
}

fn parse_fb_server_message(bytes: &[u8]) -> Result<ServerMessage> {
    let root = flatbuffers::root::<fb::ServerMessage>(bytes)?;
    match root.payload_type() {
        fb::ServerMessagePayload::ResponsePayload => {
            let resp = root
                .payload_as_response_payload()
                .ok_or_else(|| anyhow!("Missing response payload"))?;
            let id = resp
                .id()
                .map(|id| serde_json::Value::String(id.to_string()));

            match resp.result_type() {
                fb::ServerResultPayload::HelloResult => {
                    let hello = resp
                        .result_as_hello_result()
                        .ok_or_else(|| anyhow!("Missing HelloResult"))?;
                    Ok(ServerMessage::Response {
                        id,
                        result: ServerResult::Hello {
                            protocol_version: hello.protocol_version().unwrap_or("").to_string(),
                            authenticated: hello.authenticated(),
                        },
                    })
                }
                fb::ServerResultPayload::SessionIdsResult => {
                    let sids_res = resp
                        .result_as_session_ids_result()
                        .ok_or_else(|| anyhow!("Missing SessionIdsResult"))?;
                    let mut session_ids = Vec::new();
                    if let Some(fb_sids) = sids_res.session_ids() {
                        for i in 0..fb_sids.len() {
                            session_ids.push(SessionId::new(fb_sids.get(i)).unwrap());
                        }
                    }
                    Ok(ServerMessage::Response {
                        id,
                        result: ServerResult::SessionIds { session_ids },
                    })
                }
                fb::ServerResultPayload::SessionIdResult => {
                    let sid_res = resp
                        .result_as_session_id_result()
                        .ok_or_else(|| anyhow!("Missing SessionIdResult"))?;
                    let session_id = SessionId::new(sid_res.session_id().unwrap_or("")).unwrap();
                    Ok(ServerMessage::Response {
                        id,
                        result: ServerResult::SessionId { session_id },
                    })
                }
                fb::ServerResultPayload::AttachSessionResult => Ok(ServerMessage::Response {
                    id,
                    result: ServerResult::AttachSession {
                        response: triage_core::session::AttachSessionResponse {
                            snapshot: triage_core::session::SessionSnapshot {
                                output_seq: 0,
                                bytes_logged: 0,
                                size: triage_core::session::SessionSize::default(),
                                visible_rows: vec![],
                                styled_rows_start: 0,
                                styled_rows: vec![],
                                cursor: triage_core::session::TerminalCursor {
                                    row: 0,
                                    col: 0,
                                    visible: false,
                                },
                                current_working_directory: None,
                                context: None,
                                bracketed_paste_enabled: false,
                                exited: false,
                            },
                            lease: triage_core::session::InputLeaseState::default(),
                        },
                    },
                }),
                fb::ServerResultPayload::SubscribedResult => {
                    let sub_res = resp
                        .result_as_subscribed_result()
                        .ok_or_else(|| anyhow!("Missing SubscribedResult"))?;
                    let sub_id = triage_transport_ws::SubscriptionId::new(
                        sub_res.subscription_id().unwrap_or(""),
                    )
                    .unwrap();
                    Ok(ServerMessage::Response {
                        id,
                        result: ServerResult::Subscribed {
                            subscription_id: sub_id,
                        },
                    })
                }
                _ => Ok(ServerMessage::Response {
                    id,
                    result: ServerResult::Unit,
                }),
            }
        }
        fb::ServerMessagePayload::ErrorPayload => {
            let err = root
                .payload_as_error_payload()
                .ok_or_else(|| anyhow!("Missing error payload"))?;
            let id = err.id().map(|id| serde_json::Value::String(id.to_string()));
            let code = err.code().unwrap_or("").to_string();
            let message = err.message().unwrap_or("").to_string();
            Ok(ServerMessage::Error {
                id,
                error: triage_transport_ws::ProtocolError { code, message },
            })
        }
        _ => Ok(ServerMessage::Response {
            id: None,
            result: ServerResult::Unit,
        }),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let (url, protocol, duration_secs, rate, payload_size, session_id_arg) = parse_args();
    let use_fb = protocol.to_lowercase() == "flatbuffers";
    let subprotocol = if use_fb {
        "triage-flatbuffers"
    } else {
        "triage-json"
    };

    println!("Starting E2E stress testing tool...");
    println!("Target URL:        {}", url);
    println!("Protocol:          {}", protocol);
    println!("Negotiating subprotocol: {}", subprotocol);
    println!("Duration:          {} seconds", duration_secs);
    println!("Write rate:        {} writes/sec", rate);
    println!("Payload size:      {} bytes per write", payload_size);

    // 1. Establish connection
    let mut request = url.as_str().into_client_request().context("invalid URL")?;
    request.headers_mut().insert(
        "Sec-WebSocket-Protocol",
        tokio_tungstenite::tungstenite::http::HeaderValue::from_str(subprotocol)?,
    );

    let (ws_stream, response) = connect_async(request)
        .await
        .context("WebSocket connection failed")?;

    let negotiated = response
        .headers()
        .get("Sec-WebSocket-Protocol")
        .and_then(|val| val.to_str().ok())
        .unwrap_or("none");
    println!("Negotiated protocol: {}", negotiated);

    let (mut ws_sink, mut ws_stream) = ws_stream.split();

    // 2. Hello handshake
    let client_id = ClientId::new("stress-client-1").unwrap();
    let hello_msg = ClientMessage {
        id: Some(serde_json::Value::String("hello-req".to_string())),
        request: ClientRequest::Hello {
            client_id: Some(client_id.clone()),
            token: None,
        },
    };

    println!("Sending Hello message...");
    if use_fb {
        let bytes = flatbuffers_proto::serialize_client_message(&hello_msg);
        ws_sink.send(Message::Binary(bytes)).await?;
    } else {
        let text = serde_json::to_string(&hello_msg)?;
        ws_sink.send(Message::Text(text)).await?;
    }

    // Wait for hello response
    let hello_resp_raw = ws_stream
        .next()
        .await
        .ok_or_else(|| anyhow!("Connection closed immediately after Hello"))??;

    let server_hello = match hello_resp_raw {
        Message::Text(text) => {
            let msg: ServerMessage = serde_json::from_str(&text)?;
            msg
        }
        Message::Binary(bytes) => parse_fb_server_message(&bytes)?,
        _ => return Err(anyhow!("Unexpected response format for Hello")),
    };

    match server_hello {
        ServerMessage::Response {
            result:
                ServerResult::Hello {
                    protocol_version,
                    authenticated,
                },
            ..
        } => {
            println!(
                "Connected successfully. Protocol version: {}, Authenticated: {}",
                protocol_version, authenticated
            );
        }
        other => {
            return Err(anyhow!(
                "Hello handshake failed. Expected ServerMessage::Response(Hello), got: {:?}",
                other
            ));
        }
    }

    // 3. Resolve Session ID
    let session_id = if let Some(sid_str) = session_id_arg {
        SessionId::new(&sid_str).unwrap()
    } else {
        // First try to list sessions
        let list_msg = ClientMessage {
            id: Some(serde_json::Value::String("list-req".to_string())),
            request: ClientRequest::ListSessions,
        };
        if use_fb {
            ws_sink
                .send(Message::Binary(
                    flatbuffers_proto::serialize_client_message(&list_msg),
                ))
                .await?;
        } else {
            ws_sink
                .send(Message::Text(serde_json::to_string(&list_msg)?))
                .await?;
        }

        let resp_raw = ws_stream
            .next()
            .await
            .ok_or_else(|| anyhow!("Connection closed during session listing"))??;

        let server_resp = match resp_raw {
            Message::Text(text) => {
                let msg: ServerMessage = serde_json::from_str(&text)?;
                msg
            }
            Message::Binary(bytes) => parse_fb_server_message(&bytes)?,
            _ => return Err(anyhow!("Unexpected response format for ListSessions")),
        };

        let mut existing_id = None;
        if let ServerMessage::Response {
            result: ServerResult::SessionIds { session_ids },
            ..
        } = server_resp
        {
            existing_id = session_ids.first().cloned();
        }

        if let Some(sid) = existing_id {
            println!("Reusing existing session: {}", sid);
            sid
        } else {
            // Start a new session
            println!("No active session found. Spawning a new session...");
            let start_msg = ClientMessage {
                id: Some(serde_json::Value::String("start-req".to_string())),
                request: ClientRequest::StartSession {
                    request: StartSessionRequest {
                        command: if cfg!(windows) {
                            "cmd.exe".to_string()
                        } else {
                            "sh".to_string()
                        },
                        args: vec![],
                        cwd: None,
                        size: SessionSize::default(),
                    },
                },
            };
            if use_fb {
                ws_sink
                    .send(Message::Binary(
                        flatbuffers_proto::serialize_client_message(&start_msg),
                    ))
                    .await?;
            } else {
                ws_sink
                    .send(Message::Text(serde_json::to_string(&start_msg)?))
                    .await?;
            }

            let start_resp_raw = ws_stream
                .next()
                .await
                .ok_or_else(|| anyhow!("Connection closed during StartSession"))??;

            let start_resp = match start_resp_raw {
                Message::Text(text) => serde_json::from_str::<ServerMessage>(&text)?,
                Message::Binary(bytes) => parse_fb_server_message(&bytes)?,
                _ => return Err(anyhow!("Unexpected response format for StartSession")),
            };

            if let ServerMessage::Response {
                result: ServerResult::SessionId { session_id },
                ..
            } = start_resp
            {
                println!("Created new session: {}", session_id);
                session_id
            } else {
                return Err(anyhow!(
                    "Failed to start new session. Got: {:?}",
                    start_resp
                ));
            }
        }
    };

    // 4. Attach and Subscribe
    println!("Attaching to session: {} ...", session_id);
    let attach_msg = ClientMessage {
        id: Some(serde_json::Value::String("attach-req".to_string())),
        request: ClientRequest::AttachSession {
            request: AttachSessionRequest {
                session_id: session_id.clone(),
                client_id: client_id.clone(),
                mode: AttachMode::InteractiveController,
            },
        },
    };
    if use_fb {
        ws_sink
            .send(Message::Binary(
                flatbuffers_proto::serialize_client_message(&attach_msg),
            ))
            .await?;
    } else {
        ws_sink
            .send(Message::Text(serde_json::to_string(&attach_msg)?))
            .await?;
    }

    let attach_resp_raw = ws_stream
        .next()
        .await
        .ok_or_else(|| anyhow!("Connection closed during AttachSession"))??;
    let attach_resp = match attach_resp_raw {
        Message::Text(text) => serde_json::from_str::<ServerMessage>(&text)?,
        Message::Binary(bytes) => parse_fb_server_message(&bytes)?,
        _ => return Err(anyhow!("Unexpected response format for AttachSession")),
    };

    if let ServerMessage::Response {
        result: ServerResult::AttachSession { .. },
        ..
    } = attach_resp
    {
        println!("Successfully attached to session.");
    } else {
        return Err(anyhow!(
            "Failed to attach to session. Got: {:?}",
            attach_resp
        ));
    }

    // Subscribe
    println!("Subscribing to session events...");
    let sub_msg = ClientMessage {
        id: Some(serde_json::Value::String("sub-req".to_string())),
        request: ClientRequest::SubscribeSessionEvents {
            request: SubscribeSessionEventsRequest {
                session_id: session_id.clone(),
                after_event_seq: None,
            },
        },
    };
    if use_fb {
        ws_sink
            .send(Message::Binary(
                flatbuffers_proto::serialize_client_message(&sub_msg),
            ))
            .await?;
    } else {
        ws_sink
            .send(Message::Text(serde_json::to_string(&sub_msg)?))
            .await?;
    }

    let sub_resp_raw = ws_stream
        .next()
        .await
        .ok_or_else(|| anyhow!("Connection closed during SubscribeSessionEvents"))??;
    let sub_resp = match sub_resp_raw {
        Message::Text(text) => serde_json::from_str::<ServerMessage>(&text)?,
        Message::Binary(bytes) => parse_fb_server_message(&bytes)?,
        _ => {
            return Err(anyhow!(
                "Unexpected response format for SubscribeSessionEvents"
            ));
        }
    };

    if let ServerMessage::Response {
        result: ServerResult::Subscribed { .. },
        ..
    } = sub_resp
    {
        println!("Successfully subscribed to session events.");
    } else {
        return Err(anyhow!(
            "Failed to subscribe to session events. Got: {:?}",
            sub_resp
        ));
    }

    // 5. Stress loop
    println!("Beginning stress loop...");
    let is_running = Arc::new(AtomicBool::new(true));
    let sent_count = Arc::new(AtomicU64::new(0));
    let received_count = Arc::new(AtomicU64::new(0));
    let output_event_count = Arc::new(AtomicU64::new(0));
    let bytes_received = Arc::new(AtomicU64::new(0));

    let run_sender = is_running.clone();
    let sent_count_sender = sent_count.clone();
    let payload = vec![b'A'; payload_size];
    let sess_id_clone = session_id.clone();
    let client_id_clone = client_id.clone();

    // Spawn high-frequency sender task
    let mut ws_sink = ws_sink;
    let sender_task = tokio::spawn(async move {
        let mut tick = interval(Duration::from_nanos(1_000_000_000 / rate));
        let mut msg_seq = 0;
        while run_sender.load(Ordering::Relaxed) {
            tick.tick().await;
            msg_seq += 1;
            let write_msg = ClientMessage {
                id: Some(serde_json::Value::String(format!("w-{}", msg_seq))),
                request: ClientRequest::WriteInput {
                    request: WriteInputRequest {
                        session_id: sess_id_clone.clone(),
                        client_id: client_id_clone.clone(),
                        bytes: payload.clone(),
                    },
                },
            };

            let send_result = if use_fb {
                let bytes = flatbuffers_proto::serialize_client_message(&write_msg);
                ws_sink.send(Message::Binary(bytes)).await
            } else {
                let text = serde_json::to_string(&write_msg).unwrap();
                ws_sink.send(Message::Text(text)).await
            };

            if send_result.is_err() {
                break;
            }
            sent_count_sender.fetch_add(1, Ordering::Relaxed);
        }
        // Send close frame
        let _ = ws_sink.send(Message::Close(None)).await;
    });

    // Receiver task
    let run_receiver = is_running.clone();
    let received_count_receiver = received_count.clone();
    let output_event_count_receiver = output_event_count.clone();
    let bytes_received_receiver = bytes_received.clone();

    let mut ws_stream = ws_stream;
    let receiver_task = tokio::spawn(async move {
        while run_receiver.load(Ordering::Relaxed) {
            match ws_stream.next().await {
                Some(Ok(msg)) => {
                    received_count_receiver.fetch_add(1, Ordering::Relaxed);
                    match msg {
                        Message::Text(text) => {
                            bytes_received_receiver.fetch_add(text.len() as u64, Ordering::Relaxed);
                            if let Ok(ServerMessage::Event {
                                envelope:
                                    triage_core::session::SessionEventEnvelope {
                                        event: triage_core::session::SessionEvent::Output { .. },
                                        ..
                                    },
                                ..
                            }) = serde_json::from_str::<ServerMessage>(&text)
                            {
                                output_event_count_receiver.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                        Message::Binary(bytes) => {
                            bytes_received_receiver
                                .fetch_add(bytes.len() as u64, Ordering::Relaxed);
                            if let Ok(root) = flatbuffers::root::<fb::ServerMessage>(&bytes) {
                                let is_event =
                                    root.payload_type() == fb::ServerMessagePayload::EventPayload;
                                let is_output = is_event
                                    && root.payload_as_event_payload().is_some_and(|ep| {
                                        ep.event_type() == fb::SessionEventPayload::OutputEvent
                                    });
                                if is_output {
                                    output_event_count_receiver.fetch_add(1, Ordering::Relaxed);
                                }
                            }
                        }
                        Message::Close(_) => {
                            break;
                        }
                        _ => {}
                    }
                }
                _ => break,
            }
        }
    });

    // Run for duration
    let start_time = Instant::now();
    tokio::time::sleep(Duration::from_secs(duration_secs)).await;
    is_running.store(false, Ordering::Relaxed);

    // Clean up tasks
    let _ = sender_task.await;
    let _ = receiver_task.await;
    let elapsed = start_time.elapsed().as_secs_f64();

    // 6. Metrics report
    let total_sent = sent_count.load(Ordering::Relaxed);
    let total_recv = received_count.load(Ordering::Relaxed);
    let total_outputs = output_event_count.load(Ordering::Relaxed);
    let total_bytes = bytes_received.load(Ordering::Relaxed);

    println!("\n================ STRESS TEST RESULTS ================");
    println!("Protocol:            {}", protocol);
    println!("Actual Duration:     {:.2} seconds", elapsed);
    println!("Total Messages Sent: {}", total_sent);
    println!("Total Messages Recv: {}", total_recv);
    println!("Output Events Recv:  {}", total_outputs);
    println!(
        "Total Bytes Recv:    {} bytes ({:.2} KB)",
        total_bytes,
        total_bytes as f64 / 1024.0
    );
    println!("-----------------------------------------------------");
    println!(
        "Send rate:           {:.2} msgs/sec",
        total_sent as f64 / elapsed
    );
    println!(
        "Receive rate:        {:.2} msgs/sec",
        total_recv as f64 / elapsed
    );
    println!(
        "Throughput:          {:.2} KB/sec",
        (total_bytes as f64 / 1024.0) / elapsed
    );
    println!("=====================================================");

    Ok(())
}
