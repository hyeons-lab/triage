//! Shared test harness utilities for Triage crates.
//!
//! This crate is a workspace-only dependency for integration and acceptance
//! tests. It keeps renderer snapshot helpers and terminal byte fixtures in one
//! place so future daemon, TUI, and transport tests exercise the same behavior.

pub mod snapshots;
pub mod terminal_acceptance;
pub mod vt;
