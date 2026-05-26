use crate::{ClientMessage, ClientRequest, ServerMessage, ServerResult};
use flatbuffers::FlatBufferBuilder;
use triage_core::generated::triage::generated as fb;
use triage_core::session::{
    AttachMode, AttachSessionRequest, ClientId, InputControllerKind, InputLeaseRequest,
    ResizeSessionRequest, RestoreSessionRequest, SessionEvent, SessionId, StartSessionRequest,
    StyledRowsRequest, WriteInputRequest,
};

pub fn parse_client_message(msg: fb::ClientMessage<'_>) -> ClientMessage {
    let id = msg.id().map(|s| serde_json::Value::String(s.to_string()));
    let request = match msg.payload_type() {
        fb::ClientRequestPayload::HelloRequest => {
            let req = msg.payload_as_hello_request().unwrap();
            let client_id = req.client_id().map(|s| ClientId::new(s).unwrap());
            let token = req.token().map(|s| s.to_string());
            ClientRequest::Hello { client_id, token }
        }
        fb::ClientRequestPayload::PairRequest => {
            let req = msg.payload_as_pair_request().unwrap();
            let code = req.code().unwrap_or("").to_string();
            let client_id = ClientId::new(req.client_id().unwrap_or("")).unwrap();
            ClientRequest::Pair { code, client_id }
        }
        fb::ClientRequestPayload::ListSessionsRequest => ClientRequest::ListSessions,
        fb::ClientRequestPayload::StartSessionRequestTable => {
            let req = msg.payload_as_start_session_request_table().unwrap();
            let command = req.command().unwrap_or("").to_string();
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
            let fb_size = req.size().unwrap();
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
            let req = msg.payload_as_attach_session_request_table().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
            let client_id = ClientId::new(req.client_id().unwrap_or("")).unwrap();
            let mode = match req.mode() {
                fb::AttachMode::Observer => AttachMode::Observer,
                fb::AttachMode::InteractiveController => AttachMode::InteractiveController,
                fb::AttachMode::AgentController => AttachMode::AgentController,
                _ => AttachMode::Observer,
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
                .unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
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
            let req = msg.payload_as_acquire_input_lease_request().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
            let client_id = ClientId::new(req.client_id().unwrap_or("")).unwrap();
            let kind = match req.kind() {
                fb::InputControllerKind::Interactive => InputControllerKind::Interactive,
                fb::InputControllerKind::Agent => InputControllerKind::Agent,
                _ => InputControllerKind::Interactive,
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
            let req = msg.payload_as_release_input_lease_request().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
            let client_id = ClientId::new(req.client_id().unwrap_or("")).unwrap();
            ClientRequest::ReleaseInputLease {
                session_id,
                client_id,
            }
        }
        fb::ClientRequestPayload::WriteInputRequestTable => {
            let req = msg.payload_as_write_input_request_table().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
            let client_id = ClientId::new(req.client_id().unwrap_or("")).unwrap();
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
            let req = msg.payload_as_resize_session_request_table().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
            let fb_size = req.size().unwrap();
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
            let req = msg.payload_as_restore_session_request_table().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
            let fb_size = req.size().unwrap();
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
            let req = msg.payload_as_snapshot_session_request().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
            ClientRequest::SnapshotSession { session_id }
        }
        fb::ClientRequestPayload::StyledRowsRequestTable => {
            let req = msg.payload_as_styled_rows_request_table().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
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
            let req = msg.payload_as_shutdown_session_request().unwrap();
            let session_id = SessionId::new(req.session_id().unwrap_or("")).unwrap();
            ClientRequest::ShutdownSession { session_id }
        }
        _ => ClientRequest::ListSessions,
    };
    ClientMessage { id, request }
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
    };

    fb::ServerMessage::create(
        builder,
        &fb::ServerMessageArgs {
            payload_type,
            payload: Some(payload_offset),
        },
    )
}
