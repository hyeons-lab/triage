# 000072 — feat/tailnet-pair-approval

**Agent:** Claude (claude-opus-4-8) @ triage branch feat/tailnet-pair-approval

## Intent

Allow `/pair` approval from our own tailnet devices without SSHing into the daemon
host. Today the gate (`is_local_pairing_peer`) only accepts loopback (or same
concrete-bind IP), so with the `0.0.0.0` default bind remote pairing requires a
shell on the daemon machine. Gate approval instead on an **allowlisted,
authenticated tailnet identity** (from `tailscale whois`), keeping the loopback
path and defaulting to today's behavior when the allowlist is empty.

## Decisions

2026-06-16T23:19-0700 Gate on tailnet *identity* (whois `UserProfile.LoginName`)
against a config allowlist — not on source IP range (spoofable) and not on bare
tailnet reachability (unsafe on shared tailnets).

2026-06-16T23:19-0700 Get identity via `tailscale whois --json` CLI shellout, not
the LocalAPI socket: the CLI handles socket discovery + macOS-GUI sameuserproof
auth across all install types; `/pair` is one-time-per-device so subprocess cost
is irrelevant. (User chose CLI over LocalAPI.)

2026-06-16T23:19-0700 Opt-in + additive: empty/absent `pair_approval_tailnet_users`
= byte-for-byte today's loopback-only gate. whois failure / Tailscale absent /
not-on-allowlist → reject.

2026-06-16T23:19-0700 Move the gate computation inside the spawned per-connection
task (it becomes async due to the whois I/O) so a slow lookup never stalls the
accept loop; bound the subprocess with a short timeout.

2026-06-17T07:12-0700 Code-review follow-up: the two structural risks — a
loopback reverse proxy making every client look local, and an all-interfaces
bind trusting the source IP — cannot be closed in code without trusting a
forwarded header (which we must not) or constraining the bind. Addressed as
explicit deployment guidance in the README (bind to the tailnet IP; don't
expose `/pair` through a loopback proxy) rather than code changes.

2026-06-17T07:12-0700 Self-approval (an allowlisted device approving its own
pairing) is the intended, opt-in relaxation of the old loopback-only guarantee,
not a bug. Documented it explicitly so operators allowlist only identities they
trust to authorize devices. Kept the implicit "non-empty allowlist = enabled"
gate (no separate enable flag) but added a startup log line so the active mode
is visible.

## Progress

- [ ] Config: `pair_approval_tailnet_users` + validation + test
- [ ] whois helper (CLI shellout + JSON parse + timeout)
- [ ] Async pairing gate composing loopback || allowlisted-whois
- [ ] Wire config through `start_websocket_server`
- [ ] Tests (gate logic with injected whois result)
- [ ] README pairing docs
- [ ] fmt + clippy + test clean

