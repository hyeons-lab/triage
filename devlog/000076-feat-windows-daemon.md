# 000076 — feat/windows-daemon

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/windows-daemon

## Intent

Make `triaged` run as a real daemon on Windows so the Flutter/TUI/MCP clients can
talk to it there, the same way they do on macOS and Linux. Today the daemon's
control plane is a Unix domain socket (`crates/triaged/src/ipc.rs`), so on Windows
`main.rs` falls through to a `thread::park()` loop that serves nothing.

This is the prerequisite epic for a Windows background *service* (a later PR);
here we only make the daemon itself functional on Windows.

Out of scope: zero-downtime handover (relies on `SCM_RIGHTS` FD passing — no
Windows equivalent; Windows updates restart instead). Handover stays `#[cfg(unix)]`.

## Research & Discoveries

- **PTY core is already portable.** Sessions spawn via `portable-pty`'s
  `native_pty_system()` (`session.rs:3014`), which uses ConPTY on Windows. No
  terminal rewrite needed.
- **`session.rs` is already Windows-defensive** — 22 `cfg(unix)` guards; the
  handover/FD-serialization path (`serialize_active_sessions`,
  `extract_handover_state`, `adopt_sessions`, `ExtractedHandover`,
  `spawn_adopted_pty_runtime`) is all `#[cfg(unix)]`. `OsStringExt` import is
  gated. The IPC test file already has `cfg(windows)` `cmd.exe` branches and
  `cfg_attr(windows, ignore)` markers.
- **`ipc.rs` is the gap** — entirely `std::os::unix::net` (`UnixListener`/
  `UnixStream`) + `PermissionsExt`/`MetadataExt`. The whole module is Unix-only.
- **`main.rs`** already has `cfg(not(unix))` fallbacks (parks instead of serving);
  needs to start the Windows IPC server instead.
- **Client call sites** (must keep compiling, ideally unchanged):
  `triage-mcp/src/main.rs:11,29`, `triage/src/lib.rs:13,56`,
  `triage/src/main.rs:55,62,104,106,379` — all use
  `triaged::ipc::{UnixSocketClient, default_socket_path}`.
- **Transport choice:** `interprocess` 2.4.2. Namespaced names
  (`to_ns_name::<GenericNamespaced>()`) map to `\\.\pipe\<name>` on Windows and a
  filesystem AF_UNIX socket on Unix. We only use it in `cfg(windows)` code; Unix
  stays on std (zero regression risk for the daily-driver platforms).
- **Protocol is half-close-free in practice.** Requests/events are newline-framed
  JSON (`read_line` stops at `\n`), so the client's `shutdown(Shutdown::Write)` is
  only a signal, not required for framing. The server reads exactly one request
  line then only writes — so the connection handler can `BufReader` the request,
  `into_inner()`, and write responses without `try_clone()`. That makes the
  handler work over any `Read + Write` stream, named pipes included.
