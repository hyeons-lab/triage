//! Background update check (Phase 1 of the self-update epic).
//!
//! The daemon is the one always-on, network-capable component, so it owns the
//! "is a newer release available?" question and surfaces the answer to every
//! client over the session API. We deliberately answer it with
//! `git ls-remote --tags` over the git protocol rather than the GitHub releases
//! REST API: the workspace ships no outbound TLS/HTTP client, while `git` is
//! already a hard runtime dependency (handover, worktree grouping, and session
//! context all shell out to it). Asset *download* URLs will need the releases
//! API later, but the version check itself needs nothing new.
//!
//! Everything here is best-effort. A failed poll leaves the previous status in
//! place and never blocks the daemon; the next interval simply tries again.

use std::process::Command;
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use triage_core::config::UpdateConfig;

/// Public repository whose release tags define "the latest version". The git
/// protocol endpoint needs no auth and is not subject to the REST API rate
/// limit.
const RELEASE_REPO_URL: &str = "https://github.com/hyeons-lab/triage";

/// This daemon's own compiled version (the workspace `version`, e.g. `0.1.6`).
pub fn current_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// The result of the most recent update check. `latest` is `None` until the
/// first poll succeeds; `update_available` is only ever true once a strictly
/// newer release tag has been observed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UpdateStatus {
    /// The running daemon's version.
    pub current: String,
    /// The newest release tag seen so far, normalized without a leading `v`.
    pub latest: Option<String>,
    /// Whether `latest` is strictly newer than `current`.
    pub update_available: bool,
}

impl UpdateStatus {
    /// The status before any poll has completed: we know our own version, but
    /// not yet whether anything newer exists.
    pub fn current() -> Self {
        Self {
            current: current_version().to_string(),
            latest: None,
            update_available: false,
        }
    }
}

/// Spawn the background poll thread. A no-op when `config.check` is false, so
/// disabling the check costs nothing. The thread polls immediately, then once
/// per `interval_hours`, and invokes `on_update_available` exactly on the
/// transition into the "update available" state (not on every poll).
pub fn spawn_poller(
    config: UpdateConfig,
    status: Arc<RwLock<UpdateStatus>>,
    on_update_available: impl Fn(&UpdateStatus) + Send + 'static,
) {
    if !config.check {
        return;
    }
    let spawned = thread::Builder::new()
        .name("triage-update-poll".to_string())
        .spawn(move || run_poll_loop(config, status, on_update_available));
    if let Err(error) = spawned {
        tracing::warn!(error = ?error, "failed to spawn update-check thread; updates won't be detected");
    }
}

fn run_poll_loop(
    config: UpdateConfig,
    status: Arc<RwLock<UpdateStatus>>,
    on_update_available: impl Fn(&UpdateStatus),
) {
    // `interval_hours` is validated > 0, but guard the arithmetic anyway so a
    // surprising config can never spin this thread in a tight loop.
    let interval = Duration::from_secs(config.interval_hours.saturating_mul(3600).max(60));
    loop {
        match fetch_latest_tag(RELEASE_REPO_URL) {
            Ok(latest) => {
                let next = compute_status(current_version(), latest.as_deref());
                if let Some(newly_available) = store_status(&status, next.clone())
                    && newly_available
                {
                    tracing::info!(
                        current = %next.current,
                        latest = ?next.latest,
                        "a newer Triage release is available",
                    );
                    on_update_available(&next);
                }
            }
            Err(error) => {
                // Network blips, offline laptops, and DNS failures are expected;
                // keep the previous status and try again next interval.
                tracing::debug!(error = ?error, "update check failed; will retry");
            }
        }
        thread::sleep(interval);
    }
}

/// Write the new status, returning `Some(true)` when this write is the
/// transition into "update available", `Some(false)` otherwise, or `None` if
/// the lock was poisoned (in which case nothing was written).
fn store_status(status: &RwLock<UpdateStatus>, next: UpdateStatus) -> Option<bool> {
    let mut guard = status.write().ok()?;
    let newly_available = next.update_available && !guard.update_available;
    *guard = next;
    Some(newly_available)
}

/// Query the release host for the newest semver release tag, returning it
/// normalized without a leading `v` (e.g. `0.1.6`). Returns `Ok(None)` when the
/// remote has no parseable release tags. Errors only on the `git` invocation
/// itself failing.
pub fn fetch_latest_tag(repo_url: &str) -> Result<Option<String>> {
    let output = Command::new("git")
        .args(["ls-remote", "--tags", "--refs", repo_url])
        .output()
        .context("running git ls-remote to check for updates")?;
    if !output.status.success() {
        bail!(
            "git ls-remote failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(latest_tag_from_ls_remote(&String::from_utf8_lossy(
        &output.stdout,
    )))
}

