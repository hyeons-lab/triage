# 000066 — feat/session-snippets

**Agent:** Claude (claude-opus-4-8[1m]) @ triage branch feat/session-snippets

## Intent

Show a short, one-line, human-readable snippet per session in the Flutter client's side
rail (e.g. "running cargo test", "editing config in nvim") so the user can see what each
session is doing without opening it. Snippets are generated **locally** by the `cera`
inference engine running a small **LFM2.5-1.2B Q4_0** GGUF model — no cloud.

See plan: `devlog/plans/000066-01-session-snippets.md`.

## Decisions

- 2026-06-11T23:54-07:00 Model = LFM2.5-1.2B-Instruct-GGUF, quant Q4_0 — user choice; balanced quality/latency for one-liners. Configurable via `[summarizer]`.
- 2026-06-11T23:54-07:00 Trigger = debounced on activity (settle ~1.5s, min-regen ~5s/session, skip unchanged screen) — avoids summarizing mid-scroll and limits CPU/battery cost.
- 2026-06-11T23:54-07:00 Enablement = on by default; cera always compiled into `triaged`, runtime `[summarizer] enabled` flag (default true). Model downloads lazily on first use, off the reactor, so first launch never blocks.
- 2026-06-11T23:54-07:00 cera dependency = crates.io `cera = { version = "0.1", features = ["remote"] }` — confirmed published v0.1.0 (2026-06-10) at hyeons-lab/cera; no path/git dep needed.
- 2026-06-11T23:54-07:00 Inference serialized through ONE dedicated worker thread owning the engine (not N spawn_blocking) — engine is heavy (~1GB), generation is CPU-bound.
- 2026-06-11T23:54-07:00 Snippet delivery = new append-only `SessionSnippetUpdated` global push event (transport is otherwise subscription-scoped, so the rail needs a connection-wide channel) + a `list_session_snippets` seed call for newly-connected clients.

## Research & Discoveries

- 2026-06-11 cera API verified against the published crate (hyeons-lab/cera v0.1.0): NO text-only `append_chat` — must render via `cera::tokenizer::apply_chat_template(tokenizer, &messages, true)` then `session.append_text(rendered)`. `remote` feature is NOT default (gates HF downloader). `EngineConfig.context_size` is `usize`. `ModalitySink::on_done` is the only required method.
- 2026-06-11 triage transport delivers server events ONLY via per-session subscriptions (`WebSocketSessionConnection.subscriptions`, drained on a 10ms loop in `ws.rs`). No connection-wide broadcast exists → the global push channel is genuinely new work.
- 2026-06-11 Adding a `SessionApi` method ripples to 3 places: trait def, `impl<T> SessionApi for Arc<T>` forwarding impl, and the concrete `SessionManager` impl (methods are not auto-delegated).
- 2026-06-11 `crates/triage-core/build.rs` auto-regenerates Rust FB bindings (`flatc --rust`); Dart bindings have no regen script — manual `flatc --dart` + commit.

## Progress

- [x] Worktree + devlog + plan scaffolding
- [x] Step 1: cera dependency (workspace + triaged)
- [x] Step 2: `summarizer.rs` module (engine, single worker thread, sink, sanitize, prompt builder)
- [x] Step 3: dirty hook (`ActorState.dirty_tx`) + debounce loop (`run_debounce_loop`)
- [x] Step 4: prompt building (`build_prompt_text`, chat template + system prompt)
- [x] Step 5: snippet cache + `apply_snippet` (newest output_seq wins) + overlay on snapshots
- [x] Step 6: protocol — `SessionSnippetUpdated` push + `list_session_snippets` seed + schema + transport (de)serialize
- [x] Step 7: `[summarizer]` config + `default_model_cache_dir` + `main.rs` `start_summarizer`
- [x] Step 8: Dart client (regen bindings, `SessionVm.snippet`, parse push/result, seed, render muted 3rd line)
- [x] Build + clippy + fmt + flutter analyze (no new issues)
- [x] Toolchain → nightly-2026-04-02 (rust-toolchain.toml + ci.yml + publish.yml); CI commands verified green locally
- [x] End-to-end verify: `#[ignore]` test in summarizer.rs downloads the real LFM2.5-1.2B Q4_0 model and runs inference — produced snippet "Building and testing project version" for sample `cargo test` output (5 words, within cap). Confirms download→load→chat-template→generate→sanitize.

