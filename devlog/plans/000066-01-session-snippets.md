<!-- Source: Claude Code plan mode, slug `we-want-to-use-ethereal-wigderson` (~/.claude/plans/we-want-to-use-ethereal-wigderson.md). Copied verbatim for durability. -->

# Plan: Local-LLM session snippets in the side rail

## Context

The Flutter client's session side rail lists every session by title + status, but the
user can't tell *what each session is actually doing* without opening it. We want a
short one-line, human-readable snippet per session (e.g. "running cargo test",
"editing config in nvim", "git rebase in progress") shown as a muted third line on each
rail tile.

We generate these locally — no cloud — using the **`cera`** inference engine
(`~/development/cera`, published on crates.io) running a small **LFM2.5** GGUF model.
cera downloads + caches the model by `(bundle_id, quant)` from HuggingFace
`LiquidAI/LeapBundles`, then runs blocking text generation.

**Decisions (from the user):**
- Model: **LFM2.5-1.2B, quant Q4_0** (configurable). Exact LeapBundles `bundle_id`
  resolved at implement time via `cera::bundle::list_leap_bundles()`.
- Trigger: **debounced on activity** — summarize after a session's output settles
  (~1.5s), rate-limited to ~5s per session, skipping unchanged screens.
- Enablement: **on by default**. cera is always compiled into `triaged`; a config flag
  (`[summarizer] enabled`, default `true`) can disable it. The ~0.7 GB model is
  downloaded lazily on first use, off the reactor, so first launch never blocks.

## Architecture (where everything lives)

The daemon **`triaged`** owns all session state and the WebSocket/FlatBuffers API, so
all new logic lives there + in shared types (`triage-core`) + the wire schema.

```
SessionActor (per session, existing)
  └─ handle_output()  ── emit DirtyTick (non-blocking) ──┐
                                                          ▼
SessionManager (shared Arc, existing)                Debounce loop (new bg thread)
  ├─ snippets: Arc<RwLock<HashMap<SessionId, SessionSnippet>>>   (settle + rate-limit + dedup)
  ├─ global push senders (new)                              │ enqueue SummarizeJob
  └─ Summarizer (new) ── single worker thread ─────────────┘
        owns ONE cera::CeraEngine (lazy-loaded, serialized inference)
        on_result → write cache + broadcast SessionSnippetUpdated to all clients
```

Inference is **serialized through one dedicated worker thread** that owns the engine —
not N concurrent `spawn_blocking` calls — because the engine is heavy (~1 GB) and
generation is CPU-bound. A bounded queue with per-session coalescing bounds growth and
always prefers the freshest screen.

## Implementation steps

### 1. Dependencies — root `Cargo.toml` + `crates/triaged/Cargo.toml`
cera is published on crates.io (`cera` v0.1.0, released 2026-06-10, edition 2024, repo
`hyeons-lab/cera`). Use a normal version dep — no path/git needed.
- Add to root `[workspace.dependencies]`:
  `cera = { version = "0.1", features = ["remote"] }`
- `remote` is **not** a default feature (it gates the HF downloader + reqwest); `mmap` IS default.
  `context_size` on `EngineConfig` is `usize` (cast from the `u32` config).
- In `crates/triaged/Cargo.toml`: `cera = { workspace = true }` (always compiled in — no Cargo
  feature gate, per "on by default"). Note edition/MSRV: cera needs Rust 1.85+ / edition 2024,
  which the triage workspace already uses.

### 2. New module `crates/triaged/src/summarizer.rs`
Confine all `cera` usage here. Key surface:

```rust
pub struct Summarizer { jobs: SyncSender<SummarizeJob>, enabled: bool }  // Clone

pub struct SummarizeJob { session_id: SessionId, prompt_text: String, output_seq: u64 }
pub struct SnippetResult { session_id: SessionId, text: String, generated_at_output_seq: u64 }

pub struct SummarizerConfig {
    enabled: bool, bundle_id: String, quant: String,
    context_size: u32, max_tokens: u32, cache_dir: PathBuf, queue_depth: usize,
}

impl Summarizer {
    /// Spawns the single worker thread; engine loads lazily on first job.
    /// `on_result` runs on the worker thread for each produced snippet.
    pub fn spawn(cfg: SummarizerConfig, on_result: impl Fn(SnippetResult) + Send + 'static) -> Self;
    pub fn disabled() -> Self;
    pub fn is_enabled(&self) -> bool;
    pub fn try_enqueue(&self, job: SummarizeJob) -> bool;  // non-blocking; drop if full
}
```

