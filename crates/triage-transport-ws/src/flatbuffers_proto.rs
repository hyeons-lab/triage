use crate::{ClientMessage, ClientRequest, ServerMessage, ServerResult};
use flatbuffers::FlatBufferBuilder;
use triage_core::generated::triage::generated as fb;
use triage_core::session::{
    AttachMode, AttachSessionRequest, ClientId, InputControllerKind, InputLeaseRequest,
    ResizeSessionRequest, RestoreSessionRequest, SessionEvent, SessionId, StartSessionRequest,
    StyledRowsRequest, WriteInputRequest,
};

pub fn parse_client_message(
    msg: fb::ClientMessage<'_>,
) -> Result<ClientMessage, crate::ProtocolError> {
    let id = msg.id().map(|s| serde_json::Value::String(s.to_string()));
    let request = match msg.payload_type() {
        fb::ClientRequestPayload::HelloRequest => {
            let req = msg.payload_as_hello_request().ok_or_else(|| {
                crate::ProtocolError::new("invalid_flatbuffer", "HelloRequest payload is missing")
            })?;
            let client_id =
                match req.client_id() {
                    Some(s) => Some(ClientId::new(s).map_err(|e| {
                        crate::ProtocolError::new("invalid_client_id", e.to_string())
                    })?),
                    None => None,
                };
            let token = req.token().map(|s| s.to_string());
            ClientRequest::Hello { client_id, token }
        }
        fb::ClientRequestPayload::PairRequest => {
            let req = msg.payload_as_pair_request().ok_or_else(|| {
                crate::ProtocolError::new("invalid_flatbuffer", "PairRequest payload is missing")
            })?;
            let code = req.code().unwrap_or("").to_string();
            let client_id_str = req.client_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "client_id is missing")
            })?;
            let client_id = ClientId::new(client_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_client_id", e.to_string()))?;
            ClientRequest::Pair { code, client_id }
        }
        fb::ClientRequestPayload::PairingChallengeRequest => {
            let req = msg.payload_as_pairing_challenge_request().ok_or_else(|| {
                crate::ProtocolError::new(
                    "invalid_flatbuffer",
                    "PairingChallengeRequest payload is missing",
                )
            })?;
            let client_id_str = req.client_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "client_id is missing")
            })?;
            let client_id = ClientId::new(client_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_client_id", e.to_string()))?;
            ClientRequest::PairingChallenge { client_id }
        }
        fb::ClientRequestPayload::ListSessionsRequest => ClientRequest::ListSessions,
        fb::ClientRequestPayload::StartSessionRequestTable => {
            let req = msg
                .payload_as_start_session_request_table()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "StartSessionRequestTable payload is missing",
                    )
                })?;
            let command = req
                .command()
                .ok_or_else(|| crate::ProtocolError::new("missing_field", "command is missing"))?
                .to_string();
            let mut args = Vec::new();
            if let Some(fb_args) = req.args() {
                for i in 0..fb_args.len() {
                    args.push(fb_args.get(i).to_string());
                }
            }
            let cwd = if req.cwd().unwrap_or("").is_empty() {
                None
            } else {
                Some(std::path::PathBuf::from(req.cwd().unwrap()))
            };
            let fb_size = req
                .size()
                .ok_or_else(|| crate::ProtocolError::new("missing_field", "size is missing"))?;
            let size = triage_core::session::SessionSize {
                rows: fb_size.rows() as usize,
                cols: fb_size.cols() as usize,
                pixel_width: fb_size.pixel_width() as usize,
                pixel_height: fb_size.pixel_height() as usize,
                dpi: fb_size.dpi() as usize,
            };
            ClientRequest::StartSession {
                request: StartSessionRequest {
                    command,
                    args,
                    cwd,
                    size,
                },
            }
        }
        fb::ClientRequestPayload::AttachSessionRequestTable => {
            let req = msg
                .payload_as_attach_session_request_table()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "AttachSessionRequestTable payload is missing",
                    )
                })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            let client_id_str = req.client_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "client_id is missing")
            })?;
            let client_id = ClientId::new(client_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_client_id", e.to_string()))?;
            let mode = match req.mode() {
                fb::AttachMode::Observer => AttachMode::Observer,
                fb::AttachMode::InteractiveController => AttachMode::InteractiveController,
                fb::AttachMode::AgentController => AttachMode::AgentController,
                other => {
                    return Err(crate::ProtocolError::new(
                        "invalid_enum",
                        format!("invalid AttachMode value: {:?}", other.0),
                    ));
                }
            };
            ClientRequest::AttachSession {
                request: AttachSessionRequest {
                    session_id,
                    client_id,
                    mode,
                },
            }
        }
        fb::ClientRequestPayload::SubscribeSessionEventsRequestTable => {
            let req = msg
                .payload_as_subscribe_session_events_request_table()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "SubscribeSessionEventsRequestTable payload is missing",
                    )
                })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            let after_event_seq = if req.after_event_seq() == 0 {
                None
            } else {
                Some(req.after_event_seq())
            };
            ClientRequest::SubscribeSessionEvents {
                request: triage_core::session::SubscribeSessionEventsRequest {
                    session_id,
                    after_event_seq,
                },
            }
        }
        fb::ClientRequestPayload::AcquireInputLeaseRequest => {
            let req = msg
                .payload_as_acquire_input_lease_request()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "AcquireInputLeaseRequest payload is missing",
                    )
                })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            let client_id_str = req.client_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "client_id is missing")
            })?;
            let client_id = ClientId::new(client_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_client_id", e.to_string()))?;
            let kind = match req.kind() {
                fb::InputControllerKind::Interactive => InputControllerKind::Interactive,
                fb::InputControllerKind::Agent => InputControllerKind::Agent,
                other => {
                    return Err(crate::ProtocolError::new(
                        "invalid_enum",
                        format!("invalid InputControllerKind value: {:?}", other.0),
                    ));
                }
            };
            ClientRequest::AcquireInputLease {
                request: InputLeaseRequest {
                    session_id,
                    client_id,
                    kind,
                },
            }
        }
        fb::ClientRequestPayload::ReleaseInputLeaseRequest => {
            let req = msg
                .payload_as_release_input_lease_request()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "ReleaseInputLeaseRequest payload is missing",
                    )
                })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            let client_id_str = req.client_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "client_id is missing")
            })?;
            let client_id = ClientId::new(client_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_client_id", e.to_string()))?;
            ClientRequest::ReleaseInputLease {
                session_id,
                client_id,
            }
        }
        fb::ClientRequestPayload::WriteInputRequestTable => {
            let req = msg.payload_as_write_input_request_table().ok_or_else(|| {
                crate::ProtocolError::new(
                    "invalid_flatbuffer",
                    "WriteInputRequestTable payload is missing",
                )
            })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            let client_id_str = req.client_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "client_id is missing")
            })?;
            let client_id = ClientId::new(client_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_client_id", e.to_string()))?;
            let mut bytes = Vec::new();
            if let Some(fb_bytes) = req.bytes() {
                bytes.extend_from_slice(fb_bytes.bytes());
            }
            ClientRequest::WriteInput {
                request: WriteInputRequest {
                    session_id,
                    client_id,
                    bytes,
                },
            }
        }
        fb::ClientRequestPayload::ResizeSessionRequestTable => {
            let req = msg
                .payload_as_resize_session_request_table()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "ResizeSessionRequestTable payload is missing",
                    )
                })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            let fb_size = req
                .size()
                .ok_or_else(|| crate::ProtocolError::new("missing_field", "size is missing"))?;
            let size = triage_core::session::SessionSize {
                rows: fb_size.rows() as usize,
                cols: fb_size.cols() as usize,
                pixel_width: fb_size.pixel_width() as usize,
                pixel_height: fb_size.pixel_height() as usize,
                dpi: fb_size.dpi() as usize,
            };
            ClientRequest::ResizeSession {
                request: ResizeSessionRequest { session_id, size },
            }
        }
        fb::ClientRequestPayload::RestoreSessionRequestTable => {
            let req = msg
                .payload_as_restore_session_request_table()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "RestoreSessionRequestTable payload is missing",
                    )
                })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            let fb_size = req
                .size()
                .ok_or_else(|| crate::ProtocolError::new("missing_field", "size is missing"))?;
            let size = triage_core::session::SessionSize {
                rows: fb_size.rows() as usize,
                cols: fb_size.cols() as usize,
                pixel_width: fb_size.pixel_width() as usize,
                pixel_height: fb_size.pixel_height() as usize,
                dpi: fb_size.dpi() as usize,
            };
            ClientRequest::RestoreSession {
                request: RestoreSessionRequest { session_id, size },
            }
        }
        fb::ClientRequestPayload::SnapshotSessionRequest => {
            let req = msg.payload_as_snapshot_session_request().ok_or_else(|| {
                crate::ProtocolError::new(
                    "invalid_flatbuffer",
                    "SnapshotSessionRequest payload is missing",
                )
            })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            ClientRequest::SnapshotSession { session_id }
        }
        fb::ClientRequestPayload::StyledRowsRequestTable => {
            let req = msg.payload_as_styled_rows_request_table().ok_or_else(|| {
                crate::ProtocolError::new(
                    "invalid_flatbuffer",
                    "StyledRowsRequestTable payload is missing",
                )
            })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            let start = req.start() as usize;
            let end = req.end() as usize;
            ClientRequest::StyledRows {
                request: StyledRowsRequest {
                    session_id,
                    start,
                    end,
                },
            }
        }
        fb::ClientRequestPayload::ShutdownSessionRequest => {
            let req = msg.payload_as_shutdown_session_request().ok_or_else(|| {
                crate::ProtocolError::new(
                    "invalid_flatbuffer",
                    "ShutdownSessionRequest payload is missing",
                )
            })?;
            let session_id_str = req.session_id().ok_or_else(|| {
                crate::ProtocolError::new("missing_field", "session_id is missing")
            })?;
            let session_id = SessionId::new(session_id_str)
                .map_err(|e| crate::ProtocolError::new("invalid_session_id", e.to_string()))?;
            ClientRequest::ShutdownSession { session_id }
        }
        fb::ClientRequestPayload::ListSessionSnippetsRequest => ClientRequest::ListSessionSnippets,
        _ => {
            return Err(crate::ProtocolError::new(
                "unsupported_payload",
                "The provided FlatBuffers payload type is not recognized or supported by Triage",
            ));
        }
    };
    Ok(ClientMessage { id, request })
}

