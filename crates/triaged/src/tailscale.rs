//! Tailscale identity resolution for SSO pairing.
//!
//! When `remote.tailscale_pair_users` is configured, pairing mints a token
//! only for peers whose tailnet login is allowlisted. Identity comes from the
//! local tailscaled's answer about the peer's source IP (`tailscale whois`)
//! — never from the IP itself, which is spoofable — and every failure mode
//! denies (fail closed): missing CLI, timeout, non-zero exit, malformed JSON,
//! unparseable login, or no allowlist match.
//!
//! The CLI shellout is deliberate: the `tailscale` binary owns LocalAPI socket
//! discovery and macOS GUI same-user-proof auth on every platform, and pairing
//! is one-time-per-device so subprocess cost is irrelevant.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;
use triage_core::config::TAGGED_DEVICES_LOGIN;

use crate::session::run_command_with_timeout;

/// Subprocess budget for one `tailscale whois` call.
const TAILSCALE_WHOIS_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a *successful* lookup is reused. Tailnet IP-to-login mappings
/// change only when nodes or users change (rare), while reconnects are
/// common, and each cold pair pays ~300ms for the subprocess on the load
/// path. Five minutes keeps identity changes effective quickly while making
/// reconnect pairs free.
const WHOIS_CACHE_TTL: Duration = Duration::from_secs(300);
/// How long a *failed* lookup is cached. Far shorter than [`WHOIS_CACHE_TTL`]
/// so a transient failure (timeout, tailscaled reload) denies a legitimate
/// allowlisted user for at most this long.
const WHOIS_NEGATIVE_CACHE_TTL: Duration = Duration::from_secs(1);
/// Cap on cached peers so a flood of unique fresh peers can't grow the map
/// without bound; overflow evicts expired entries, then an arbitrary one.
const WHOIS_CACHE_MAX_ENTRIES: usize = 1024;

#[derive(Debug, Deserialize)]
struct TailscaleWhois {
    #[serde(rename = "UserProfile")]
    user_profile: Option<TailscaleUserProfile>,
}

#[derive(Debug, Deserialize)]
struct TailscaleUserProfile {
    #[serde(rename = "LoginName")]
    login_name: Option<String>,
}

fn parse_tailscale_whois_login(input: &[u8]) -> Option<String> {
    let whois: TailscaleWhois = serde_json::from_slice(input).ok()?;
    whois
        .user_profile?
        .login_name
        .as_deref()
        .and_then(normalize_tailnet_login)
}

fn normalize_tailnet_login(login: &str) -> Option<String> {
    let login = login.trim().to_lowercase();
    (!login.is_empty()).then_some(login)
}

/// Whether a whois-reported login authorizes pairing. The daemon's allowlist
/// entries are normalized the same way before comparison. `tagged-devices`
/// never matches even if allowlisted (config validation also rejects it).
pub fn tailnet_login_is_allowed(login: &str, tailnet_allowlist: &[String]) -> bool {
    let Some(login) = normalize_tailnet_login(login) else {
        return false;
    };
    if login == TAGGED_DEVICES_LOGIN {
        return false;
    }
    tailnet_allowlist
        .iter()
        .filter_map(|allowed| normalize_tailnet_login(allowed))
        .any(|allowed| allowed == login)
}

fn mapped_ipv4(ip: IpAddr) -> Option<Ipv4Addr> {
    match ip {
        IpAddr::V4(ip) => Some(ip),
        IpAddr::V6(ip) => ip.to_ipv4_mapped(),
    }
}

/// Canonicalize the peer address for the whois argument: unmap IPv4-mapped
/// IPv6 so `::ffff:100.x.y.z` and `100.x.y.z` resolve (and cache) identically.
/// A real IPv6 address passes through untouched.
fn whois_addr_arg(addr: SocketAddr) -> String {
    match mapped_ipv4(addr.ip()) {
        Some(v4) => SocketAddr::new(IpAddr::V4(v4), addr.port()).to_string(),
        None => addr.to_string(),
    }
}

fn unmapped_ip(ip: IpAddr) -> IpAddr {
    mapped_ipv4(ip).map_or(ip, IpAddr::V4)
}