Worker thread (`run_worker`):
- `let mut engine: Option<CeraEngine> = None;` — load on first job via
  `CeraEngine::from_bundle_id(&cfg.bundle_id, &cfg.quant, EngineConfig { context_size,
  backend: BackendPreference::Auto, bundle_repo: Some(BundleRepo::new(&cfg.cache_dir)),
  ..Default::default() })`. On load failure: log, mark disabled, drain queue as no-ops —
  daemon stays fully functional.
- Coalesce: drain the queue keeping only the newest job per `session_id` before each run.
- Generate: `engine.new_session(SessionConfig::default())`, render the chat prompt with
  `let rendered = cera::tokenizer::apply_chat_template(engine.tokenizer(), &messages, true)?;`
  then `session.append_text(&rendered)?` (there is **no** `append_chat` for text-only — only
  `append_chat_with_images`; `apply_chat_template` is the public path and hard-errors if the GGUF
  has no chat template, which the Instruct model does carry). Then
  `generate(&GenerateOpts { max_tokens: cfg.max_tokens, temperature: 0.0, ..Default::default() }, &mut sink)`.
  `messages: Vec<cera::tokenizer::ChatMessage { role, content }>`.
- `OneLineSink` impls `cera::ModalitySink`: `on_text_tokens(&mut self, &[u32])` (optional —
  has a default) decodes via `engine.tokenizer().decode(..)`, accumulates into a `String`, stops
  at the first `\n`; `on_done(&mut self, FinishReason)` is the one **required** method.
- `sanitize_one_line()` then `on_result(...)`.

### 3. Trigger / debounce — `crates/triaged/src/session.rs`
- **Dirty hook (hot path):** add `dirty_tx: Option<Sender<DirtyTick>>` to `ActorState`,
  threaded through `spawn_with_events` / `adopt_sessions` alongside `event_session_id`.
  In `handle_output` (~`session.rs:1807`), after a successful `ingest`, send a tiny
  `DirtyTick { session_id, output_seq, last_byte_at: Instant::now() }` on an unbounded
  channel — one non-blocking `send`, no lock, no I/O.
- **Debounce loop:** `SessionManager::start_summarizer(cfg)` spawns one bg thread that
  drains `DirtyTick`s (coalescing by session, newest `output_seq` wins) and, for each
  session whose last tick is older than `settle_ms` (default 1500):
  - skip if `output_seq` unchanged since last summary;
  - skip if `< min_regen_ms` (default 5000) since last enqueue for this session;
  - fetch `snapshot_session(sid)`, build prompt text from `visible_rows`;
  - skip if the budgeted text hash equals the last summarized hash (spinner/cursor repaints);
  - `summarizer.try_enqueue(...)`, record `last_enqueue_at`.

### 4. Prompt — what we feed the model
- Use `SessionSnapshot.visible_rows` only (current screen; already plain text, bounded).
  `build_prompt_text`: take last ~20 non-blank rows, right-trim, drop blank lines, hard-cap
  ~1500 chars (well under a 1024-token context).
- Chat messages (`Vec<cera::tokenizer::ChatMessage>`, rendered via `apply_chat_template`):
  - system: `"You label terminal sessions. Reply with a terse description of what the
    session is doing, at most 8 words, no trailing punctuation, no quotes. Output only the label."`
  - user: the budgeted screen text.
