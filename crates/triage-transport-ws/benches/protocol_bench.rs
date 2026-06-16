use criterion::{Criterion, criterion_group, criterion_main};
use triage_core::session::{
    AttachSessionResponse, InputLeaseState, SessionEvent, SessionEventEnvelope, SessionId,
    SessionSize, SessionSnapshot, TerminalCursor,
};
use triage_transport_ws::{ServerMessage, ServerResult, SubscriptionId, flatbuffers_proto};

fn bench_serialization(c: &mut Criterion) {
    let mut group = c.benchmark_group("serialization");

    // 1. Setup attach message (~150 bytes)
    let attach_msg = ServerMessage::Response {
        id: Some(serde_json::Value::String("req-123".to_string())),
        result: ServerResult::AttachSession {
            response: AttachSessionResponse {
                snapshot: SessionSnapshot {
                    output_seq: 100,
                    bytes_logged: 500,
                    size: SessionSize::default(),
                    visible_rows: vec!["line 1".to_string(), "line 2".to_string()],
                    styled_rows_start: 0,
                    styled_rows: vec![],
                    cursor: TerminalCursor {
                        row: 5,
                        col: 10,
                        visible: true,
                    },
                    current_working_directory: Some(std::path::PathBuf::from("/usr/bin")),
                    context: None,
                    bracketed_paste_enabled: false,
                    exited: false,
                    raw_output: Vec::new(),
                    raw_output_start: 0,
                    snippet: None,
                    snippet_detail: None,
                },
                lease: InputLeaseState::default(),
            },
        },
    };

    // 2. Setup standard 4KB output
    let std_out_msg = ServerMessage::Event {
        subscription_id: SubscriptionId::new("sub-1").unwrap(),
        envelope: SessionEventEnvelope {
            event_seq: 42,
            event: SessionEvent::Output {
                session_id: SessionId::new("sess-1").unwrap(),
                output_seq: 101,
                bytes: vec![b'A'; 4096],
            },
        },
    };

    // 3. Setup stress 256KB output
    let stress_out_msg = ServerMessage::Event {
        subscription_id: SubscriptionId::new("sub-1").unwrap(),
        envelope: SessionEventEnvelope {
            event_seq: 43,
            event: SessionEvent::Output {
                session_id: SessionId::new("sess-1").unwrap(),
                output_seq: 102,
                bytes: vec![b'B'; 256 * 1024],
            },
        },
    };

    // Bench Attach Payload
    group.bench_function("attach_payload_json", |b| {
        b.iter(|| {
            let _ = serde_json::to_string(&attach_msg).unwrap();
        })
    });
    group.bench_function("attach_payload_flatbuffers", |b| {
        b.iter(|| {
            let _ = flatbuffers_proto::serialize_server_message(&attach_msg);
        })
    });

    // Bench Standard Output (4KB)
    group.bench_function("std_output_4kb_json", |b| {
        b.iter(|| {
            let _ = serde_json::to_string(&std_out_msg).unwrap();
        })
    });
    group.bench_function("std_output_4kb_flatbuffers", |b| {
        b.iter(|| {
            let _ = flatbuffers_proto::serialize_server_message(&std_out_msg);
        })
    });

    // Bench Stress Output (256KB)
    group.bench_function("stress_output_256kb_json", |b| {
        b.iter(|| {
            let _ = serde_json::to_string(&stress_out_msg).unwrap();
        })
    });
    group.bench_function("stress_output_256kb_flatbuffers", |b| {
        b.iter(|| {
            let _ = flatbuffers_proto::serialize_server_message(&stress_out_msg);
        })
    });

    group.finish();
}

fn bench_deserialization(c: &mut Criterion) {
    let mut group = c.benchmark_group("deserialization");

    // 1. Setup serialized JSON string
    let attach_msg = ServerMessage::Response {
        id: Some(serde_json::Value::String("req-123".to_string())),
        result: ServerResult::AttachSession {
            response: AttachSessionResponse {
                snapshot: SessionSnapshot {
                    output_seq: 100,
                    bytes_logged: 500,
                    size: SessionSize::default(),
                    visible_rows: vec!["line 1".to_string(), "line 2".to_string()],
                    styled_rows_start: 0,
                    styled_rows: vec![],
                    cursor: TerminalCursor {
                        row: 5,
                        col: 10,
                        visible: true,
                    },
                    current_working_directory: Some(std::path::PathBuf::from("/usr/bin")),
                    context: None,
                    bracketed_paste_enabled: false,
                    exited: false,
                    raw_output: Vec::new(),
                    raw_output_start: 0,
                    snippet: None,
                    snippet_detail: None,
                },
                lease: InputLeaseState::default(),
            },
        },
    };
    let json_str = serde_json::to_string(&attach_msg).unwrap();

    // 2. Setup serialized FlatBuffers bytes
    let fb_bytes = flatbuffers_proto::serialize_server_message(&attach_msg);

    // Bench JSON parsing
    group.bench_function("json_deserialize", |b| {
        b.iter(|| {
            let _: ServerMessage = serde_json::from_str(&json_str).unwrap();
        })
    });

    // Bench FlatBuffers reading (safe parsing)
    group.bench_function("flatbuffers_deserialize", |b| {
        b.iter(|| {
            let msg =
                ::flatbuffers::root::<triage_core::generated::triage::generated::ServerMessage>(
                    &fb_bytes,
                )
                .unwrap();
            // Force access to snapshot field to simulate real-world read cost
            let payload = msg.payload_as_response_payload().unwrap();
            let result = payload.result_as_attach_session_result().unwrap();
            let response = result.response().unwrap();
            let snapshot = response.snapshot().unwrap();
            let _ = snapshot.output_seq();
        })
    });

    group.finish();
}

criterion_group!(benches, bench_serialization, bench_deserialization);
criterion_main!(benches);