## What Changed

- 2026-06-11T23:54-07:00 devlog/000066-feat-session-snippets.md, devlog/plans/000066-01-session-snippets.md — branch devlog + verbatim plan copy.
- 2026-06-12T16:48-07:00 crates/triage-core/src/config.rs — added `[summarizer]` config (enabled default true, bundle_id `LFM2.5-1.2B-Instruct-GGUF`, quant Q4_0, context/tokens/settle/min_regen/cache_dir) + validation + default-assert test.
- 2026-06-12T16:48-07:00 crates/triage-core/schema/triage.fbs — append-only: `SessionSnapshot.snippet`, `ListSessionSnippetsRequest`, `SessionSnippetEntry`/`SessionSnippetsResult`, `SessionSnippetUpdatedPayload` (+ union members). Rust bindings auto-regen via build.rs; Dart regen via flatc.
- 2026-06-12T16:48-07:00 crates/triage-core/src/session.rs — `SessionSnapshot.snippet: Option<String>`; `SessionApi::list_session_snippets` (trait default + Arc forward).
- 2026-06-12T16:48-07:00 crates/triage-core/src/flatbuffers_proto.rs — encode `snippet` in `build_session_snapshot`.
- 2026-06-12T16:48-07:00 crates/triage-transport-ws/src/{lib.rs,flatbuffers_proto.rs} — `ClientRequest::ListSessionSnippets`, `ServerResult::SessionSnippets`, `ServerMessage::SessionSnippetUpdated`, `SessionSnippetEntry`; global-push receiver on `WebSocketSessionConnection` (`with_global_receiver` + drain in `drain_events`); FB (de)serialize + borrowed parse.
- 2026-06-12T16:48-07:00 crates/triaged/src/summarizer.rs (new) — `Summarizer` (single worker thread owns one `cera::CeraEngine`, lazy load, coalescing queue), `OneLineSink`, `sanitize_one_line`, `build_prompt_text`; chat via `cera::tokenizer::apply_chat_template` + `append_text` (no `append_chat` for text-only).
- 2026-06-12T16:48-07:00 crates/triaged/src/session.rs — `SessionManager` gains snippets cache + summarizer + dirty_tx + global_senders; `start_summarizer`/`seed_initial_summaries`/`apply_snippet`/`broadcast_global`/`register_global_receiver`/`forget_snippet`/`overlay_snippet`/`list_session_snippets`; `DirtyTick` from `handle_output`; `run_debounce_loop`; `default_model_cache_dir`. `dirty_tx` threaded through `spawn_with_events`/`spawn_managed`/`spawn_restored`/adopt.
- 2026-06-12T16:48-07:00 crates/triaged/src/{ws.rs,main.rs} — register global receiver per WS connection; `manager.start_summarizer(config.summarizer)` at startup.
- 2026-06-12T16:48-07:00 crates/{triage-mcp,triage}/... + benches — added `snippet: None` to existing `SessionSnapshot` literals (mechanical).
- 2026-06-12T16:48-07:00 flutter/triage_client/lib/generated/* — regenerated Dart FB bindings.
- 2026-06-12T16:48-07:00 flutter/triage_client/lib/services/triage_websocket_client.dart — parse `session_snippet_updated` push, `SessionSnippetsResult`, snapshot `snippet`; `listSessionSnippets()`; build `list_session_snippets` request.
- 2026-06-12T16:48-07:00 flutter/triage_client/lib/main.dart — `SessionVm.snippet`; handle push event; `_seedSessionSnippets` on load; snippet from snapshot; render muted italic 3rd line in `SessionListTile`.
- 2026-06-12T17:20-07:00 rust-toolchain.toml, .github/workflows/{ci.yml,publish.yml} — pin toolchain to `nightly-2026-04-02` (required by cera on aarch64). crates/triage-transport-ws/src/bin/stress_client.rs + crates/triage/src/main.rs — `#[allow(clippy::collapsible_match)]` for two pre-existing sites newly flagged by nightly clippy.
- 2026-06-12T20:53-07:00 crates/triaged/src/{session.rs,main.rs} — seed snippets for sessions adopted on handover. `start_summarizer` seeds at startup (line 62), but that runs *before* inherited-session adoption (main.rs line 109), so on handover the startup seed hits an empty session list and adopted sessions had no snippet until their next output. Added public `SessionManager::seed_session_snippets` (re-runs `seed_initial_summaries` against the now-live sessions; no-op when summarizer disabled) and call it right after `adopt_sessions` in the handover path. Fresh starts skip the block entirely, so no double-seed.

## Issues

- 2026-06-12T16:48-07:00 **cera 0.1.0 requires nightly Rust.** Its crate root has `#![cfg_attr(target_arch="aarch64", feature(stdarch_neon_dotprod, stdarch_aarch64_prefetch))]` — unconditional on Apple Silicon, no cera feature flag to opt out (the dotprod intrinsics `vdotq_s32`/`_prefetch` are genuinely unstable on 1.94.1, tracking issues #117224/#117217 — confirmed by a probe). **Resolution (user decision, 2026-06-12): switch triage/triaged to nightly.** triage is an app, not a library, so requiring nightly is acceptable and far simpler than gating the nightly kernels inside cera (which would touch numerical hot-path GEMV/GEMM + BLAS + parity tests). Pinned `rust-toolchain.toml` → `nightly-2026-04-02`; updated `.github/workflows/ci.yml` (both jobs) and `publish.yml` Rust toolchain pins to match. Verified: full workspace builds, `cargo clippy --workspace --all-targets --all-features -D warnings` clean, `cargo doc -D warnings` clean, `cargo test --workspace --all-features` all pass — all on the pinned nightly with no `RUSTC_BOOTSTRAP`. (An earlier interim plan to gate cera behind a feature + release cera 0.1.1 was dropped in favor of this simpler path.) Do NOT publish without asking first.
  - The nightly clippy bump surfaced two pre-existing `clippy::collapsible_match` lints (CI uses `-D warnings`): `stress_client.rs` arg loop (crate-level `#![allow]`) and `triage/src/main.rs:432` event-loop match (the inner `if` uses `?`, so it can't become a match guard — targeted `#[allow]`). Both are pre-existing, unrelated to the feature; suppressed rather than refactored.

## Verification

- 2026-06-12T17:35-07:00 `cargo test -p triaged --release -- --ignored end_to_end --nocapture` — downloaded LFM2.5-1.2B-Instruct-GGUF/Q4_0 (cached under `~/.cache/triage/models`), ran one inference on a sample `cargo test` screen, generated snippet `"Building and testing project version"`, passed. Full path: BundleRepo download → from_bundle_id load → apply_chat_template → generate → OneLineSink → sanitize.
- CI-equivalent local runs on nightly-2026-04-02: `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings` ✓, `cargo doc --workspace --all-features -D warnings` ✓, `cargo test --workspace --all-features --locked` ✓, `flutter analyze` ✓ (no new issues).
- 2026-06-12T20:53-07:00 Post-adoption seed fix: `cargo build -p triaged` ✓, `cargo clippy -p triaged --all-targets --all-features` ✓ (clean), `cargo fmt -p triaged` ✓. Empirically motivated — a live `triaged --handover` upgrade (PID 30758 → 94333) completed during this session; adopted sessions are exactly the case this fix seeds.

## Issues (continued)

- 2026-06-12T21:50-07:00 **Live snippet push never reached the client (bug found via real-app testing).** In `triage_websocket_client.dart` `_handleIncomingMessage`, only `response`/`error`/`event`/`subscription_closed` types were forwarded to `_eventController`; the new top-level `session_snippet_updated` push had no branch, so it was dropped before reaching `_processWebSocketEvent`. Symptom: a session present at connect (seeded via `listSessionSnippets`, a request *response*) showed its snippet, but a session created *after* connect (relies on the live push) never updated. Caught when a Claude Code session (session-34) created mid-run never got a snippet while session-33 did. Fix: add the `session_snippet_updated` branch to forward it to the stream. The seed path masked this in earlier checks because the first session was seeded, not pushed.
- 2026-06-15T12:11-07:00 **Fix verified end-to-end in the deployed macOS app.** With the push branch in place, the user confirms the rail shows snippets that change over time on active sessions — the live push path (not just seed-on-connect) is working.

## Lessons Learned

- cera text-only chat has no `append_chat`; render via `cera::tokenizer::apply_chat_template(tokenizer, &messages, true)` then `session.append_text(rendered)`. `remote` feature is opt-in (HF downloader); `EngineConfig.context_size` is `usize`.
- triage transport delivers server events only per-subscription; a connection-wide push needs a separate global channel drained in `drain_events` (done).
- The Rust TUI talks to the daemon in-process via `SessionApi`, not the WS borrowed parser — only Flutter + the stress_client use the wire protocol.

## Deployment / Handover Testing (2026-06-12T21:26-07:00)

**Goal:** replace `/Applications/Triage.app` + restart `triaged` + the web client so the user can test snippets live. The Claude Code session has been CRASHING / losing context on daemon+UI restarts — so this section is the durable state-of-the-world. Read this first on resume.

### Built artifacts (all current, branch feat/session-snippets)
- triaged binary: `target/release/triaged` (built ~21:23 WITH the uncommitted summary_rows refactor) → installed to `~/.cargo/bin/triaged`. Old binary backed up as `~/.cargo/bin/triaged.old-*`.
- Flutter web: `flutter/triage_client/build/web/` (embedded into triaged via rust-embed `#[folder = "../../flutter/triage_client/build/web/"]`, served on :7777).
- Flutter macOS app: `flutter/triage_client/build/macos/Build/Products/Release/Triage.app` (NOT yet copied to /Applications).

### Runtime topology
- `triaged` at `~/.cargo/bin/triaged`; binds `127.0.0.1:7777` (HTTP+WS); no config file → defaults → **summarizer enabled**.
- Handover unix socket: `/var/folders/zn/.../T/triage-501/triage.sock` (`default_socket_path()`).
- **Daemon log: `~/.local/state/triage/triaged.log`** (tracing-appender rolling::never). The `/tmp/triaged-*.log` files are stdout and have been EMPTY — diagnose via the state log, not /tmp.
- Sessions: `~/.local/state/triage/sessions/` (28 logs); pairing persists in `paired_devices.json`.
- App is standalone (`com.example.triageClient`, adhoc); connects over WS; does NOT spawn the daemon.

### Restart mechanism + OPEN PROBLEM
- `triaged --handover` (`-U`): new process connects to old daemon's `triage.sock`, inherits the TCP listener FD + live session PTYs, old exits, new continues IN THE SAME PROCESS (no re-exec). `main.rs` order: handover-client → SessionManager::default → load config → **start_summarizer** → bind → adopt inherited sessions → **seed_session_snippets** (commit 94a3374).
- **PROBLEM:** launching the daemon detached from the Claude Code Bash tool via `nohup ... & disown` does NOT survive — terminal showed `zsh: warning: 1 jobs SIGHUPed`; the daemon dies AND the Claude Code session loses context on the crash. NEXT TIME use the Bash tool's `run_in_background: true` (persists across turns) or a real double-fork/`launchctl submit` — NOT bare `nohup &`.
- "the handover doesn't seem to work" (user) — root cause unconfirmed; first read `~/.local/state/triage/triaged.log`. Candidates: (a) daemon not surviving detachment, (b) adoption failing, (c) snippets not generating. pid 321 (`triaged --handover`, started 21:10) was on :7777 at diagnosis time.

### Uncommitted work (COMPLETE) — summary_rows off-lock refactor
The summarizer used `snapshot_session`, which holds the global `sessions` Mutex across the actor round-trip AND reads up to 1 MB of raw-output log tail + builds styled rows — wasteful and a lock-starvation risk on the debounce/seed hot path. Replaced with a cheap, off-lock path:
- New `ActorCommand::SummaryRows` → returns visible rows + output_seq only (no styled rows, no disk read). Handler + shutdown-reject arm added.
- `request_summary_rows(tx)` helper (`session.rs:3069`); `SessionManager::summary_rows(id)` clones the live actor `tx` under a brief lock then calls it OFF-LOCK.
- `seed_initial_summaries` + `run_debounce_loop` switched to `summary_rows`.
- Added debug logs (`apply_snippet` cached+broadcast, seed total/enqueued/skipped_blank, worker empty-output drop) for the live test.
Complete + defined; needs `cargo build -p triaged` confirm, then commit.

### DIAGNOSIS (2026-06-12T21:27-07:00) — backend works; the issue is the stale app + fragile detach
Read `~/.local/state/triage/triaged.log` (the state log, NOT /tmp). Findings:
- **The feature WORKS end-to-end on real sessions.** The 04:10 UTC handover succeeded: "Adopting 9 inherited live sessions" → "loaded session summarizer model" → genuinely good snippets generated + broadcast for every session, e.g. session-30 "Analyzing session logs and daemon status", session-23 "Setting up EMSDK environment", session-32 "Building Flutter macOS app completed", session-21 "Checking terminal settings". Seed log: `total:9 enqueued:8`.
- **Daemon pid 321 is HEALTHY**: `curl http://127.0.0.1:7777/` → 200 in 0.4ms. Runs a ~21:07 binary (has 94a3374 seed-fix + debug logging; LACKS the e9561a1 summary_rows perf refactor — perf-only, not needed to test).
- **Why "handover doesn't work":** a SECOND handover at 04:23 UTC (to deploy the summary_rows binary) reached "Initiating Phase 3 (teardown)" then the log DEAD-STOPS — the new process was launched detached via `nohup ... & disown` and got **SIGHUPed** by the Bash-tool process-group cleanup, dying mid-handover. That both (a) leaves the daemon in a half-torn-down state and (b) is what crashes the Claude Code session. **Never launch the daemon via `nohup &` from the Bash tool.** Use `run_in_background: true`.
- **Why the user can't SEE snippets:** `/Applications/Triage.app` (what the running app pid launched from) is the OLD 8:41PM build with NO snippet rendering. The new build at `flutter/.../build/macos/Build/Products/Release/Triage.app` was never copied over.

### Plan (low-risk; NO daemon restart)
The daemon already works and generating a restart risks the SIGHUP crash + losing the user's live sessions. So:
1. ✓ Commit summary_rows refactor (e9561a1) — done.
2. Deploy the app ONLY: quit old app → `rm -rf /Applications/Triage.app` → `cp -R` new build → `open`. (File copy + app relaunch can't crash the session.)
3. New app connects to the working daemon (pid 321), calls listSessionSnippets (seeded) + receives pushes → snippets render in the rail. Verify via the daemon log showing a new WS connection.
4. LEAVE the daemon as-is. If the summary_rows perf binary is wanted later, restart via `run_in_background` (clean start or careful handover) — NOT now, not via nohup.

### UPDATE (2026-06-12T21:30-07:00) — daemon CONFIRMED stuck; clean restart required
After deploying the new app and relaunching it, the daemon log is STILL frozen at 04:23:56 — no "Upgraded WebSocket client connected" (which logs at debug, and debug IS enabled since the snippet debug logs appear). curl returns 200 (HTTP accept task alive) but the daemon processes no WS sessions → pid 321 is wedged in the aborted-handover Phase-3 teardown. So:
- New `/Applications/Triage.app` IS deployed (the new snippet-rendering build, ditto-copied 21:28). App relaunches but can't get a working session from the wedged daemon.
- **Action: clean restart.** Rebuild release from HEAD (summary_rows e9561a1), install to `~/.cargo/bin/triaged`, `kill` pid 321, start fresh `triaged` (NO --handover) via the Bash tool's `run_in_background: true` (survives; nohup did not). Fresh start loses the wedged live PTYs — unavoidable; the 28 persisted sessions reload as Historical (restorable).
- **Known nuance (acceptable):** the summary_rows refactor only reads LIVE actors, so on a fresh (non-handover) start, Historical sessions are NOT seeded a snippet until restored→live→produce output. Reasonable (a non-running session isn't "doing" anything). To SEE snippets after restart: start a new session / restore one and run a command → debounce generates a snippet within ~settle.

### BUG + FIX (2026-06-15T16:47-07:00) — dead `Live` sessions are unrestorable after handover

User report: "I can't input into restored sessions anymore" / "side rail says exited with a grey dot" / "I also don't see any snippets" (desktop Flutter client). Investigated against the live daemon (pid 86096, `triaged --handover`, self-updated to this branch's binary at 15:59; log shows a clean handover this time: "Adopting 4 inherited live sessions" + model loaded, no wedge).

Findings:
- **Root cause of can't-input/grey-exited:** a session whose child process dies while in the `ManagedSession::Live` state is **never** demoted to `Historical` (the only Live→Historical transitions are restore-rollback and the manifest reload on a fresh daemon start). `attach_session` on such a session returns `exited: true` (the actor's `snapshot()` reflects the reaped child), so the client correctly shows grey and gates input on `status == 'attached'` (main.dart:631). The client's recovery path — `restoreSession` — calls `restore_session`, which **requires** `Historical` and bails `"session … is already live or restoring"`; the client swallows that error, so the session is stuck exited/uninputtable until a full daemon restart. Bites exactly the post-handover case: the 4 adopted sessions' shell processes are dead now (none re-parented to launchd; confirmed via `ps`) → dead-`Live` → irrecoverable.
- **Why no snippets (again):** the running client is pid 88261 = `…/triage/flutter/triage_client/build/macos/Build/Products/Debug/Triage.app` — the **main-checkout Debug build**, no snippet code, never calls `list_session_snippets`. The snippet-capable build was installed to `/Applications/Triage.app` (Release, this branch) but is NOT the one running. Same class of issue as the 2026-06-12 note. Also: snippets only generate for LIVE sessions; with all sessions dead there is nothing to summarize until they are restored→live→produce output.

Fix (daemon, `crates/triaged/src/session.rs`):
- New `SessionManager::demote_dead_live_session(session_id)` — three-phase (brief lock → off-lock `HistoricalSession::restore` log replay → brief lock swap), mirroring the `summary_rows` off-lock discipline so the multi-MB log replay never runs under the global `sessions` mutex. Converts a dead `Live` session into `Historical` in place; no-op for running/non-Live sessions; leaves the session untouched if the historical rebuild fails.
- `restore_session` calls it first, so the existing restore path then finds `Historical` and re-spawns normally.
- Regression test `restore_revives_live_session_whose_process_died`: start a live `/bin/sh`, `exit\n` it, wait for the manager to observe `exited`, assert `restore_session` revives it (was panicking on the "already live" bail before the fix) and accepts input again. Full triaged suite: 85 pass; my code fmt-clean + clippy-clean.

Pre-existing note: `cargo fmt --all --check` flagged session.rs:586 (the `seed_initial_summaries` debug log) — committed drift from b0662c5. RESOLVED in a later `style:` commit: confirmed it is NOT a rustfmt-version mismatch (the local toolchain resolves to the same pinned `nightly-2026-04-02` / rustfmt 1.9.0 that CI uses), so it was a genuine format violation; `cargo fmt` collapsed the multi-line macro call. Workspace fmt now clean.

NOT YET DONE (pending user confirmation — daemon redeploy is disruptive to the one remaining live session): deploy the rebuilt daemon (`target/release/triaged` + `~/.cargo/bin/triaged`) and move the user onto the snippet-capable client.

### BUG + FIX (2026-06-15T17:04-07:00) — blank terminal on a session's first load (refresh race)

User: "when I tap on a session, the first time I load one, it shows the session, then a blank screen. looks like a race condition." Confirmed root cause: on a session's FIRST load, `_refreshSessionSnapshot` runs twice concurrently — once from `_selectSession` (main.dart) and once from `_onSessionViewFit`'s first-fit branch (gated on `!session.hasFitted`, so it only doubles on first load). Each refresh calls `applyHistory` → `HistoryBytes`, whose reducer does `_sink.clear()` then re-emulates (terminal_store.dart:196). The first refresh renders content; the second clears and replays underneath it — and the second often carries thinner/empty history (e.g. a fresh re-attach vs the restore path's full replay), so the screen goes blank. Only happens once because `hasFitted` is true thereafter.

Fix (client, `flutter/triage_client/lib/main.dart`):
- `_refreshSessionSnapshot`: per-session in-flight guard (`_refreshInFlight: Set<String>`, add at entry / remove in `finally`) — a second concurrent refresh for the same session returns immediately instead of clobbering the first. Defends against any concurrent trigger (select+fit, double-select, reconnect+select).
- `_selectSession`: only refresh when `session.hasFitted` — on first load the view-fit handler does the authoritative refresh at the REAL fitted size; refreshing from select too would race it and use an estimated pre-layout size. Re-selecting an already-fitted session still refreshes (its pane is kept alive, so no new fit fires).
- `flutter analyze lib/main.dart`: clean for the change (2 pre-existing infos at unrelated lines). Rebuilt Release + reinstalled to `/Applications/Triage.app` (pid 4238).

### BUG + FIX #2 (2026-06-15T17:53-07:00) — blank persists: rendering from the history-less resize snapshot

User after fix #1: "it still sometimes shows a blank session. it will show text, then clear it." The in-flight guard removed one race but not the real culprit. Root cause: when the view's fitted size differs from the session's recorded size, `_refreshSessionSnapshot` (and `_loadDaemonSession`) take a resize branch that **replaces the render snapshot with the `resizeSession` response**. The daemon's resize returns the plain `snapshot()` with `raw_output: Vec::new()` (session.rs:2449/3019; attach/Snapshot use `snapshot_with_history()` which DOES carry it — the doc says "Resize broadcasts ... never carry history"). So `_applySnapshotToSession` → `applyHistory([])` → `HistoryBytes([])` → `_sink.clear()` + nothing → the just-rendered content blanks. "Sometimes" = only when fitted size ≠ recorded size. History replays at the fitted size CLIENT-side (`HistoryBytes(cols:_viewCols, rows:_viewRows)`), so the resize snapshot was never needed for sizing — only as a host side-effect.

Fix (client, `main.dart`):
- `_refreshSessionSnapshot`: resize branch now calls `resizeSession` purely for the host side-effect and KEEPS the history-bearing attach snapshot for rendering (no longer overwrites `finalSnapshot`).
- `_loadDaemonSession`: the analogous prepared-snapshot swap now only fires when the prepared snapshot actually has `raw_output` — restore path still wins (it has history), resize path no longer blanks.
- Confirmed the incoming `Snapshot` resize-broadcast EVENT handler already ignores history correctly (tracks size only) — not a blank source.
- `flutter analyze` clean; rebuilt Release + reinstalled `/Applications/Triage.app` (pid 7267).

### CODE REVIEW (max effort) + FIXES (2026-06-15T20:58-07:00)

Ran `/code-review max` (Workflow: 10 finder angles → dedup → 1-vote verify → sweep → synth; 26 agents, 67 raw → 11 findings). Fixed all 11.

DAEMON (`session.rs`, `demote_dead_live_session`):
- #3 gate on `is_restorable_shell_launch` BEFORE demoting — a dead non-restorable `Live` session is no longer downgraded/reaped for a restore that bails. New test `restore_does_not_demote_a_non_restorable_dead_live_session` (proves it stays `Live` via an acquirable lease).
- #7 helper now returns `Result`; `restore_session` propagates with `?` — a confirmed-dead session whose log can't be rebuilt yields a real error instead of the misleading "already live or restoring".
- #8 only demote on `Ok(snapshot.exited == true)`; a snapshot *error* (actor worker gone, child maybe alive) no longer triggers demote → no orphaned child / duplicate shell.
- #9 deadness check done OFF-lock via new `request_snapshot(tx)` helper (clone tx under brief lock, round-trip off-lock), mirroring `request_summary_rows`; phase 3 no longer round-trips under the lock.
- #10 `persist_manifest` after the Live→Historical swap, like every other map mutator.
- #11 `actor.shutdown()` error now logged instead of `let _ =`.

CLIENT (`main.dart`):
- #4 `_applySnapshotToSession` gained a `renderSize` param; `_refreshSessionSnapshot` passes `replayTargetSize` so `lastFittedCols/Rows` track the VIEW size, not the host-sized attach snapshot — kills the resize ping-pong (#6 folds in: no more host bounce from polluted `lastFittedCols`).
- #1 restore branch now calls new `_resubscribeSessionEvents(sessionId)` (drops stale sub ids + re-subscribes) before the fresh attach — live output keeps flowing after a dead session is revived (restore spawns a new actor with an empty subscriber list).
- #2 `_selectSession` keeps the fitted-size-wins design but adds a post-frame fallback refresh when a selected session never reports a view-fit (zero-size / reused pane), so it can't be stranded on stale content.
- #5 `_applySnapshotToSession` bails if the `SessionVm` was disposed/replaced mid-await (`!_sessions.contains(session)`) — no use-after-dispose when a reconnect swaps the same-id object.

Daemon: 85 tests pass, clippy clean, fmt clean (mine; pre-existing 586 drift untouched). Client: `flutter analyze` clean (2 pre-existing infos). Rebuilt + reinstalled `/Applications/Triage.app` (pid 26549).

### ROOT-CAUSE FIX (2026-06-15T21:11-07:00) — handover was killing every session

User: "the handover still kills all sessions. any way we can make it seamless?" This is the long-running mystery (sessions die after a self-update handover; confirmed via `ps` that adopted shells were gone even though the daemon held their PTY masters).

Root cause: `ipc.rs` handover Phase-3 teardown called `manager.clear_all_live_sessions()`, which sends each actor `ActorCommand::Shutdown` → `shutdown()` → **`child.kill()`**. The old daemon was SIGKILLing the very shell processes it had just handed over. The PTY *masters* survive (the successor dup'd them via SCM_RIGHTS), so it's not a SIGHUP-on-master-close — the old daemon actively kills the shared child PIDs. Then it `process::exit(0)`s anyway, so the "cleanup" was pure destruction. `process::exit(0)` skips `Drop`, so nothing else needed to run.

Fix (daemon):
- New `SessionActor::detach(self)` — drops the worker/reader join handles WITHOUT sending shutdown and WITHOUT `child.kill()`, so the worker thread keeps owning the live child until `process::exit` (the OS then reaps threads/fds; the child, reparented to launchd, lives on under the successor's master fd).
- New `SessionManager::detach_all_live_sessions()` — drains the map and detaches each live actor. Handover-safe counterpart to the old kill path.
- `ipc.rs` Phase-3 now calls `detach_all_live_sessions()` instead of `clear_all_live_sessions()`.
- Removed the now-dead `clear_all_live_sessions()` (no remaining callers).
- Strengthened `handover_tests::test_zero_downtime_session_serialization_and_adoption`: after adopting into the successor, call the old manager's teardown (`detach_all_live_sessions`) and assert the adopted session is still `!exited` — the shared child survived. (With the old kill path this would fail.)

Daemon: 85 tests pass, clippy clean. DEPLOYMENT CAVEAT: the currently-running daemon still has the OLD (killing) teardown, so the ONE handover that deploys this fix will still tear down current sessions a final time; every handover AFTER that is seamless. Minor residual: a sub-ms reader race during the handover window (both daemons briefly read the master) — negligible for an idle session, not addressed.

## Commits

- b0662c5 — feat: local-LLM session snippets in the side rail via cera (LFM2.5)
- 94a3374 — fix(triaged): seed snippets for sessions adopted on handover
- e9561a1 — perf(triaged): off-lock cheap visible-rows snapshot for summarizer
- 4b96d10 — fix(client): forward session_snippet_updated push to the rail
- ff5573d — fix(client): stop blank terminals and first-load refresh races
- f05f8c6 — fix(triaged): keep sessions alive on restore and across handover
- HEAD — docs(devlog): record restore-revive, handover-detach, and client render fixes