/// Candidate `tailscale` binaries, tried in order until one yields a
/// parseable answer. The search also stops at the first working CLI that
/// answers with valid JSON, since other paths to the same tailscaled cannot
/// change the answer (see [`judge_whois_output`]). The daemon usually runs under
/// launchd/systemd with a minimal `PATH`, so absolute locations come before
/// the bare `PATH` lookup. Notably absent: the macOS GUI app bundle binary,
/// which requires a GUI context and fails headless — resolvable but
/// unrunnable here.
const TAILSCALE_CANDIDATE_BINARIES: &[&str] = &[
    "/opt/homebrew/bin/tailscale",
    "/usr/bin/tailscale",
    "/usr/local/bin/tailscale",
    "tailscale",
];

/// Verdict for one candidate binary's whois attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WhoisCandidateVerdict {
    /// Parseable login: use this output, stop searching.
    Use,
    /// No login, but a working CLI answered (tagged device, unknown peer):
    /// other paths to the same tailscaled cannot change the answer.
    Stop,
    /// Binary missing/broken/timed out, or garbage output: try the next one.
    Next,
}

fn judge_whois_output(output: Option<&[u8]>) -> WhoisCandidateVerdict {
    let Some(output) = output else {
        return WhoisCandidateVerdict::Next;
    };
    if parse_tailscale_whois_login(output).is_some() {
        return WhoisCandidateVerdict::Use;
    }
    if serde_json::from_slice::<serde_json::Value>(output).is_ok() {
        return WhoisCandidateVerdict::Stop;
    }
    WhoisCandidateVerdict::Next
}

fn run_tailscale_whois(peer: SocketAddr) -> Option<Vec<u8>> {
    let arg = whois_addr_arg(peer);
    for binary in TAILSCALE_CANDIDATE_BINARIES {
        let mut command = std::process::Command::new(binary);
        command.arg("whois").arg("--json").arg(&arg);
        let output = run_command_with_timeout(command, TAILSCALE_WHOIS_TIMEOUT);
        match judge_whois_output(output.as_deref()) {
            WhoisCandidateVerdict::Use => return output,
            WhoisCandidateVerdict::Stop => return None,
            WhoisCandidateVerdict::Next => continue,
        }
    }
    None
}

struct CachedLogin {
    login: Option<String>,
    expires_at: Instant,
}

impl CachedLogin {
    fn successful(login: String) -> Self {
        Self {
            login: Some(login),
            expires_at: Instant::now() + WHOIS_CACHE_TTL,
        }
    }

    fn failed() -> Self {
        Self {
            login: None,
            expires_at: Instant::now() + WHOIS_NEGATIVE_CACHE_TTL,
        }
    }

    fn is_fresh(&self) -> bool {
        self.expires_at > Instant::now()
    }
}

/// Short-TTL cache over `tailscale whois`, fail-closed throughout.
///
/// At most one subprocess runs at a time (a contended lookup denies rather
/// than queues), so a flood of pair attempts can't fork-bomb the host.
pub struct TailnetPairing {
    cache: Mutex<HashMap<IpAddr, CachedLogin>>,
    inflight: Mutex<()>,
    run_whois: fn(SocketAddr) -> Option<Vec<u8>>,
}

impl TailnetPairing {
    pub fn new() -> Self {
        Self {
            cache: Mutex::new(HashMap::new()),
            inflight: Mutex::new(()),
            run_whois: run_tailscale_whois,
        }
    }

    #[cfg(test)]
    pub(crate) fn with_runner(run_whois: fn(SocketAddr) -> Option<Vec<u8>>) -> Self {
        Self {
            cache: Mutex::new(HashMap::new()),
            inflight: Mutex::new(()),
            run_whois,
        }
    }

