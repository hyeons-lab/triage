#![cfg_attr(unix, allow(unsafe_code))]

pub mod handover;
pub mod http;
#[cfg(any(unix, windows))]
pub mod ipc;
pub mod service;
pub mod session;
pub mod summarizer;
pub mod ws;

#[cfg(all(unix, test))]
mod handover_tests;
#[cfg(test)]
mod http_tests;
