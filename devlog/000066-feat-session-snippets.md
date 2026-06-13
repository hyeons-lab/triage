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

## Issues

- 2026-06-12T16:48-07:00 **cera 0.1.0 requires nightly Rust.** Its crate root has `#![cfg_attr(target_arch="aarch64", feature(stdarch_neon_dotprod, stdarch_aarch64_prefetch))]` — unconditional on Apple Silicon, no cera feature flag to opt out (the dotprod intrinsics `vdotq_s32`/`_prefetch` are genuinely unstable on 1.94.1, tracking issues #117224/#117217 — confirmed by a probe). **Resolution (user decision, 2026-06-12): switch triage/triaged to nightly.** triage is an app, not a library, so requiring nightly is acceptable and far simpler than gating the nightly kernels inside cera (which would touch numerical hot-path GEMV/GEMM + BLAS + parity tests). Pinned `rust-toolchain.toml` → `nightly-2026-04-02`; updated `.github/workflows/ci.yml` (both jobs) and `publish.yml` Rust toolchain pins to match. Verified: full workspace builds, `cargo clippy --workspace --all-targets --all-features -D warnings` clean, `cargo doc -D warnings` clean, `cargo test --workspace --all-features` all pass — all on the pinned nightly with no `RUSTC_BOOTSTRAP`. (An earlier interim plan to gate cera behind a feature + release cera 0.1.1 was dropped in favor of this simpler path.) Do NOT publish without asking first.
  - The nightly clippy bump surfaced two pre-existing `clippy::collapsible_match` lints (CI uses `-D warnings`): `stress_client.rs` arg loop (crate-level `#![allow]`) and `triage/src/main.rs:432` event-loop match (the inner `if` uses `?`, so it can't become a match guard — targeted `#[allow]`). Both are pre-existing, unrelated to the feature; suppressed rather than refactored.

## Verification

- 2026-06-12T17:35-07:00 `cargo test -p triaged --release -- --ignored end_to_end --nocapture` — downloaded LFM2.5-1.2B-Instruct-GGUF/Q4_0 (cached under `~/.cache/triage/models`), ran one inference on a sample `cargo test` screen, generated snippet `"Building and testing project version"`, passed. Full path: BundleRepo download → from_bundle_id load → apply_chat_template → generate → OneLineSink → sanitize.
- CI-equivalent local runs on nightly-2026-04-02: `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings` ✓, `cargo doc --workspace --all-features -D warnings` ✓, `cargo test --workspace --all-features --locked` ✓, `flutter analyze` ✓ (no new issues).

## Lessons Learned

- cera text-only chat has no `append_chat`; render via `cera::tokenizer::apply_chat_template(tokenizer, &messages, true)` then `session.append_text(rendered)`. `remote` feature is opt-in (HF downloader); `EngineConfig.context_size` is `usize`.
- triage transport delivers server events only per-subscription; a connection-wide push needs a separate global channel drained in `drain_events` (done).
- The Rust TUI talks to the daemon in-process via `SessionApi`, not the WS borrowed parser — only Flutter + the stress_client use the wire protocol.

## Commits

- HEAD — feat: local-LLM session snippets in the side rail via cera (LFM2.5)
