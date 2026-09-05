#![cfg_attr(unix, allow(unsafe_code))]

pub mod handover;
pub mod http;
#[cfg(any(unix, windows))]
pub mod ipc;
pub mod judge;
pub mod service;
pub mod session;
#[cfg(unix)]
pub mod shutdown;
pub mod storage;
pub mod summarizer;
pub mod update;
pub mod ws;

#[cfg(all(unix, test))]
mod handover_tests;
#[cfg(test)]
mod http_tests;
#[cfg(test)]
mod storage_tests;