/// Pick the highest semver tag out of `git ls-remote --tags` output. Pure so it
/// can be unit-tested without a network. Non-semver tags and prerelease tags
/// (anything that isn't a bare `X.Y.Z`) are ignored, which is exactly the
/// stable-channel policy.
fn latest_tag_from_ls_remote(text: &str) -> Option<String> {
    text.lines()
        .filter_map(|line| line.rsplit_once("refs/tags/").map(|(_, tag)| tag.trim()))
        .filter_map(|tag| parse_semver(tag).map(|version| (version, tag)))
        .max_by_key(|(version, _)| *version)
        .map(|(_, tag)| normalize_version(tag))
}

/// Strip a single leading `v` so versions compare as bare `X.Y.Z` strings.
fn normalize_version(tag: &str) -> String {
    tag.strip_prefix('v').unwrap_or(tag).to_string()
}

/// Parse a strict `X.Y.Z` (optionally `v`-prefixed) release tag. Anything with
/// fewer or more components, non-numeric parts, or a prerelease/build suffix
/// returns `None` and is treated as not-a-stable-release.
fn parse_semver(tag: &str) -> Option<(u64, u64, u64)> {
    let trimmed = tag.strip_prefix('v').unwrap_or(tag);
    let mut parts = trimmed.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((major, minor, patch))
}

/// Build an [`UpdateStatus`] from the running version and the latest observed
/// tag. `update_available` is true only when both parse and `latest` is
/// strictly greater than `current`.
pub fn compute_status(current: &str, latest_tag: Option<&str>) -> UpdateStatus {
    let latest = latest_tag.map(normalize_version);
    let update_available = match (
        parse_semver(current),
        latest.as_deref().and_then(parse_semver),
    ) {
        (Some(current), Some(latest)) => latest > current,
        _ => false,
    };
    UpdateStatus {
        current: current.to_string(),
        latest,
        update_available,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_semver_accepts_plain_and_v_prefixed() {
        assert_eq!(parse_semver("0.1.6"), Some((0, 1, 6)));
        assert_eq!(parse_semver("v0.1.6"), Some((0, 1, 6)));
        assert_eq!(parse_semver("v12.34.56"), Some((12, 34, 56)));
    }

    #[test]
    fn parse_semver_rejects_non_releases() {
        assert_eq!(parse_semver("v0.2.0-rc1"), None); // prerelease
        assert_eq!(parse_semver("1.2"), None); // too few components
        assert_eq!(parse_semver("1.2.3.4"), None); // too many components
        assert_eq!(parse_semver("latest"), None); // not numeric
        assert_eq!(parse_semver("v0.1.6^{}"), None); // peeled-tag artifact
    }

    #[test]
    fn picks_highest_tag_ignoring_noise() {
        // Mirrors real `git ls-remote --tags` output, including a peeled line,
        // a prerelease, and a non-version tag — all of which must be ignored.
        let sample = "\
abc123\trefs/tags/v0.1.0
def456\trefs/tags/v0.1.3
aaa111\trefs/tags/v0.1.4
bbb222\trefs/tags/v0.1.5
ccc333\trefs/tags/v0.2.0-rc1
ddd444\trefs/tags/nightly
eee555\trefs/tags/v0.1.5^{}";
        assert_eq!(latest_tag_from_ls_remote(sample), Some("0.1.5".to_string()));
    }

    #[test]
    fn empty_or_tagless_output_yields_none() {
        assert_eq!(latest_tag_from_ls_remote(""), None);
        assert_eq!(latest_tag_from_ls_remote("abc123\trefs/heads/main"), None);
    }

    #[test]
    fn compute_status_flags_newer_release() {
        let status = compute_status("0.1.5", Some("v0.1.6"));
        assert!(status.update_available);
        assert_eq!(status.latest.as_deref(), Some("0.1.6"));
        assert_eq!(status.current, "0.1.5");
    }

    #[test]
    fn compute_status_is_false_when_current_or_newer() {
        assert!(!compute_status("0.1.6", Some("0.1.6")).update_available); // equal
        assert!(!compute_status("0.2.0", Some("0.1.6")).update_available); // ahead
        assert!(!compute_status("0.1.6", None).update_available); // no poll yet
    }

    #[test]
    fn store_status_reports_only_the_transition() {
        let status = Arc::new(RwLock::new(UpdateStatus::current()));
        // First time we learn an update exists → transition.
        assert_eq!(
            store_status(&status, compute_status("0.1.5", Some("0.1.6"))),
            Some(true)
        );
        // Still available on the next poll → not a new transition.
        assert_eq!(
            store_status(&status, compute_status("0.1.5", Some("0.1.6"))),
            Some(false)
        );
    }
}