pub fn serialize_client_message(msg: &ClientMessage) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let offset = build_client_message(&mut builder, msg);
    builder.finish(offset, None);
    builder.finished_data().to_vec()
}

pub fn build_client_message<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    msg: &ClientMessage,
) -> flatbuffers::WIPOffset<fb::ClientMessage<'a>> {
    let id_str = msg.id.as_ref().map(|v| match v {
        serde_json::Value::String(s) => s.clone(),
        v => v.to_string(),
    });
    let id_val = id_str.as_ref().map(|s| builder.create_string(s));

    let (payload_type, payload_offset) = match &msg.request {
        ClientRequest::Hello { client_id, token } => {
            let client_id_str = client_id
                .as_ref()
                .map(|id| builder.create_string(id.as_str()));
            let token_str = token.as_ref().map(|tok| builder.create_string(tok));
            let req = fb::HelloRequest::create(
                builder,
                &fb::HelloRequestArgs {
                    client_id: client_id_str,
                    token: token_str,
                },
            );
            (fb::ClientRequestPayload::HelloRequest, req.as_union_value())
        }
        ClientRequest::Pair { code, client_id } => {
            let code_str = builder.create_string(code);
            let client_id_str = builder.create_string(client_id.as_str());
            let req = fb::PairRequest::create(
                builder,
                &fb::PairRequestArgs {
                    code: Some(code_str),
                    client_id: Some(client_id_str),
                },
            );
            (fb::ClientRequestPayload::PairRequest, req.as_union_value())
        }
        ClientRequest::PairingChallenge { client_id } => {
            let client_id_str = builder.create_string(client_id.as_str());
            let req = fb::PairingChallengeRequest::create(
                builder,
                &fb::PairingChallengeRequestArgs {
                    client_id: Some(client_id_str),
                },
            );
            (
                fb::ClientRequestPayload::PairingChallengeRequest,
                req.as_union_value(),
            )
        }
        ClientRequest::ListSessions => {
            let req = fb::ListSessionsRequest::create(builder, &fb::ListSessionsRequestArgs {});
            (
                fb::ClientRequestPayload::ListSessionsRequest,
                req.as_union_value(),
            )
        }
        ClientRequest::StartSession { request } => {
            let cmd_str = builder.create_string(&request.command);
            let mut args_vec = Vec::new();
            for arg in &request.args {
                args_vec.push(builder.create_string(arg));
            }
            let args_offset = builder.create_vector(&args_vec);
            let cwd_str = request
                .cwd
                .as_ref()
                .map(|path| builder.create_string(&path.to_string_lossy()));
            let size = fb::SessionSize::new(
                request.size.rows as u32,
                request.size.cols as u32,
                request.size.pixel_width as u32,
                request.size.pixel_height as u32,
                request.size.dpi as u32,
            );
            let req = fb::StartSessionRequestTable::create(
                builder,
                &fb::StartSessionRequestTableArgs {
                    command: Some(cmd_str),
                    args: Some(args_offset),
                    cwd: cwd_str,
                    size: Some(&size),
                },
            );
            (
                fb::ClientRequestPayload::StartSessionRequestTable,
                req.as_union_value(),
            )
        }
        ClientRequest::AttachSession { request } => {
            let sess_id_str = builder.create_string(request.session_id.as_str());
            let client_id_str = builder.create_string(request.client_id.as_str());
            let mode = match request.mode {
                AttachMode::Observer => fb::AttachMode::Observer,
                AttachMode::InteractiveController => fb::AttachMode::InteractiveController,
                AttachMode::AgentController => fb::AttachMode::AgentController,
            };
            let req = fb::AttachSessionRequestTable::create(
                builder,
                &fb::AttachSessionRequestTableArgs {
                    session_id: Some(sess_id_str),
                    client_id: Some(client_id_str),
                    mode,
                },
            );
            (
                fb::ClientRequestPayload::AttachSessionRequestTable,
                req.as_union_value(),
            )
        }
        ClientRequest::SubscribeSessionEvents { request } => {
            let sess_id_str = builder.create_string(request.session_id.as_str());
            let req = fb::SubscribeSessionEventsRequestTable::create(
                builder,
                &fb::SubscribeSessionEventsRequestTableArgs {
                    session_id: Some(sess_id_str),
                    after_event_seq: request.after_event_seq.unwrap_or(0),
                },
            );
            (
                fb::ClientRequestPayload::SubscribeSessionEventsRequestTable,
                req.as_union_value(),
            )
        }
        ClientRequest::AcquireInputLease { request } => {
            let sess_id_str = builder.create_string(request.session_id.as_str());
            let client_id_str = builder.create_string(request.client_id.as_str());
            let kind = match request.kind {
                InputControllerKind::Interactive => fb::InputControllerKind::Interactive,
                InputControllerKind::Agent => fb::InputControllerKind::Agent,
            };
            let req = fb::AcquireInputLeaseRequest::create(
                builder,
                &fb::AcquireInputLeaseRequestArgs {
                    session_id: Some(sess_id_str),
                    client_id: Some(client_id_str),
                    kind,
                },
            );
            (
                fb::ClientRequestPayload::AcquireInputLeaseRequest,
                req.as_union_value(),
            )
        }
        ClientRequest::ReleaseInputLease {
            session_id,
            client_id,
        } => {
            let sess_id_str = builder.create_string(session_id.as_str());
            let client_id_str = builder.create_string(client_id.as_str());
            let req = fb::ReleaseInputLeaseRequest::create(
                builder,
                &fb::ReleaseInputLeaseRequestArgs {
                    session_id: Some(sess_id_str),
                    client_id: Some(client_id_str),
                },
            );
            (
                fb::ClientRequestPayload::ReleaseInputLeaseRequest,
                req.as_union_value(),
            )
        }
        ClientRequest::WriteInput { request } => {
            let sess_id_str = builder.create_string(request.session_id.as_str());
            let client_id_str = builder.create_string(request.client_id.as_str());
            let bytes_offset = builder.create_vector(&request.bytes);
            let req = fb::WriteInputRequestTable::create(
                builder,
                &fb::WriteInputRequestTableArgs {
                    session_id: Some(sess_id_str),
                    client_id: Some(client_id_str),
                    bytes: Some(bytes_offset),
                },
            );
            (
                fb::ClientRequestPayload::WriteInputRequestTable,
                req.as_union_value(),
            )
        }
        ClientRequest::ResizeSession { request } => {
            let sess_id_str = builder.create_string(request.session_id.as_str());
            let size = fb::SessionSize::new(
                request.size.rows as u32,
                request.size.cols as u32,
                request.size.pixel_width as u32,
                request.size.pixel_height as u32,
                request.size.dpi as u32,
            );
            let req = fb::ResizeSessionRequestTable::create(
                builder,
                &fb::ResizeSessionRequestTableArgs {
                    session_id: Some(sess_id_str),
                    size: Some(&size),
                },
            );
            (
                fb::ClientRequestPayload::ResizeSessionRequestTable,
                req.as_union_value(),
            )
        }
        ClientRequest::RestoreSession { request } => {
            let sess_id_str = builder.create_string(request.session_id.as_str());
            let size = fb::SessionSize::new(
                request.size.rows as u32,
                request.size.cols as u32,
                request.size.pixel_width as u32,
                request.size.pixel_height as u32,
                request.size.dpi as u32,
            );
            let req = fb::RestoreSessionRequestTable::create(
                builder,
                &fb::RestoreSessionRequestTableArgs {
                    session_id: Some(sess_id_str),
                    size: Some(&size),
                },
            );
            (
                fb::ClientRequestPayload::RestoreSessionRequestTable,
                req.as_union_value(),
            )
        }
        ClientRequest::SnapshotSession { session_id } => {
            let sess_id_str = builder.create_string(session_id.as_str());
            let req = fb::SnapshotSessionRequest::create(
                builder,
                &fb::SnapshotSessionRequestArgs {
                    session_id: Some(sess_id_str),
                },
            );
            (
                fb::ClientRequestPayload::SnapshotSessionRequest,
                req.as_union_value(),
            )
        }
        ClientRequest::StyledRows { request } => {
            let sess_id_str = builder.create_string(request.session_id.as_str());
            let req = fb::StyledRowsRequestTable::create(
                builder,
                &fb::StyledRowsRequestTableArgs {
                    session_id: Some(sess_id_str),
                    start: request.start as u32,
                    end: request.end as u32,
                },
            );
            (
                fb::ClientRequestPayload::StyledRowsRequestTable,
                req.as_union_value(),
            )
        }
        ClientRequest::ShutdownSession { session_id } => {
            let sess_id_str = builder.create_string(session_id.as_str());
            let req = fb::ShutdownSessionRequest::create(
                builder,
                &fb::ShutdownSessionRequestArgs {
                    session_id: Some(sess_id_str),
                },
            );
            (
                fb::ClientRequestPayload::ShutdownSessionRequest,
                req.as_union_value(),
            )
        }
        ClientRequest::ListSessionSnippets => {
            let req = fb::ListSessionSnippetsRequest::create(
                builder,
                &fb::ListSessionSnippetsRequestArgs {},
            );
            (
                fb::ClientRequestPayload::ListSessionSnippetsRequest,
                req.as_union_value(),
            )
        }
    };

    fb::ClientMessage::create(
        builder,
        &fb::ClientMessageArgs {
            id: id_val,
            payload_type,
            payload: Some(payload_offset),
        },
    )
}