- `temperature: 0.0`, `max_tokens: 24`, stop at first newline.
- `sanitize_one_line`: first line only, trim, collapse whitespace, strip wrapping
  quotes/backticks, cap ~8 words / ~60 chars; if empty, drop (don't overwrite a good prior).

### 5. Cache + result handling — `crates/triaged/src/session.rs`
- `SessionSnippet { text: String, generated_at_output_seq: u64 }`.
- `snippets: Arc<RwLock<HashMap<SessionId, SessionSnippet>>>` on `SessionManager`.
- `apply_snippet(result)`: write only if `result.generated_at_output_seq >= existing`
  (guards out-of-order results); then broadcast (step 6). Remove entry on session shutdown.
- No persistence across restarts initially — live sessions re-summarize on next output.
- **Construction-cycle fix:** build the snippet cache `Arc` + the global push `Sender`
  first; the `Summarizer::spawn` `on_result` closure closes over *those* (not over
  `SessionManager`), so the manager can still own the `Summarizer`.

### 6. Protocol — push event + current-value seed
Schema changes are **append-only** to unions/tables to preserve FlatBuffers ordinals and
back-compat. Files: `crates/triage-core/schema/triage.fbs`,
`crates/triage-transport-ws/src/lib.rs`, `crates/triage-transport-ws/src/flatbuffers_proto.rs`.

- **Push event (live updates, bypasses per-session subscriptions):**
  - fbs: `table SessionSnippetUpdatedPayload { session_id: string; snippet: string; output_seq: uint64; }`
    appended to the `ServerMessagePayload` union.
  - `ServerMessage::SessionSnippetUpdated { session_id, snippet, output_seq }` + FB/JSON serialize.
  - **Global delivery:** the existing WS loop drains per-connection events every 10ms
    (`ws.rs:192` `drain_events()`), but only for *subscribed* sessions. Add a global path:
    `WebSocketSessionConnection` gets `global_rx: Option<Receiver<ServerMessage>>` +
    `with_global_receiver(rx)`; `drain_events()` also drains it. In `ws.rs` (~`:130`), each
    new connection calls `manager.register_global_receiver()` (manager keeps the `Sender`
    in a `Vec`, pruning dead ones on send). `apply_snippet` → `manager.broadcast_snippet(...)`
    fans out to all senders. This reaches clients that never attached to the session — required
    for the rail.
- **Seed for newly-connected clients:**
  - `SessionApi::list_session_snippets(&self) -> Result<Vec<(SessionId, Option<String>)>>`
    — add in **3 places**: the trait def (default `Ok(vec![])`), the `impl<T> SessionApi for Arc<T>`
    forwarding impl (`session.rs:426`, methods are NOT auto-delegated), and the concrete
    `SessionManager` impl in `triaged`.
  - fbs: `ListSessionSnippetsRequest {}` (append to client request union),
    `SessionSnippetEntry { session_id; snippet; }` + `SessionSnippetsResult { entries; }`
    (append to server result union). Wire the enum variants + `handle_request` arm + FB
    (de)serialize. `SessionManager::list_session_snippets` read-locks the cache joined with
    `list_sessions()`.
- **Bonus:** add `snippet: Option<String>` (`#[serde(default)]`) to `SessionSnapshot` in fbs
  + `triage-core`, populated from the cache in the snapshot builders — rides along free for
  the attached session. Not sufficient alone (hence the list call + push remain primary).

### 7. Config — `crates/triage-core/src/config.rs`
Add a `[summarizer]` sub-struct to `Config` (`#[serde(default, deny_unknown_fields)]`):
```
enabled: bool = true                       // on by default
bundle_id: String = "LFM2.5-1.2B-Instruct-GGUF"   // exact LeapBundles id (verified in cera's live catalog test)
quant: String = "Q4_0"
context_size: u32 = 1024                   // cast to usize for EngineConfig
max_tokens: u32 = 24
settle_ms: u64 = 1500
min_regen_ms: u64 = 5000
cache_dir: Option<String> = None           // default ~/.cache/triage/models (see below)
```
Wire `Config::validate()`. **Config threading:** today `main.rs` builds the manager with
`SessionManager::default()` and the manager re-reads the config file internally for
`require_pairing` (`session.rs:329-339`). Two options, pick one: (a) thread the already-loaded
`Config` into a new `SessionManager` constructor / `start_summarizer(cfg)`; or (b) follow the
existing pattern and re-read `Config::load_from_path` inside `start_summarizer`. Prefer (a) to
avoid a third config read. Call `manager.start_summarizer(config.summarizer.clone())` from
`main.rs` after load when `enabled`, else leave the `Summarizer::disabled()` default.

**Model cache dir:** no helper exists today. Add `default_model_cache_dir()` mirroring
`default_log_dir()` (`session.rs:1148-1171`) but rooted at `XDG_CACHE_HOME` → `~/.cache`, returning
`.../triage/models`. `BundleRepo::new` caches downloads there.

### 8. Client (Dart) — `flutter/triage_client`
- Regenerate FB bindings: Rust bindings auto-regen via `crates/triage-core/build.rs` (runs
  `flatc --rust`). Dart has **no** regen script today — run manually:
  `flatc --dart -o flutter/triage_client/lib/generated crates/triage-core/schema/triage.fbs`,
  and commit the regenerated `lib/generated/*.dart`. Optionally add `scripts/regenerate-bindings.sh`
  doing both, since this is now a recurring need.
- `lib/services/triage_websocket_client.dart`: handle the appended
  `SessionSnippetUpdatedPayload` ordinal in `_parseServerMessage` → emit
  `{type: 'session_snippet_updated', session_id, snippet, output_seq}`; add
  `listSessionSnippets()` (mirrors `listSessions()`) + parse `SessionSnippetsResult` in
  `_parseServerResult`; optionally read the new `snippet` on the snapshot.
- `lib/main.dart`: add `String? snippet;` to `SessionVm` (~`:97`); on connect call
  `listSessionSnippets()` to seed, on each push update the matching `SessionVm.snippet` and
  rebuild; render `snippet` as a muted, single-line, ellipsized third line in
  `SessionListTile` (~`:2128`), hidden when null/empty.

## Critical files
- `crates/triaged/src/summarizer.rs` *(new)* — engine + worker + sink + sanitize
- `crates/triaged/src/session.rs` — dirty hook, debounce loop, snippet cache, global push, `list_session_snippets`
- `crates/triaged/src/ws.rs` — register global receiver per connection
- `crates/triaged/src/main.rs` — start summarizer from config
- `crates/triage-core/schema/triage.fbs` — push payload, list req/result, `SessionSnapshot.snippet`
- `crates/triage-core/src/session.rs` — `SessionApi::list_session_snippets`, `SessionSnapshot.snippet`
- `crates/triage-core/src/config.rs` — `[summarizer]` section
- `crates/triage-transport-ws/src/lib.rs` + `src/flatbuffers_proto.rs` — `ServerMessage`/`ServerResult` variants, global drain, (de)serialize
- `crates/triaged/Cargo.toml` + root `Cargo.toml` — `cera` dependency
- `flutter/triage_client/lib/services/triage_websocket_client.dart`, `lib/main.dart`, `lib/generated/…` — parse, seed, render

## Risks & mitigations
- **Model load / memory (~1 GB, ~0.7 GB download):** lazy first-job load on the worker
  thread, off the reactor; first launch never blocks (snippets just appear once ready).
  Load failure → `disabled()` + log, daemon unaffected.
- **CPU / battery:** debounce (settle) + per-session min-regen + screen-hash/output-seq
  dedup → summarize only on meaningful, settled change. `temp 0` + `max_tokens 24` keep
  each generation short.
- **Concurrency:** one worker owns the engine; all inference serialized; bounded queue +
  coalescing prefer the freshest screen.
- **Out-of-order results:** cache keeps the highest `output_seq`.
- **Back-compat:** append-only union/table edits preserve FB ordinals; new API method +
  `snippet` field have defaults — old peers/clients keep working.
- **Actor hot path:** dirty notify is one non-blocking `send` of a tiny struct — can't stall an actor.

## Verification (end-to-end)
1. `cargo build` / `cargo test` / `cargo clippy --workspace` — compiles with cera in
   (`cera = { version = "0.1", features = ["remote"] }`), schema + transport + new `SessionApi`
   method intact. Requires `flatc` on PATH (already needed by `build.rs`).
2. `flutter analyze` after regenerating Dart bindings.
3. Run `triaged` (default config → enabled). First run downloads LFM2.5-1.2B Q4_0 to the
   cache dir (watch logs); daemon stays responsive meanwhile.
4. Start a session, run something recognizable (`cargo test`, `git log`, an editor). Connect
   the Flutter client → rail tile shows a one-line snippet within ~`settle_ms` + inference
   after output settles, and updates as activity changes.
5. With a **second** client that never attaches to that session, confirm it still receives the
   snippet (validates the global push, not the per-subscription path).
6. Restart `triaged` → no crash with no persisted snippets; snippets repopulate on new output.
7. Set `[summarizer] enabled = false` → no model load, no snippet line; daemon fully functional.