2026-06-16T23:36-0700 Codex completed the planned slice:
- [x] Config: `pair_approval_tailnet_users` + validation + tests
- [x] Whois helper using `tailscale whois --json`, JSON parsing, timeout, and fail-closed behavior
- [x] Async pairing gate composing loopback / same-host approval with allowlisted tailnet identity
- [x] Config allowlist wired through `start_websocket_server`
- [x] Gate tests with injected whois results and parser coverage
- [x] README pairing docs
- [x] `cargo fmt --all -- --check`, `cargo check --workspace`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test --workspace` clean

## What Changed

(pending)

2026-06-16T23:36-0700 Added `remote.pair_approval_tailnet_users` to config,
defaulting empty and rejecting empty entries. Full config parsing tests now cover
a populated allowlist.

2026-06-16T23:36-0700 Added the tailnet approval gate in `triaged::ws`: local
peers still approve immediately; non-local peers are only checked with
`tailscale whois --json` when the allowlist is non-empty. The lookup is bounded
by a timeout, parses `UserProfile.LoginName`, normalizes case/whitespace, and
fails closed on missing CLI, non-zero status, malformed JSON, missing login, or
non-allowlisted identity.

2026-06-16T23:36-0700 Moved approval computation into the spawned connection task
and threaded the allowlist from `main.rs` into `start_websocket_server`, avoiding
subprocess work in the accept loop.

2026-06-16T23:55-0700 Refined the gate to compute whois lazily only for `/pair`
requests. Normal remote `/ws` and static asset requests do not pay the whois
subprocess or timeout when the allowlist is configured.

2026-06-16T23:36-0700 Documented host-only default approval and opt-in tailnet
approval in `crates/triaged/README.md`, including the `tailscale` CLI dependency
and config snippet.

2026-06-17T07:12-0700 Hardening after a max-effort code review (see Decisions
and Issues). `ws.rs`: introduced a `PairApproval` struct that (a) normalizes +
de-dupes the allowlist once at construction, (b) caches `tailscale whois`
results per peer IP for a 10s TTL, and (c) bounds concurrent whois subprocesses
with a `Semaphore(4)`. Added `whois_addr_arg` to unmap IPv4-mapped-IPv6 peer
addresses (`::ffff:a.b.c.d` → `a.b.c.d`) before invoking whois, matching how
`is_local_pairing_peer` already canonicalizes. whois non-zero-status logging now
includes captured stderr. Startup logs whether approval is loopback-only or also
tailnet-allowlisted.

2026-06-17T07:12-0700 `http.rs`: `serve_http` now takes a lazy
`authorize_pairing: FnOnce() -> impl Future<Output = bool>` instead of a
precomputed `bool`. The authorizer runs only inside the `/pair` branch, which
sits after the `method != GET` 405 check — so non-GET requests (and all
non-pairing paths) never trigger a whois lookup. This also makes `/pair` the
single source of truth for the pairing route (ws.rs no longer re-matches the
path).

2026-06-17T07:12-0700 `config.rs`: `RemoteConfig::validate` now rejects a
non-empty `pair_approval_tailnet_users` when `require_pairing = false`. Fixed the
`FULL_CONFIG` fixture (`require_pairing = true`) and added
`tailnet_pair_approval_requires_require_pairing`.

2026-06-17T07:12-0700 `README.md`: added a "Security caveats for tailnet
approval" callout — bind to the tailnet IP rather than `0.0.0.0`; a loopback
reverse proxy bypasses the identity check; allowlisted identities can
self-approve.

2026-06-17T07:12-0700 Tests: added `test_pair_page_non_get_does_not_invoke_authorizer`
(http_tests) proving the authorizer is not consulted for non-GET `/pair`, plus
`pair_approval_normalizes_and_dedupes_allowlist`, `whois_addr_arg_unmaps_v4_mapped_v6`,
and `pair_approval_caches_whois_per_peer` (ws). Updated existing serve_http call
sites to the closure form.

2026-06-17T07:34-0700 Addressed PR #82 review (Copilot). (1) `WHOIS_CACHE_MAX_ENTRIES`
was not actually enforced — `retain` only drops stale entries, so a flood of
unique fresh peers grew the map unbounded; `store_login` now evicts the oldest
entries after pruning until under the cap (new test
`pair_approval_cache_stays_capped_under_unique_peers`). (2) The cache mutex
accessors recovered from poisoning via `into_inner()` instead of `expect`, so a
prior panic can't crash pairing. (3) README tailnet config snippet now uses a
`100.x.y.z` Tailscale-IP bind instead of `0.0.0.0`, matching the caveat below it.

2026-06-17T08:57-0700 Addressed a max-effort multi-agent review (15 findings) of
the branch. Code (`ws.rs`): negative (`None`) whois results now use a 1s TTL
(`WHOIS_NEGATIVE_CACHE_TTL`) vs the 10s positive TTL, so a transient failure
can't lock out a legit user; `cached_login` returns a named `CacheLookup` enum
instead of `Option<Option<String>>`; `resolve_login` split into a thin wrapper +
testable `resolve_login_with(lookup)` that owns the cache/semaphore orchestration;
cache eviction guards updates of existing keys and evicts overflow in one sorted
pass (was an O(n²) `min_by_key` loop); `whois_addr_arg` reuses `mapped_ipv4`;
`tailnet_login_is_allowed` hard-rejects the `tagged-devices` pseudo-login;
startup warns when the allowlist is set but `tailscale` isn't runnable or the
bind is unspecified; the misleading "at most one subprocess" comment corrected.
Config (`config.rs`): new `remote.pair_approval_trust_local_peers` (default true)
to disable loopback/same-host auto-approval behind a reverse proxy, validated to
require a non-empty allowlist; validation rejects `tagged-devices`. New tests for
the resolver orchestration, the real `tailscale_whois_login` subprocess path,
the trust toggle, the tagged-devices guard, negative TTL, and the require_pairing
fixture coupling. README documents the new option and behaviors.

2026-06-17T08:57-0700 Deferred (not bug-fixes): finding #15 (re-architect
tailnet authz into a shared `WebSocketAuthenticator`/peer-identity layer rather
than a `/pair`-only gate) is a design-direction item, intentionally not bundled
into this review-fix pass to avoid a risky cross-cutting refactor. Finding #1
(loopback reverse-proxy trust) is now enforceable in code via the new toggle
rather than README-only.

## Research & Discoveries

- Gate computed sync at `ws.rs:43` (`is_local_pairing_peer`) before `tokio::spawn`,
  captured into the hyper service closure as `allow_pairing_approval: bool`.
- `/pair` served only when `allow_pairing_approval` (`http.rs:205`).
- `tailscale whois --json <ip[:port]>` JSON: top-level `Node{...}` and
  `UserProfile{ LoginName, DisplayName, ... }`. `UserProfile.LoginName` is the
  email-like identity to match. CLI at `/opt/homebrew/bin/tailscale` (macOS).
- `start_websocket_server` called once at `main.rs:152` in a dedicated thread.
- daemon already depends on `tokio` + `hyper`; no HTTP-client dep — confirms the
  CLI-shellout choice avoids adding one.

## Issues

(none yet)

2026-06-16T23:36-0700 The first sandboxed `cargo test --workspace` run failed on
Unix socket bind permissions in macOS tempdir for existing IPC/handover tests.
Reran the same command outside the sandbox and it passed.

2026-06-17T08:57-0700 Review finding "0.0.0.0 makes a routable peer look
same-host" was investigated and refuted — `is_unspecified_ip` short-circuits the
same-host branch for an unspecified listener (test
`local_pairing_peer_rejects_remote_peer_on_concrete_or_wildcard_listener`), so no
fix was needed there. The IPv4-mapped-unspecified asymmetry is not reachable by a
real accepted peer, so it was not changed.

## Commits

8a41b8c — feat(triaged): tailnet identity pair approval
9265110 — fix(triaged): enforce whois cache cap and harden pairing per PR review
HEAD — fix(triaged): address max-effort review (negative-cache TTL, trust-local toggle, tagged-devices guard, single-pass eviction, startup warnings)