pub fn serialize_server_message(msg: &ServerMessage) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let offset = build_server_message(&mut builder, msg);
    builder.finish(offset, None);
    builder.finished_data().to_vec()
}

pub fn build_server_message<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    msg: &ServerMessage,
) -> flatbuffers::WIPOffset<fb::ServerMessage<'a>> {
    let (payload_type, payload_offset) = match msg {
        ServerMessage::Response { id, result } => {
            let id_str = id.as_ref().map(|v| match v {
                serde_json::Value::String(s) => s.clone(),
                v => v.to_string(),
            });
            let id_val = id_str.as_ref().map(|s| builder.create_string(s));

            let (res_type, res_offset) = match result {
                ServerResult::Unit => {
                    let r = fb::UnitResult::create(builder, &fb::UnitResultArgs {});
                    (fb::ServerResultPayload::UnitResult, r.as_union_value())
                }
                ServerResult::Hello {
                    protocol_version,
                    authenticated,
                } => {
                    let pv = builder.create_string(protocol_version);
                    let r = fb::HelloResult::create(
                        builder,
                        &fb::HelloResultArgs {
                            protocol_version: Some(pv),
                            authenticated: *authenticated,
                        },
                    );
                    (fb::ServerResultPayload::HelloResult, r.as_union_value())
                }
                ServerResult::Paired { token } => {
                    let tok = builder.create_string(token);
                    let r = fb::PairedResult::create(
                        builder,
                        &fb::PairedResultArgs { token: Some(tok) },
                    );
                    (fb::ServerResultPayload::PairedResult, r.as_union_value())
                }
                ServerResult::PairingChallenge {
                    device_code,
                    expires_at,
                } => {
                    let device_code = builder.create_string(device_code);
                    let r = fb::PairingChallengeResult::create(
                        builder,
                        &fb::PairingChallengeResultArgs {
                            device_code: Some(device_code),
                            expires_at: *expires_at,
                        },
                    );
                    (
                        fb::ServerResultPayload::PairingChallengeResult,
                        r.as_union_value(),
                    )
                }
                ServerResult::SessionIds { session_ids } => {
                    let mut sids = Vec::new();
                    for s in session_ids {
                        sids.push(builder.create_string(s.as_str()));
                    }
                    let sids_vec = builder.create_vector(&sids);
                    let r = fb::SessionIdsResult::create(
                        builder,
                        &fb::SessionIdsResultArgs {
                            session_ids: Some(sids_vec),
                        },
                    );
                    (
                        fb::ServerResultPayload::SessionIdsResult,
                        r.as_union_value(),
                    )
                }
                ServerResult::SessionId { session_id } => {
                    let sid = builder.create_string(session_id.as_str());
                    let r = fb::SessionIdResult::create(
                        builder,
                        &fb::SessionIdResultArgs {
                            session_id: Some(sid),
                        },
                    );
                    (fb::ServerResultPayload::SessionIdResult, r.as_union_value())
                }
                ServerResult::AttachSession { response } => {
                    let resp = triage_core::flatbuffers_proto::build_attach_session_response(
                        builder, response,
                    );
                    let r = fb::AttachSessionResult::create(
                        builder,
                        &fb::AttachSessionResultArgs {
                            response: Some(resp),
                        },
                    );
                    (
                        fb::ServerResultPayload::AttachSessionResult,
                        r.as_union_value(),
                    )
                }
                ServerResult::Subscribed { subscription_id } => {
                    let sub = builder.create_string(subscription_id.as_str());
                    let r = fb::SubscribedResult::create(
                        builder,
                        &fb::SubscribedResultArgs {
                            subscription_id: Some(sub),
                        },
                    );
                    (
                        fb::ServerResultPayload::SubscribedResult,
                        r.as_union_value(),
                    )
                }
                ServerResult::LeaseChange { change } => {
                    let chg = triage_core::flatbuffers_proto::build_lease_change(builder, change);
                    let r = fb::LeaseChangeResult::create(
                        builder,
                        &fb::LeaseChangeResultArgs { change: Some(chg) },
                    );
                    (
                        fb::ServerResultPayload::LeaseChangeResult,
                        r.as_union_value(),
                    )
                }
                ServerResult::SessionSnapshot { snapshot } => {
                    let snap =
                        triage_core::flatbuffers_proto::build_session_snapshot(builder, snapshot);
                    let r = fb::SessionSnapshotResult::create(
                        builder,
                        &fb::SessionSnapshotResultArgs {
                            snapshot: Some(snap),
                        },
                    );
                    (
                        fb::ServerResultPayload::SessionSnapshotResult,
                        r.as_union_value(),
                    )
                }
                ServerResult::StyledRows { response } => {
                    let resp = triage_core::flatbuffers_proto::build_styled_rows_response(
                        builder, response,
                    );
                    let r = fb::StyledRowsResult::create(
                        builder,
                        &fb::StyledRowsResultArgs {
                            response: Some(resp),
                        },
                    );
                    (
                        fb::ServerResultPayload::StyledRowsResult,
                        r.as_union_value(),
                    )
                }
                ServerResult::CompletedSession { completed } => {
                    let comp =
                        triage_core::flatbuffers_proto::build_completed_session(builder, completed);
                    let r = fb::CompletedSessionResult::create(
                        builder,
                        &fb::CompletedSessionResultArgs {
                            completed: Some(comp),
                        },
                    );
                    (
                        fb::ServerResultPayload::CompletedSessionResult,
                        r.as_union_value(),
                    )
                }
                ServerResult::SessionSnippets { entries } => {
                    let mut entry_offsets = Vec::with_capacity(entries.len());
                    for entry in entries {
                        let sid = builder.create_string(entry.session_id.as_str());
                        let snip = entry.snippet.as_ref().map(|s| builder.create_string(s));
                        entry_offsets.push(fb::SessionSnippetEntry::create(
                            builder,
                            &fb::SessionSnippetEntryArgs {
                                session_id: Some(sid),
                                snippet: snip,
                            },
                        ));
                    }
                    let entries_vec = builder.create_vector(&entry_offsets);
                    let r = fb::SessionSnippetsResult::create(
                        builder,
                        &fb::SessionSnippetsResultArgs {
                            entries: Some(entries_vec),
                        },
                    );
                    (
                        fb::ServerResultPayload::SessionSnippetsResult,
                        r.as_union_value(),
                    )
                }
            };

            let res_payload = fb::ResponsePayload::create(
                builder,
                &fb::ResponsePayloadArgs {
                    id: id_val,
                    result_type: res_type,
                    result: Some(res_offset),
                },
            );
            (
                fb::ServerMessagePayload::ResponsePayload,
                res_payload.as_union_value(),
            )
        }
        ServerMessage::Error { id, error } => {
            let id_str = id.as_ref().map(|v| match v {
                serde_json::Value::String(s) => s.clone(),
                v => v.to_string(),
            });
            let id_val = id_str.as_ref().map(|s| builder.create_string(s));
            let code = builder.create_string(&error.code);
            let message = builder.create_string(&error.message);

            let err_payload = fb::ErrorPayload::create(
                builder,
                &fb::ErrorPayloadArgs {
                    id: id_val,
                    code: Some(code),
                    message: Some(message),
                },
            );
            (
                fb::ServerMessagePayload::ErrorPayload,
                err_payload.as_union_value(),
            )
        }
        ServerMessage::Event {
            subscription_id,
            envelope,
        } => {
            let sub = builder.create_string(subscription_id.as_str());

            let (evt_type, evt_offset) = match &envelope.event {
                SessionEvent::ResyncRequired {
                    session_id,
                    latest_event_seq,
                    snapshot,
                } => {
                    let sid = builder.create_string(session_id.as_str());
                    let snap =
                        triage_core::flatbuffers_proto::build_session_snapshot(builder, snapshot);
                    let e = fb::ResyncRequiredEvent::create(
                        builder,
                        &fb::ResyncRequiredEventArgs {
                            session_id: Some(sid),
                            latest_event_seq: *latest_event_seq,
                            snapshot: Some(snap),
                        },
                    );
                    (
                        fb::SessionEventPayload::ResyncRequiredEvent,
                        e.as_union_value(),
                    )
                }
                SessionEvent::Output {
                    session_id,
                    output_seq,
                    bytes,
                } => {
                    let sid = builder.create_string(session_id.as_str());
                    let bytes_vec = builder.create_vector(bytes);
                    let e = fb::OutputEvent::create(
                        builder,
                        &fb::OutputEventArgs {
                            session_id: Some(sid),
                            output_seq: *output_seq,
                            bytes: Some(bytes_vec),
                        },
                    );
                    (fb::SessionEventPayload::OutputEvent, e.as_union_value())
                }
                SessionEvent::Snapshot {
                    session_id,
                    snapshot,
                } => {
                    let sid = builder.create_string(session_id.as_str());
                    let snap =
                        triage_core::flatbuffers_proto::build_session_snapshot(builder, snapshot);
                    let e = fb::SnapshotEvent::create(
                        builder,
                        &fb::SnapshotEventArgs {
                            session_id: Some(sid),
                            snapshot: Some(snap),
                        },
                    );
                    (fb::SessionEventPayload::SnapshotEvent, e.as_union_value())
                }
                SessionEvent::LeaseChanged { session_id, change } => {
                    let sid = builder.create_string(session_id.as_str());
                    let chg = triage_core::flatbuffers_proto::build_lease_change(builder, change);
                    let e = fb::LeaseChangedEvent::create(
                        builder,
                        &fb::LeaseChangedEventArgs {
                            session_id: Some(sid),
                            change: Some(chg),
                        },
                    );
                    (
                        fb::SessionEventPayload::LeaseChangedEvent,
                        e.as_union_value(),
                    )
                }
                SessionEvent::Exited {
                    session_id,
                    completed,
                } => {
                    let sid = builder.create_string(session_id.as_str());
                    let comp =
                        triage_core::flatbuffers_proto::build_completed_session(builder, completed);
                    let e = fb::ExitedEvent::create(
                        builder,
                        &fb::ExitedEventArgs {
                            session_id: Some(sid),
                            completed: Some(comp),
                        },
                    );
                    (fb::SessionEventPayload::ExitedEvent, e.as_union_value())
                }
            };

            let evt_payload = fb::EventPayload::create(
                builder,
                &fb::EventPayloadArgs {
                    subscription_id: Some(sub),
                    event_seq: envelope.event_seq,
                    event_type: evt_type,
                    event: Some(evt_offset),
                },
            );
            (
                fb::ServerMessagePayload::EventPayload,
                evt_payload.as_union_value(),
            )
        }
        ServerMessage::SubscriptionClosed { subscription_id } => {
            let sub = builder.create_string(subscription_id.as_str());
            let sub_closed = fb::SubscriptionClosedPayload::create(
                builder,
                &fb::SubscriptionClosedPayloadArgs {
                    subscription_id: Some(sub),
                },
            );
            (
                fb::ServerMessagePayload::SubscriptionClosedPayload,
                sub_closed.as_union_value(),
            )
        }
        ServerMessage::SessionSnippetUpdated {
            session_id,
            snippet,
            output_seq,
        } => {
            let sid = builder.create_string(session_id.as_str());
            let snip = builder.create_string(snippet);
            let updated = fb::SessionSnippetUpdatedPayload::create(
                builder,
                &fb::SessionSnippetUpdatedPayloadArgs {
                    session_id: Some(sid),
                    snippet: Some(snip),
                    output_seq: *output_seq,
                },
            );
            (
                fb::ServerMessagePayload::SessionSnippetUpdatedPayload,
                updated.as_union_value(),
            )
        }
    };

    fb::ServerMessage::create(
        builder,
        &fb::ServerMessageArgs {
            payload_type,
            payload: Some(payload_offset),
        },
    )
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProtocolErrorBorrowed<'a> {
    pub code: &'a str,
    pub message: &'a str,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServerResultBorrowed<'a> {
    Unit,
    Hello {
        protocol_version: &'a str,
        authenticated: bool,
    },
    Paired {
        token: &'a str,
    },
    PairingChallenge {
        device_code: &'a str,
        expires_at: u64,
    },
    SessionIds {
        session_ids: Vec<&'a str>,
    },
    SessionId {
        session_id: &'a str,
    },
    AttachSession,
    Subscribed {
        subscription_id: &'a str,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum SessionEventBorrowed<'a> {
    Output {
        session_id: &'a str,
        output_seq: u64,
        bytes: &'a [u8],
    },
    ResyncRequired {
        session_id: &'a str,
        latest_event_seq: u64,
    },
    Snapshot {
        session_id: &'a str,
    },
    LeaseChanged {
        session_id: &'a str,
    },
    Exited {
        session_id: &'a str,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServerMessageBorrowed<'a> {
    Response {
        id: Option<&'a str>,
        result: ServerResultBorrowed<'a>,
    },
    Error {
        id: Option<&'a str>,
        error: ProtocolErrorBorrowed<'a>,
    },
    Event {
        subscription_id: &'a str,
        event_seq: u64,
        event: SessionEventBorrowed<'a>,
    },
    SubscriptionClosed {
        subscription_id: &'a str,
    },
    SessionSnippetUpdated {
        session_id: &'a str,
        snippet: &'a str,
        output_seq: u64,
    },
}

pub fn parse_fb_server_message_borrowed<'a>(
    bytes: &'a [u8],
) -> Result<ServerMessageBorrowed<'a>, crate::ProtocolError> {
    let root = flatbuffers::root::<fb::ServerMessage>(bytes)
        .map_err(|e| crate::ProtocolError::new("invalid_flatbuffer", e.to_string()))?;

    match root.payload_type() {
        fb::ServerMessagePayload::ResponsePayload => {
            let resp = root.payload_as_response_payload().ok_or_else(|| {
                crate::ProtocolError::new("invalid_flatbuffer", "missing response payload")
            })?;
            let id = resp.id();
            let result = match resp.result_type() {
                fb::ServerResultPayload::HelloResult => {
                    let hello = resp.result_as_hello_result().ok_or_else(|| {
                        crate::ProtocolError::new("invalid_flatbuffer", "missing hello result")
                    })?;
                    ServerResultBorrowed::Hello {
                        protocol_version: hello.protocol_version().unwrap_or(""),
                        authenticated: hello.authenticated(),
                    }
                }
                fb::ServerResultPayload::PairingChallengeResult => {
                    let challenge = resp.result_as_pairing_challenge_result().ok_or_else(|| {
                        crate::ProtocolError::new(
                            "invalid_flatbuffer",
                            "missing pairing challenge result",
                        )
                    })?;
                    ServerResultBorrowed::PairingChallenge {
                        device_code: challenge.device_code().unwrap_or(""),
                        expires_at: challenge.expires_at(),
                    }
                }
                fb::ServerResultPayload::SessionIdsResult => {
                    let sids_res = resp.result_as_session_ids_result().ok_or_else(|| {
                        crate::ProtocolError::new(
                            "invalid_flatbuffer",
                            "missing session ids result",
                        )
                    })?;
                    let mut session_ids = Vec::new();
                    if let Some(fb_sids) = sids_res.session_ids() {
                        for i in 0..fb_sids.len() {
                            session_ids.push(fb_sids.get(i));
                        }
                    }
                    ServerResultBorrowed::SessionIds { session_ids }
                }
                fb::ServerResultPayload::SessionIdResult => {
                    let sid_res = resp.result_as_session_id_result().ok_or_else(|| {
                        crate::ProtocolError::new("invalid_flatbuffer", "missing session id result")
                    })?;
                    ServerResultBorrowed::SessionId {
                        session_id: sid_res.session_id().unwrap_or(""),
                    }
                }
                fb::ServerResultPayload::AttachSessionResult => ServerResultBorrowed::AttachSession,
                fb::ServerResultPayload::SubscribedResult => {
                    let sub_res = resp.result_as_subscribed_result().ok_or_else(|| {
                        crate::ProtocolError::new("invalid_flatbuffer", "missing subscribed result")
                    })?;
                    ServerResultBorrowed::Subscribed {
                        subscription_id: sub_res.subscription_id().unwrap_or(""),
                    }
                }
                fb::ServerResultPayload::NONE => ServerResultBorrowed::Unit,
                _ => {
                    return Err(crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "unknown server result payload type",
                    ));
                }
            };
            Ok(ServerMessageBorrowed::Response { id, result })
        }
        fb::ServerMessagePayload::ErrorPayload => {
            let err = root.payload_as_error_payload().ok_or_else(|| {
                crate::ProtocolError::new("invalid_flatbuffer", "missing error payload")
            })?;
            let id = err.id();
            let code = err.code().unwrap_or("");
            let message = err.message().unwrap_or("");
            Ok(ServerMessageBorrowed::Error {
                id,
                error: ProtocolErrorBorrowed { code, message },
            })
        }
        fb::ServerMessagePayload::EventPayload => {
            let evt = root.payload_as_event_payload().ok_or_else(|| {
                crate::ProtocolError::new("invalid_flatbuffer", "missing event payload")
            })?;
            let subscription_id = evt.subscription_id().unwrap_or("");
            let event_seq = evt.event_seq();

            let event = match evt.event_type() {
                fb::SessionEventPayload::OutputEvent => {
                    let out = evt.event_as_output_event().ok_or_else(|| {
                        crate::ProtocolError::new("invalid_flatbuffer", "missing output event")
                    })?;
                    SessionEventBorrowed::Output {
                        session_id: out.session_id().unwrap_or(""),
                        output_seq: out.output_seq(),
                        bytes: out.bytes().map(|b| b.bytes()).unwrap_or(&[]),
                    }
                }
                fb::SessionEventPayload::ResyncRequiredEvent => {
                    let res = evt.event_as_resync_required_event().ok_or_else(|| {
                        crate::ProtocolError::new("invalid_flatbuffer", "missing resync event")
                    })?;
                    SessionEventBorrowed::ResyncRequired {
                        session_id: res.session_id().unwrap_or(""),
                        latest_event_seq: res.latest_event_seq(),
                    }
                }
                fb::SessionEventPayload::SnapshotEvent => {
                    let snap = evt.event_as_snapshot_event().ok_or_else(|| {
                        crate::ProtocolError::new("invalid_flatbuffer", "missing snapshot event")
                    })?;
                    SessionEventBorrowed::Snapshot {
                        session_id: snap.session_id().unwrap_or(""),
                    }
                }
                fb::SessionEventPayload::LeaseChangedEvent => {
                    let lease = evt.event_as_lease_changed_event().ok_or_else(|| {
                        crate::ProtocolError::new("invalid_flatbuffer", "missing lease event")
                    })?;
                    SessionEventBorrowed::LeaseChanged {
                        session_id: lease.session_id().unwrap_or(""),
                    }
                }
                fb::SessionEventPayload::ExitedEvent => {
                    let exited = evt.event_as_exited_event().ok_or_else(|| {
                        crate::ProtocolError::new("invalid_flatbuffer", "missing exited event")
                    })?;
                    SessionEventBorrowed::Exited {
                        session_id: exited.session_id().unwrap_or(""),
                    }
                }
                _ => {
                    return Err(crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "unknown session event type",
                    ));
                }
            };

            Ok(ServerMessageBorrowed::Event {
                subscription_id,
                event_seq,
                event,
            })
        }
        fb::ServerMessagePayload::SubscriptionClosedPayload => {
            let closed = root
                .payload_as_subscription_closed_payload()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "missing subscription closed payload",
                    )
                })?;
            Ok(ServerMessageBorrowed::SubscriptionClosed {
                subscription_id: closed.subscription_id().unwrap_or(""),
            })
        }
        fb::ServerMessagePayload::SessionSnippetUpdatedPayload => {
            let updated = root
                .payload_as_session_snippet_updated_payload()
                .ok_or_else(|| {
                    crate::ProtocolError::new(
                        "invalid_flatbuffer",
                        "missing session snippet updated payload",
                    )
                })?;
            Ok(ServerMessageBorrowed::SessionSnippetUpdated {
                session_id: updated.session_id().unwrap_or(""),
                snippet: updated.snippet().unwrap_or(""),
                output_seq: updated.output_seq(),
            })
        }
        _ => Err(crate::ProtocolError::new(
            "invalid_flatbuffer",
            "unknown server message payload type",
        )),
    }
}
