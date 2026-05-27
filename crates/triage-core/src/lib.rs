pub mod config;
pub mod logging;
pub mod session;

#[allow(
    unsafe_code,
    clippy::all,
    unused_imports,
    dead_code,
    mismatched_lifetime_syntaxes,
    unsafe_op_in_unsafe_fn
)]
pub mod generated {
    include!(concat!(env!("OUT_DIR"), "/triage_generated.rs"));
}

pub mod flatbuffers_proto;