    /// Resolve the peer's tailnet login, consulting the cache first. `None`
    /// denies: poisoned locks, a busy resolver, subprocess failure, and
    /// unparseable output all fail closed.
    pub fn resolve_login(&self, peer: SocketAddr) -> Option<String> {
        let ip = unmapped_ip(peer.ip());
        if let Ok(cache) = self.cache.lock()
            && let Some(hit) = cache.get(&ip)
            && hit.is_fresh()
        {
            return hit.login.clone();
        }
        let _single = self.inflight.try_lock().ok()?;
        let login = (self.run_whois)(peer).and_then(|out| parse_tailscale_whois_login(&out));
        if let Ok(mut cache) = self.cache.lock() {
            evict_overflow(&mut cache, &ip);
            let entry = match login.clone() {
                Some(login) => CachedLogin::successful(login),
                None => CachedLogin::failed(),
            };
            cache.insert(ip, entry);
        }
        login
    }
}

impl Default for TailnetPairing {
    fn default() -> Self {
        Self::new()
    }
}

fn evict_overflow(cache: &mut HashMap<IpAddr, CachedLogin>, incoming: &IpAddr) {
    if cache.contains_key(incoming) || cache.len() < WHOIS_CACHE_MAX_ENTRIES {
        return;
    }
    cache.retain(|_, entry| entry.is_fresh());
    if cache.len() >= WHOIS_CACHE_MAX_ENTRIES
        && let Some(victim) = cache.keys().next().cloned()
    {
        cache.remove(&victim);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn whois_output(login: &str) -> Vec<u8> {
        format!(r#"{{"Node":{{}},"UserProfile":{{"LoginName":"{login}"}}}}"#).into_bytes()
    }

    #[test]
    fn parse_returns_normalized_login() {
        assert_eq!(
            parse_tailscale_whois_login(&whois_output("  David@Hyeons-Lab.com ")),
            Some("david@hyeons-lab.com".to_string())
        );
    }

    #[test]
    fn parse_rejects_missing_and_malformed() {
        assert_eq!(parse_tailscale_whois_login(b"{}"), None);
        assert_eq!(parse_tailscale_whois_login(b"{"), None);
        assert_eq!(parse_tailscale_whois_login(&whois_output("   ")), None);
        assert_eq!(parse_tailscale_whois_login(br#"{"UserProfile":{}}"#), None);
    }

    #[test]
    fn allowlist_match_is_case_insensitive() {
        let allowlist = vec!["David@Hyeons-Lab.com".to_string()];
        assert!(tailnet_login_is_allowed("david@hyeons-lab.com", &allowlist));
        assert!(!tailnet_login_is_allowed("mallory@evil.com", &allowlist));
        assert!(!tailnet_login_is_allowed("  ", &allowlist));
    }

    #[test]
    fn tagged_devices_never_authorizes() {
        let allowlist = vec![TAGGED_DEVICES_LOGIN.to_string()];
        assert!(!tailnet_login_is_allowed(TAGGED_DEVICES_LOGIN, &allowlist));
        assert!(!tailnet_login_is_allowed(" Tagged-Devices ", &allowlist));
    }

    #[test]
    fn whois_arg_unmaps_ipv4_mapped_ipv6() {
        let mapped: SocketAddr = "[::ffff:100.65.193.69]:1234".parse().unwrap();
        assert_eq!(whois_addr_arg(mapped), "100.65.193.69:1234");
        let v4: SocketAddr = "100.65.193.69:1234".parse().unwrap();
        assert_eq!(whois_addr_arg(v4), "100.65.193.69:1234");
        let v6: SocketAddr = "[fd7a:115c:a1e0::1]:1234".parse().unwrap();
        assert_eq!(whois_addr_arg(v6), "[fd7a:115c:a1e0::1]:1234");
    }

    #[test]
    fn whois_candidates_skip_gui_binary_and_end_with_path_fallback() {
        // The GUI bundle binary fails headless; listing it would shadow a
        // working later candidate with unparseable output.
        assert!(
            !TAILSCALE_CANDIDATE_BINARIES
                .iter()
                .any(|binary| binary.contains("Tailscale.app"))
        );
        assert_eq!(TAILSCALE_CANDIDATE_BINARIES.last(), Some(&"tailscale"));
    }

    #[test]
    fn negative_cache_ttl_is_shorter_than_success_ttl() {
        assert!(WHOIS_NEGATIVE_CACHE_TTL < WHOIS_CACHE_TTL);
    }

    #[test]
    fn judge_stops_at_valid_json_without_login() {
        // Tagged machine node: tailscaled answered, so other candidate paths
        // to it cannot change the answer; the search must stop, fail closed.
        let tagged = &br#"{"Node":{"Name":"server1","Tags":["tag:server"]}}"#[..];
        assert_eq!(parse_tailscale_whois_login(tagged), None);
        assert_eq!(
            judge_whois_output(Some(tagged)),
            WhoisCandidateVerdict::Stop
        );
    }

    #[test]
    fn judge_uses_login_and_retries_the_rest() {
        let login = whois_output("david@hyeons-lab.com");
        assert_eq!(
            judge_whois_output(Some(&login[..])),
            WhoisCandidateVerdict::Use
        );
        assert_eq!(judge_whois_output(None), WhoisCandidateVerdict::Next);
        assert_eq!(
            judge_whois_output(Some(&b"not json at all"[..])),
            WhoisCandidateVerdict::Next
        );
        assert_eq!(
            judge_whois_output(Some(&b""[..])),
            WhoisCandidateVerdict::Next
        );
    }

    static RESOLVER_CALLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    // The counting tests below share RESOLVER_CALLS; serialize them since the
    // harness runs tests on multiple threads.
    static RESOLVER_LOCK: Mutex<()> = Mutex::new(());

    fn stub_whois(_peer: SocketAddr) -> Option<Vec<u8>> {
        RESOLVER_CALLS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Some(whois_output("david@hyeons-lab.com"))
    }

    // Same canned answer without touching the shared counter, for tests that
    // don't assert call counts and must not disturb the ones that do.
    fn canned_whois(_peer: SocketAddr) -> Option<Vec<u8>> {
        Some(whois_output("david@hyeons-lab.com"))
    }

    fn failing_whois(_peer: SocketAddr) -> Option<Vec<u8>> {
        None
    }

    fn pairing_with(run: fn(SocketAddr) -> Option<Vec<u8>>) -> TailnetPairing {
        TailnetPairing {
            cache: Mutex::new(HashMap::new()),
            inflight: Mutex::new(()),
            run_whois: run,
        }
    }

    #[test]
    fn cache_reuses_success_without_rerunning() {
        let _guard = RESOLVER_LOCK.lock().unwrap();
        RESOLVER_CALLS.store(0, std::sync::atomic::Ordering::SeqCst);
        let pairing = pairing_with(stub_whois);
        let peer: SocketAddr = "100.65.193.69:1".parse().unwrap();
        assert_eq!(
            pairing.resolve_login(peer),
            Some("david@hyeons-lab.com".to_string())
        );
        assert_eq!(
            pairing.resolve_login(peer),
            Some("david@hyeons-lab.com".to_string())
        );
        assert_eq!(RESOLVER_CALLS.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[test]
    fn cache_keys_mapped_and_plain_v4_identically() {
        let _guard = RESOLVER_LOCK.lock().unwrap();
        RESOLVER_CALLS.store(0, std::sync::atomic::Ordering::SeqCst);
        let pairing = pairing_with(stub_whois);
        let plain: SocketAddr = "100.65.193.69:1".parse().unwrap();
        let mapped: SocketAddr = "[::ffff:100.65.193.69]:2".parse().unwrap();
        pairing.resolve_login(plain);
        pairing.resolve_login(mapped);
        assert_eq!(RESOLVER_CALLS.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[test]
    fn failed_lookup_denies_and_caches_negative() {
        let pairing = pairing_with(failing_whois);
        let peer: SocketAddr = "100.65.193.69:1".parse().unwrap();
        assert_eq!(pairing.resolve_login(peer), None);
        assert_eq!(pairing.cache.lock().unwrap().len(), 1);
    }

    #[test]
    fn overflow_evicts_before_growing_past_cap() {
        let pairing = pairing_with(canned_whois);
        for i in 0..(WHOIS_CACHE_MAX_ENTRIES + 64) {
            let peer: SocketAddr = format!("100.64.{}.{}:1", i / 256, i % 256).parse().unwrap();
            pairing.resolve_login(peer);
        }
        assert_eq!(pairing.cache.lock().unwrap().len(), WHOIS_CACHE_MAX_ENTRIES);
    }
}
