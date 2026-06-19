# 000076-01 — Windows daemon support

## Thinking

`triaged` already compiles on Windows for everything except the control plane.
The terminal engine is `portable-pty` (ConPTY on Windows), session/handover code
is `#[cfg(unix)]`-gated, and `main.rs` has non-unix fallbacks. The single missing
capability is a Windows-native local IPC server+client so the TUI, MCP server, and
(via the embedded daemon) the GUI can reach the daemon.

The Unix control socket is an AF_UNIX socket at a filesystem path, hardened to
`0o600` and with stale-socket reclaim. The Windows equivalent is a **named pipe**
(`\\.\pipe\triage-<user>`). Named pipes don't leave stale filesystem entries (the
pipe disappears when the last handle closes) and default to a DACL granting the
creating user + SYSTEM/Administrators — a reasonable same-user boundary for v1
(documented; tightening the DACL is a follow-up).

The IPC protocol is newline-delimited JSON. Crucially the server reads exactly one
request line per connection and then only writes (responses, or a stream of
subscription events). So a connection handler can wrap the stream in a
`BufReader`, read the one request line, `into_inner()` to recover the stream, and
write replies — needing only `Read + Write`, no `try_clone`/half-close. That is
what lets one handler body serve both `UnixStream` and an `interprocess` named-pipe
`Stream`. Handover is the lone exception (raw-fd `SCM_RIGHTS`); it stays Unix-only
and keeps its existing `UnixStream`-based handler.

`interprocess` 2.4.2 gives a unified `local_socket` API. We use it **only** under
`#[cfg(windows)]`; Unix keeps using `std::os::unix::net` verbatim, so macOS/Linux
behavior is unchanged.

I can't run Windows locally (host is macOS), so correctness is established in two
layers: `cargo check --target x86_64-pc-windows-gnu` for type/cfg correctness as I
go, and a new `windows-latest` CI job that actually builds and runs the tests.

## Plan

### Phase 1 — Dependency + transport seam in `ipc.rs`
1. Add `interprocess = "2.4.2"` to `crates/triaged/Cargo.toml` under
   `[target.'cfg(windows)'.dependencies]` so it's pulled in only for Windows.
2. Gate the Unix-only top imports in `ipc.rs` (`os::unix::fs`, `os::unix::net`)
   behind `#[cfg(unix)]`. Add a `transport` seam:
   - `#[cfg(unix)]`: `LocalStream = UnixStream`, `LocalListener = UnixListener`;
     reuse `bind_owner_socket`; `connect(path)`; `finish_write` = `shutdown(Write)`.
   - `#[cfg(windows)]`: `LocalListener`/`LocalStream` wrapping `interprocess`
     named pipe; `bind` (create from `default` pipe name; refuse if a live server
     already answers a probe connect); `accept`; `connect`; `finish_write` = no-op.
3. `default_socket_path()`:
   - `#[cfg(unix)]`: unchanged.
   - `#[cfg(windows)]`: `PathBuf` carrying the bare pipe name
     `triage-<user-component>` (reuse `fallback_user_component`, which is itself
     made portable — `HOME`→`USERPROFILE`, uid→username).

### Phase 2 — Make handlers transport-agnostic
4. `handle_subscription` signature: `&mut BufWriter<UnixStream>` → `&mut impl Write`.
   (Already only uses `write_json_line`/`flush`.)
5. Split `serve()` and `handle_connection()` per cfg:
   - Unix versions: the existing code, unchanged (handover preserved).
   - Windows versions: accept loop over the named-pipe listener; per-connection
     `BufReader` → read request line → `into_inner()` → dispatch to the shared
     `handle_request`/`handle_subscription`. `WireRequest::Handover` → `bail!`
     ("handover unsupported on Windows").
   - Shared: `handle_request`, `handle_subscription`, Wire types, JSON framing.
6. Client `SessionApi`: route `round_trip` and `subscribe_session_events_from`
   through `transport::connect` + `finish_write` so both bodies compile on both
   platforms (drop the hard `UnixStream::connect`/`shutdown`).

### Phase 3 — `main.rs` Windows serve path
7. Replace the `cfg(not(unix))` `thread::park()` block with starting the Windows
   IPC server (`UnixSocketServer::new(manager, web_cache, config).serve()`), so the
   daemon actually answers clients. Keep the WS/HTTP server thread (already
   cross-platform — `TcpListener`).

### Phase 4 — Compile-gate sweep
8. `cargo check --target x86_64-pc-windows-gnu -p triaged -p triage -p triage-mcp`.
   Fix any remaining non-gated Unix uses surfaced (expected: a few `OsStr`/path
   byte conversions, `Shutdown`, stray `libc`). Keep all fixes `#[cfg]`-scoped;
   do not alter Unix behavior.

### Phase 5 — CI
9. Add a `windows-latest` job to `.github/workflows/ci.yml`: install flatc, Rust
   1.94.1, `cargo build`/`cargo test` for the workspace (or at least
   `-p triaged -p triage -p triage-mcp`). Mirror the existing Linux job's flatc +
   toolchain setup.

### Phase 6 — Docs + tests
10. Module doc on `ipc.rs` describing the cross-platform transport + the Windows
    named-pipe security note. Update `AGENTS.md`/README "platforms" wording.
11. Un-`ignore` the Windows IPC tests if ConPTY behavior cooperates; otherwise
    leave a focused Windows lifecycle test as a follow-up and document why.

### Sequencing / PRs
- This whole plan is **one PR** (Windows daemon runs). The Windows *service*
  registration is a separate later PR that builds on it.

## Risks
- **No local Windows runtime.** Mitigated by `--target ...-windows-gnu` checks +
  `windows-latest` CI. Runtime bugs (pipe security, ConPTY quirks) may need a CI
  round-trip or two.
- **`interprocess` Stream API ergonomics** (split vs single handle). Mitigated by
  the read-once-then-write protocol shape (no concurrent read+write per conn).
- **Named-pipe security** is coarser than `0o600`. Acceptable for v1 (same-user
  default DACL); note as a hardening follow-up.
