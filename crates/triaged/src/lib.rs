#![cfg_attr(unix, allow(unsafe_code))]

pub mod handover;
pub mod http;
#[cfg(unix)]
pub mod ipc;
pub mod session;
pub mod ws;

#[cfg(all(unix, test))]
mod handover_tests;
#[cfg(test)]
mod http_tests;