- **Local validation:** `cargo check --target x86_64-pc-windows-gnu` type-checks
  the whole tree for Windows without a linker (I'm on macOS). CI on
  `windows-latest` is the real build+test gate.

## Decisions

- 2026-06-18T18:53-0700 Keep the Unix IPC path byte-identical (lowest regression
  risk) and add a parallel `#[cfg(windows)]` named-pipe path. Share the
  transport-agnostic logic (`WireRequest`/`WireResponse`/`WireSuccess`,
  `handle_request`, `handle_subscription`, JSON line framing); cfg-split only the
  listener/stream/bind/connect. ~30 lines of dispatch duplicated across the two
  cfg blocks — accepted in exchange for not touching the proven Unix code.
- 2026-06-18T18:53-0700 Keep the public type names (`UnixSocketClient`,
  `UnixSocketServer`, `UnixSocketConfig`, `default_socket_path`) so the
  `triage`/`triage-mcp` call sites don't change. A module doc clarifies they are
  "local IPC: Unix domain socket on Unix, named pipe on Windows." A cosmetic
  rename can be a later PR.
- 2026-06-18T18:53-0700 Handover remains Unix-only; Windows daemon self-update
  (future) restarts rather than hands over. The non-unix `--handover` bail already
  exists.

## Plan

See `devlog/plans/000076-01-windows-daemon.md`.

## What Changed

- 2026-06-18T19:30-0700 `crates/triaged/Cargo.toml` — add
  `interprocess = "2.4"` under `[target.'cfg(windows)'.dependencies]` (named-pipe
  transport; Unix stays on std).
- 2026-06-18T19:30-0700 `crates/triaged/src/ipc.rs` — add a `transport` seam
  (`LocalStream`, `connect`, `finish_write`, Windows `windows_pipe_name`); gate
  the Unix-only imports / `bind_owner_socket` / Unix `serve`+`handle_connection`
  behind `#[cfg(unix)]`; add parallel `#[cfg(windows)]` named-pipe `serve` +
  `handle_connection`; make `handle_subscription` generic over `&mut impl Write`;
  route the client through `transport::{connect,finish_write}` (dropping the
  `UnixStream`-specific `connect`/`shutdown`/`try_clone` — the client only reads
  after sending its one request line); make `default_socket_path` /
  `fallback_user_component` portable (`USERNAME` on Windows). Test helper
  `spawn_server` readiness probe is now cross-platform (`server_not_ready`).
- 2026-06-18T19:30-0700 `crates/triaged/src/lib.rs` — `pub mod ipc` now
  `#[cfg(any(unix, windows))]` (was `cfg(unix)`).
- 2026-06-18T19:30-0700 `crates/triaged/src/main.rs` — import the IPC server for
  `any(unix, windows)`; start the named-pipe server on Windows instead of parking;
  keep a park-only fallback for other platforms.
- 2026-06-18T19:30-0700 `crates/triaged/README.md` — clarify the daemon runs on
  Windows (named pipe + ConPTY); only handover stays Unix-only.
- 2026-06-18T20:30-0700 **Completed the client side** (the daemon served on
  Windows but no local client could attach — a `/code-review max` pass flagged it
  as half a feature). Lifted the `#[cfg(unix)]` gates to `cfg(any(unix, windows))`
  in the IPC clients:
  - `crates/triage-mcp/src/main.rs` — `run_stdio` + import now build the client on
    Windows (dropped the non-unix `bail!` and the now-unneeded `cfg_attr(windows,
    allow(dead_code, unused_imports))`); help text de-Unix-ified.
  - `crates/triage/src/lib.rs` — `LocalSessionApp::connect` + import on
    `any(unix, windows)`.
  - `crates/triage/src/main.rs` — `start_app` + `default_startup_mode` on
    `any(unix, windows)` (bare `triage` now attaches to the daemon on Windows,
    matching Unix); `ClientReload`/`ClientUpgrade` enabled on Windows; help text
    updated. Added `daemon_endpoint_present(&Path)` — Unix stats the socket file,
    Windows returns `true` — fixing the `PathBuf`-as-pipe-name landmine where the
    old `path.exists()` guard is always false for a named-pipe token.

## Issues

- 2026-06-18T19:05-0700 `cargo check --target x86_64-pc-windows-gnu` first failed
  needing the mingw C cross-compiler (a transitive dep compiles C via `cc`).
  Installed `mingw-w64` via Homebrew → type-checks now run locally.
- 2026-06-18T19:20-0700 `triaged::ipc` was `cfg(unix)` in `lib.rs`, so `main.rs`
  couldn't import it on Windows. Gated the module for `any(unix, windows)`.
- 2026-06-18T19:25-0700 The IPC integration test (`client_reports_server_errors`,
  NOT `windows,ignore`) runs on the existing `windows-latest` CI matrix entry and
  would have failed two ways: (1) test paths are filesystem-like
  (`…\triage.sock`) but a pipe name can't contain `\`/`/`/`:` → `windows_pipe_name`
  now sanitizes separators into a unique legal token; (2) `spawn_server` waited on
  `socket_path.exists()`, never true for a pipe → readiness now probes by
  connecting on Windows.
- 2026-06-18T19:30-0700 No `ci.yml` change needed: the `test` job already runs
  `windows-latest`. Until now it built a do-nothing daemon (no `ipc` module); it
  now builds and exercises the real named-pipe control plane. CI is the runtime
  gate since the dev host is macOS.

## Verification

- `cargo check -p triaged` (host) — clean.
- `cargo check/clippy -p triaged -p triage -p triage-mcp --tests --target
  x86_64-pc-windows-gnu -- -D warnings` — clean (type-level Windows validation).
- `cargo test -p triaged --lib ipc` (host) — 5/5 pass (no Unix regression).
- `cargo clippy -p triaged --all-targets -- -D warnings` (host) — clean.
- Runtime on real Windows: deferred to `windows-latest` CI.

## Code review fixes (second `/code-review max` pass)

- 2026-06-18T20:58-0700 A second review of the client-side commit found no
  correctness bugs but several Windows UX/parity gaps. Fixed:
  - `crates/triaged/src/ipc.rs` — added `display_endpoint(&Path)` (Unix: the
    socket path; Windows: the full `\\.\pipe\<token>`) and use it in the client
    connect error context, so messages no longer show a bare pipe token that
    reads like a typo. Factored the pipe-token sanitizer into
    `transport::windows_pipe_token` (shared by the name builder and display).
  - `crates/triage/src/main.rs` — replaced the Windows-always-`true`
    `daemon_endpoint_present` pre-check with a `notify_daemon_reload(socket_path,
    required)` helper that attempts the connect and reports failure uniformly on
    both platforms: a hard "is the daemon running?" error for `client reload`, a
    benign "will load on next start" note for `client upgrade` (no more scary
    Windows-only warning on an offline upgrade). This dedups the two
    near-identical notify blocks and restores the friendly hint on Windows. The
    TUI `start_app` daemon error also uses `display_endpoint`.

## PR review comments (Copilot)

- 2026-06-18T21:26-0700 Addressed the PR review:
  - `crates/triaged/src/ipc.rs` — both `handle_connection`s now treat
    EOF-before-request (`read_json_line` → `Ok(None)`) as a normal disconnect and
    return `Ok(())`, instead of an error that wasn't classified as a closed socket
    and logged a spurious warning. This also quiets the Windows liveness/preflight
    probes. `windows_pipe_token` now strips a `\\.\pipe\` / `\\?\pipe\` prefix
    before sanitizing, so a user-supplied full pipe path maps to the same token as
    the bare default (previously it was mangled and wouldn't connect). `serve()`
    diagnostics use `display_endpoint(&socket_path)` instead of the bare
    `display()` token.
  - `crates/triaged/src/main.rs` — the Windows "starting named pipe server" log
    uses `display_endpoint` for a consistent `\\.\pipe\…` endpoint.
  - `crates/triaged/README.md` — renamed the section heading from "Windows
    Graceful Fallback" to "Windows Support (no zero-downtime handover)" to match
    the content (full native support + the handover caveat).

## Next Steps

Remaining follow-ups, deliberately out of this PR (most daemon-side):

- **Bounded connect (the one substantive item).** `interprocess`'s cross-platform
  `local_socket` API has *no* connect-timeout knob — verified in source:
  `from_options` ignores the wait mode and hardcodes `ConnectWaitMode::Unbounded`.
  So under `ERROR_PIPE_BUSY` (all instances busy) a client connect can block
  indefinitely. A correct fix needs the Windows-specific
  `named_pipe::…::connect_by_path_with_wait_mode(ConnectWaitMode::Timeout(..))`,
  which changes the transport's stream type and must be validated on a real
  Windows runtime — not a safe blind change to the just-green transport.
  Low-probability in practice (the accept loop re-arms in microseconds; the
  missing-daemon case fails fast), so deferred to a dedicated, Windows-tested PR.
- **Redundant startup probe.** The Windows `serve()` self-connect "already in
  use" check is redundant — `create_sync()` sets `FILE_FLAG_FIRST_PIPE_INSTANCE`,
  so a second daemon's create fails atomically. Removing it also removes a
  potential indefinite block and the phantom-connection warning.
- **Pipe-name length cap.** `windows_pipe_token` has no 256-char guard; a deep
  override/test path could exceed the NPFS limit. Hash or truncate long names.
- **Test readiness flakiness.** The Windows test readiness probe leaves a
  dead-on-arrival connection that races the real client (latent; CI green so far).
- **`%LOCALAPPDATA%` for web assets.** `triaged::http::default_override_dir` puts
  upgraded web assets under a Unix-style `.local/share` on Windows (pre-existing,
  not in this PR's diff; client and daemon agree so it works). Switch to a
  Windows-idiomatic dir as a separate Windows-paths cleanup.
- **Cleanup.** De-dup the per-platform `serve`/`handle_connection`; rename the
  `UnixSocket*` types now that they're cross-platform. (The `cfg(any(unix,
  windows))` repetition was judged idiomatic — not worth `cfg_aliases` build.rs
  machinery in two crates.)

REFUTED by the verifier (not issues): handover-restart TOCTOU split-brain
(`FILE_FLAG_FIRST_PIPE_INSTANCE` prevents it); "any local user can RCE" (default
DACL is owner+SYSTEM+Admins only).

## Commits

- e7ca86d — feat(triaged): run the daemon on Windows via named-pipe IPC
- 52a2ec3 — feat(triage,triage-mcp): connect to the Windows daemon over the named pipe
- e473980 — fix(triage): friendlier Windows IPC errors, unified daemon-reload notify
- HEAD — fix(triaged): address PR review — quiet benign disconnects, accept full pipe paths
