#![cfg_attr(unix, allow(unsafe_code))]

pub mod handover;
#[cfg(unix)]
pub mod ipc;
pub mod session;
pub mod ws;

#[cfg(all(unix, test))]
mod handover_tests;
