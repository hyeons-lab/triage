//! Local-LLM session summarizer.
//!
//! Generates a short, one-line description of what a terminal session is doing
//! (e.g. "running cargo test") for display in the client's side rail. All
//! inference runs on a single dedicated worker thread that owns one
//! [`cera::CeraEngine`] — the engine is heavy (hundreds of MB) and generation is
//! CPU-bound, so serializing through one thread keeps inference off the tokio
//! reactor and off the session actors, and avoids loading the model more than
//! once. The model is downloaded + loaded lazily on the first job, so enabling
//! the summarizer never blocks daemon startup.

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};

use cera::manifest::GenerationDefaults;
use cera::session::{FinishReason, ModalitySink};
use cera::tokenizer::{BpeTokenizer, ChatMessage};
use triage_core::session::{SessionContext, SessionId};

/// Instruction given to the model. Kept terse; the model only needs to label.
const SYSTEM_PROMPT: &str = "You label terminal sessions. Reply with a terse description of what \
the session is doing, at most 8 words, no trailing punctuation, no quotes. Output only the label.";

/// Instruction for the longer-form detail summary shown in the hover popover and
/// used as the future session-search corpus. The repo/branch/worktree the
/// session lives in are prepended deterministically by [`generate_detail`] (the
/// model can't see them and must not invent them), so this prompt only asks for
/// the activity. Length is generous — enough sentences to localize the user.
const DETAIL_SYSTEM_PROMPT: &str = "You summarize terminal sessions so a developer can tell which \
of many sessions this is and what it needs. Describe what the session is doing: the task, the \
commands or tools running, the files or components involved, and the current state (building, \
tests passing/failing, an error and its message, or waiting at a prompt for input). Use as many \
short sentences as the activity needs — up to about five — but no filler. Be concrete and factual; \
prefer specifics (command names, file paths, error text) over generalities. Do not guess the git \
repository, branch, or directory. No markdown, no quotes, no preamble — output only the summary.";

/// Hard cap on the sanitized snippet length (characters).
const MAX_SNIPPET_CHARS: usize = 60;
/// Hard cap on the sanitized snippet length (words).
const MAX_SNIPPET_WORDS: usize = 8;

/// Hard cap on the sanitized detail summary length (characters). Applies only
/// to the model-written activity portion; the deterministic context header is
/// prepended afterwards and is never truncated.
const MAX_DETAIL_CHARS: usize = 480;

/// Runtime parameters for the summarizer worker. Built from the daemon config.
#[derive(Debug, Clone)]
pub struct SummarizerConfig {
    pub bundle_id: String,
    pub quant: String,
    pub context_size: u32,
    pub max_tokens: u32,
    /// Token budget for the longer-form detail summary (a few sentences).
    pub detail_max_tokens: u32,
    pub cache_dir: PathBuf,
    pub queue_depth: usize,
}

/// A request to summarize one session's current screen.
pub struct SummarizeJob {
    pub session_id: SessionId,
    pub prompt_text: String,
    pub output_seq: u64,
    /// Git context (repo/branch/worktree) for this session, used to build the
    /// deterministic localization header on the detail summary. `None` when the
    /// session isn't inside a git repo.
    pub context: Option<SessionContext>,
}

/// A produced snippet, delivered to the `on_result` callback on the worker thread.
pub struct SnippetResult {
    pub session_id: SessionId,
    pub text: String,
    /// Longer-form summary for the hover popover / search: a deterministic
    /// `repo · branch · worktree` header (when the session has git context)
    /// followed by the model's activity description. `None` only when neither
    /// the model nor the git context produced anything usable (keeps any prior
    /// detail rather than clearing it).
    pub detail: Option<String>,
    pub generated_at_output_seq: u64,
}

/// Handle to the summarizer worker. Cheap to clone (just a channel sender).
/// A disabled handle accepts and drops every job — used when summarization is
/// turned off or the model fails to load.
#[derive(Clone)]
pub struct Summarizer {
    jobs: Option<SyncSender<SummarizeJob>>,
}

impl Summarizer {
    /// Spawns the worker thread. The engine is loaded lazily on the first job.
    /// `on_result` is invoked on the worker thread for each produced snippet.
    pub fn spawn(
        config: SummarizerConfig,
        on_result: impl Fn(SnippetResult) + Send + 'static,
    ) -> Self {
        let (tx, rx) = sync_channel(config.queue_depth.max(1));
        let builder = std::thread::Builder::new().name("triage-summarizer".to_string());
        if let Err(error) = builder.spawn(move || run_worker(config, rx, on_result)) {
            tracing::error!(%error, "failed to spawn summarizer thread; snippets disabled");
            return Self::disabled();
        }
        Self { jobs: Some(tx) }
    }

    /// A no-op summarizer that never produces snippets.
    pub fn disabled() -> Self {
        Self { jobs: None }
    }

    pub fn is_enabled(&self) -> bool {
        self.jobs.is_some()
    }

    /// Enqueues a job without blocking. Returns `false` if the summarizer is
    /// disabled or the bounded queue is full (the upstream debounce loop will
    /// re-enqueue on the next settle, so dropping here is acceptable).
    pub fn try_enqueue(&self, job: SummarizeJob) -> bool {
        match &self.jobs {
            Some(tx) => match tx.try_send(job) {
                Ok(()) => true,
                Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => false,
            },
            None => false,
        }
    }
}

fn run_worker(
    config: SummarizerConfig,
    jobs: Receiver<SummarizeJob>,
    on_result: impl Fn(SnippetResult),
) {
    let mut engine: Option<cera::CeraEngine> = None;
    let mut load_failed = false;

    while let Ok(first) = jobs.recv() {
        // Drain everything immediately queued and coalesce per session so a
        // busy session doesn't summarize a stale screen multiple times.
        let batch = coalesce(first, &jobs);

        if load_failed {
            continue;
        }
        if engine.is_none() {
            match load_engine(&config) {
                Ok(loaded) => {
                    tracing::info!(
                        bundle_id = %config.bundle_id,
                        quant = %config.quant,
                        "loaded session summarizer model"
                    );
                    engine = Some(loaded);
                }
                Err(error) => {
                    tracing::error!(%error, "failed to load summarizer model; snippets disabled");
                    load_failed = true;
                    continue;
                }
            }
        }
        let engine = engine.as_ref().expect("engine loaded above");

        for job in batch {
            match generate_one_line(engine, &config, &job.prompt_text) {
                Ok(Some(text)) => {
                    // Second, longer-form pass for the hover popover / search.
                    // Failures here are non-fatal: emit the one-liner with no
                    // detail rather than dropping the result entirely.
                    let detail = match generate_detail(
                        engine,
                        &config,
                        &job.prompt_text,
                        job.context.as_ref(),
                    ) {
                        Ok(detail) => detail,
                        Err(error) => {
                            tracing::warn!(
                                %error,
                                session_id = %job.session_id,
                                "detail summary generation failed"
                            );
                            None
                        }
                    };
                    on_result(SnippetResult {
                        session_id: job.session_id,
                        text,
                        detail,
                        generated_at_output_seq: job.output_seq,
                    });
                }
                Ok(None) => {
                    tracing::debug!(
                        session_id = %job.session_id,
                        "snippet generation produced empty output (dropped)"
                    )
                }
                Err(error) => {
                    tracing::warn!(%error, session_id = %job.session_id, "snippet generation failed")
                }
            }
        }
    }
}

/// Coalesces the first job plus any immediately-queued jobs, keeping the
/// newest job (by `output_seq`) per session. Insertion order is not preserved;
/// order does not matter since each job is independent.
fn coalesce(first: SummarizeJob, jobs: &Receiver<SummarizeJob>) -> Vec<SummarizeJob> {
    use std::collections::HashMap;
    let mut latest: HashMap<SessionId, SummarizeJob> = HashMap::new();
    let mut consider = |job: SummarizeJob| match latest.get(&job.session_id) {
        Some(existing) if existing.output_seq >= job.output_seq => {}
        _ => {
            latest.insert(job.session_id.clone(), job);
        }
    };
    consider(first);
    while let Ok(job) = jobs.try_recv() {
        consider(job);
    }
    latest.into_values().collect()
}

fn load_engine(config: &SummarizerConfig) -> Result<cera::CeraEngine, cera::session::CeraError> {
    let repo = cera::bundle::BundleRepo::new(&config.cache_dir);
    let engine_config = cera::EngineConfig {
        context_size: config.context_size as usize,
        backend: cera::BackendPreference::Auto,
        bundle_repo: Some(repo),
    };
    cera::CeraEngine::from_bundle_id(&config.bundle_id, &config.quant, engine_config)
}

/// Runs one inference and returns a sanitized one-line snippet, or `None` if the
/// model produced nothing usable (so we don't overwrite a good prior snippet).
fn generate_one_line(
    engine: &cera::CeraEngine,
    config: &SummarizerConfig,
    prompt_text: &str,
) -> anyhow::Result<Option<String>> {
    let mut session = engine.new_session(cera::SessionConfig::default())?;
    let messages = [
        ChatMessage {
            role: "system".to_string(),
            content: SYSTEM_PROMPT.to_string(),
        },
        ChatMessage {
            role: "user".to_string(),
            content: prompt_text.to_string(),
        },
    ];
    let rendered = cera::tokenizer::apply_chat_template(engine.tokenizer(), &messages, true)?;
    session.append_text(&rendered)?;

    let mut sink = OneLineSink::new(engine.tokenizer());
    // The one-line label stays greedy (temperature 0) regardless of the model's
    // manifest sampling params, so the terse rail label is stable across
    // regenerations. The detail pass honours the manifest params instead.
    let opts = cera::GenerateOpts {
        max_tokens: config.max_tokens,
        temperature: 0.0,
        ..Default::default()
    };
    session.generate(&opts, &mut sink)?;

    Ok(sanitize_one_line(&sink.text))
}

/// Runs one inference for the longer-form detail summary and returns it
/// sanitized, with a deterministic `repo · branch · worktree` header prepended
/// so the reader can localize the session at a glance. Returns `None` only when
/// neither the model nor the git context produced anything usable.
fn generate_detail(
    engine: &cera::CeraEngine,
    config: &SummarizerConfig,
    prompt_text: &str,
    context: Option<&SessionContext>,
) -> anyhow::Result<Option<String>> {
    let mut session = engine.new_session(cera::SessionConfig::default())?;
    let messages = [
        ChatMessage {
            role: "system".to_string(),
            content: DETAIL_SYSTEM_PROMPT.to_string(),
        },
        ChatMessage {
            role: "user".to_string(),
            content: prompt_text.to_string(),
        },
    ];
    let rendered = cera::tokenizer::apply_chat_template(engine.tokenizer(), &messages, true)?;
    session.append_text(&rendered)?;

    let mut sink = DetailSink::new(engine.tokenizer());
    let opts = sampling_opts(engine, config.detail_max_tokens);
    session.generate(&opts, &mut sink)?;

    let header = context.and_then(SessionContext::localization_label);
    let summary = sanitize_detail(&sink.text);
    Ok(match (header, summary) {
        (Some(header), Some(summary)) => Some(format!("{header}\n{summary}")),
        (Some(header), None) => Some(header),
        (None, summary) => summary,
    })
}

/// Builds [`GenerateOpts`] for the detail-summary pass.
///
/// When the loaded model is a text bundle whose LeapBundles manifest ships
/// advisory `sampling_parameters`, honor them: start from cera's own defaults
/// and apply every param the manifest carries (temperature / min-p / top-p /
/// top-k / repetition-penalty), so a param the manifest *omits* keeps cera's
/// default rather than being forced off. In particular a manifest that sets
/// top-p/top-k but no temperature still samples (at cera's default temperature)
/// instead of collapsing to greedy.
///
/// A manifest that carries no sampling guidance at all — a `Text` block with
/// every field unset, a bare GGUF, or a non-text inference type — falls back to
/// deterministic greedy decoding (temperature 0) so the detail is stable across
/// regenerations. The one-line label deliberately does not use this — it stays
/// greedy for a stable rail.
///
/// The `GenerationDefaults::Text` destructure is exhaustive (no `..`) on
/// purpose: if cera grows another manifest sampling param, this stops
/// compiling so we wire it through rather than silently dropping it.
fn sampling_opts(engine: &cera::CeraEngine, max_tokens: u32) -> cera::GenerateOpts {
    sampling_opts_from_defaults(&engine.manifest().generation_defaults, max_tokens)
}

/// Engine-free core of [`sampling_opts`] — splits the decision out from the
/// `CeraEngine` so the manifest→opts mapping is unit-testable.
fn sampling_opts_from_defaults(
    defaults: &GenerationDefaults,
    max_tokens: u32,
) -> cera::GenerateOpts {
    // Start from cera's real defaults; the greedy fallback below only kicks in
    // when the manifest provides no guidance at all.
    let mut opts = cera::GenerateOpts {
        max_tokens,
        ..Default::default()
    };
    if let GenerationDefaults::Text {
        temperature,
        min_p,
        top_p,
        top_k,
        repetition_penalty,
    } = defaults
    {
        // Honor the manifest only when its `Text` block actually carries a
        // sampling param. An all-`None` block (or a non-`Text` manifest) falls
        // through to greedy rather than silently inheriting cera's sampling
        // default temperature.
        let has_sampling_params = temperature.is_some()
            || min_p.is_some()
            || top_p.is_some()
            || top_k.is_some()
            || repetition_penalty.is_some();
        if has_sampling_params {
            if let Some(temperature) = temperature {
                opts.temperature = *temperature;
            }
            if let Some(min_p) = min_p {
                opts.min_p = *min_p;
            }
            if let Some(top_p) = top_p {
                opts.top_p = *top_p;
            }
            if let Some(top_k) = top_k {
                opts.top_k = *top_k;
            }
            if let Some(repetition_penalty) = repetition_penalty {
                opts.repetition_penalty = *repetition_penalty;
            }
            return opts;
        }
    }
    // No manifest sampling guidance: deterministic greedy decoding.
    opts.temperature = 0.0;
    opts
}

/// A [`ModalitySink`] that accumulates all decoded text (multi-line). Used for
/// the longer detail summary, which may span a few sentences.
struct DetailSink<'a> {
    tokenizer: &'a BpeTokenizer,
    text: String,
}

impl<'a> DetailSink<'a> {
    fn new(tokenizer: &'a BpeTokenizer) -> Self {
        Self {
            tokenizer,
            text: String::new(),
        }
    }
}

impl ModalitySink for DetailSink<'_> {
    fn on_text_tokens(&mut self, tokens: &[u32]) {
        self.text.push_str(&self.tokenizer.decode(tokens));
    }

    fn on_done(&mut self, _reason: FinishReason) {}
}

/// Normalizes the raw detail output: trims, collapses blank-line runs and
/// internal whitespace, caps at [`MAX_DETAIL_CHARS`]. Returns `None` if empty.
fn sanitize_detail(raw: &str) -> Option<String> {
    // Collapse all whitespace (including newlines) to single spaces — the
    // popover renders it as a wrapped paragraph.
    let collapsed: String = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = collapsed.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.chars().count() > MAX_DETAIL_CHARS {
        let mut capped: String = trimmed.chars().take(MAX_DETAIL_CHARS).collect();
        capped = capped.trim_end().to_string();
        capped.push('…');
        Some(capped)
    } else {
        Some(trimmed.to_string())
    }
}

/// A [`ModalitySink`] that accumulates decoded text up to the first newline.
struct OneLineSink<'a> {
    tokenizer: &'a BpeTokenizer,
    text: String,
    stopped: bool,
}

impl<'a> OneLineSink<'a> {
    fn new(tokenizer: &'a BpeTokenizer) -> Self {
        Self {
            tokenizer,
            text: String::new(),
            stopped: false,
        }
    }
}

impl ModalitySink for OneLineSink<'_> {
    fn on_text_tokens(&mut self, tokens: &[u32]) {
        if self.stopped {
            return;
        }
        let decoded = self.tokenizer.decode(tokens);
        if let Some(newline) = decoded.find('\n') {
            self.text.push_str(&decoded[..newline]);
            self.stopped = true;
        } else {
            self.text.push_str(&decoded);
        }
    }

    fn on_done(&mut self, _reason: FinishReason) {}
}

/// Normalizes raw model output into a single short label, or `None` if empty.
fn sanitize_one_line(raw: &str) -> Option<String> {
    let first_line = raw.lines().next().unwrap_or("").trim();
    // Collapse internal whitespace runs to single spaces.
    let collapsed: String = first_line.split_whitespace().collect::<Vec<_>>().join(" ");
    // Strip a single layer of wrapping quotes/backticks.
    let unquoted = collapsed
        .strip_prefix(['"', '\'', '`'])
        .and_then(|s| s.strip_suffix(['"', '\'', '`']))
        .unwrap_or(&collapsed)
        .trim();
    // Cap by words, then by characters.
    let mut capped: String = unquoted
        .split(' ')
        .take(MAX_SNIPPET_WORDS)
        .collect::<Vec<_>>()
        .join(" ");
    if capped.chars().count() > MAX_SNIPPET_CHARS {
        capped = capped.chars().take(MAX_SNIPPET_CHARS).collect::<String>();
        capped = capped.trim_end().to_string();
    }
    if capped.is_empty() {
        None
    } else {
        Some(capped)
    }
}

/// Builds the prompt text fed to the model from a session's visible rows: the
/// last `MAX_PROMPT_ROWS` non-blank rows, right-trimmed, capped at
/// `MAX_PROMPT_CHARS`. Returns `None` when the screen is effectively empty.
pub fn build_prompt_text(visible_rows: &[String]) -> Option<String> {
    const MAX_PROMPT_ROWS: usize = 20;
    const MAX_PROMPT_CHARS: usize = 1500;

    let kept: Vec<&str> = visible_rows
        .iter()
        .map(|row| row.trim_end())
        .filter(|row| !row.is_empty())
        .collect();
    if kept.is_empty() {
        return None;
    }
    let start = kept.len().saturating_sub(MAX_PROMPT_ROWS);
    let mut text = kept[start..].join("\n");
    if text.chars().count() > MAX_PROMPT_CHARS {
        // Keep the tail (most recent activity) within the char budget.
        let skip = text.chars().count() - MAX_PROMPT_CHARS;
        text = text.chars().skip(skip).collect();
    }
    Some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_quotes_and_caps_words() {
        assert_eq!(
            sanitize_one_line("\"running cargo test\""),
            Some("running cargo test".to_string())
        );
        assert_eq!(
            sanitize_one_line("one two three four five six seven eight nine ten"),
            Some("one two three four five six seven eight".to_string())
        );
        assert_eq!(
            sanitize_one_line("first line\nsecond line"),
            Some("first line".to_string())
        );
        assert_eq!(sanitize_one_line("   \n  "), None);
    }

    #[test]
    fn sanitize_detail_collapses_whitespace_and_caps() {
        assert_eq!(
            sanitize_detail("  Running cargo test.\n\nAll 83 tests passed.  "),
            Some("Running cargo test. All 83 tests passed.".to_string())
        );
        assert_eq!(sanitize_detail("   \n\n  "), None);
        let long = "word ".repeat(100);
        let capped = sanitize_detail(&long).expect("non-empty");
        assert!(capped.chars().count() <= MAX_DETAIL_CHARS + 1, "{capped:?}");
        assert!(capped.ends_with('…'), "{capped:?}");
    }

    #[test]
    fn build_prompt_drops_blank_rows_and_keeps_tail() {
        let rows = vec![
            "".to_string(),
            "$ cargo build   ".to_string(),
            "   ".to_string(),
            "Compiling triaged".to_string(),
        ];
        let prompt = build_prompt_text(&rows).expect("non-empty");
        assert_eq!(prompt, "$ cargo build\nCompiling triaged");
        assert_eq!(build_prompt_text(&[]), None);
        assert_eq!(build_prompt_text(&["".to_string(), "  ".to_string()]), None);
    }

    // End-to-end: downloads the real LFM2.5 model (~0.7GB, cached) and runs
    // inference. Ignored so CI never pays the download; run manually with:
    //   cargo test -p triaged --release -- --ignored end_to_end --nocapture
    #[test]
    #[ignore = "downloads ~0.7GB model and runs local inference"]
    fn end_to_end_generates_a_snippet() {
        use std::sync::mpsc;
        use std::time::Duration;
        use triage_core::session::SessionId;

        let config = SummarizerConfig {
            bundle_id: "LFM2.5-1.2B-Instruct-GGUF".to_string(),
            quant: "Q4_0".to_string(),
            context_size: 1024,
            max_tokens: 24,
            detail_max_tokens: 96,
            cache_dir: crate::session::default_model_cache_dir(),
            queue_depth: 4,
        };

        let (tx, rx) = mpsc::channel();
        let summarizer = Summarizer::spawn(config, move |result| {
            let _ = tx.send(result);
        });
        assert!(summarizer.is_enabled(), "summarizer should spawn");

        let prompt = build_prompt_text(&[
            "user@host project % cargo test".to_string(),
            "   Compiling triaged v0.1.5".to_string(),
            "    Finished `test` profile in 4.2s".to_string(),
            "running 83 tests".to_string(),
            "test result: ok. 83 passed; 0 failed".to_string(),
        ])
        .expect("prompt");

        assert!(summarizer.try_enqueue(SummarizeJob {
            session_id: SessionId::new("e2e").unwrap(),
            prompt_text: prompt,
            output_seq: 1,
            context: Some(SessionContext {
                repository_root: Some("/home/dev/triage".into()),
                worktree_root: Some("/home/dev/triage/worktrees/feat-summary".into()),
                branch: Some("feat/summary".to_string()),
            }),
        }));

        // First call downloads the model, so allow a generous timeout.
        let result = rx
            .recv_timeout(Duration::from_secs(600))
            .expect("a snippet within timeout");
        eprintln!("GENERATED SNIPPET: {:?}", result.text);
        eprintln!("GENERATED DETAIL: {:?}", result.detail);
        assert!(!result.text.is_empty(), "snippet should be non-empty");
        assert!(
            result.text.split_whitespace().count() <= MAX_SNIPPET_WORDS,
            "snippet should respect the word cap: {:?}",
            result.text
        );
        // The detail must lead with the deterministic localization header.
        let detail = result.detail.expect("detail summary present");
        assert!(
            detail.starts_with("triage  ·  feat/summary  ·  feat-summary"),
            "detail should lead with the repo/branch/worktree header: {detail:?}"
        );
    }

    #[test]
    fn sampling_opts_without_temperature_samples_at_cera_default() {
        // Manifest recommends top-p/top-k but omits temperature: we must NOT
        // collapse to greedy, or those params never take effect. Temperature
        // stays at cera's sampling default so the recommendation is honored.
        let cera_default = cera::GenerateOpts::default();
        let opts = sampling_opts_from_defaults(
            &GenerationDefaults::Text {
                temperature: None,
                min_p: None,
                top_p: Some(0.5),
                top_k: Some(20),
                repetition_penalty: None,
            },
            99,
        );
        assert_eq!(opts.max_tokens, 99);
        assert!(
            (opts.temperature - cera_default.temperature).abs() < 1e-6,
            "temperature should fall back to cera's default, not greedy: {}",
            opts.temperature
        );
        assert!(opts.temperature > 0.0, "must stay stochastic, not greedy");
        assert!((opts.top_p - 0.5).abs() < 1e-6);
        assert_eq!(opts.top_k, 20);
    }

    #[test]
    fn sampling_opts_with_all_params_unset_is_greedy() {
        // A `Text` block that carries no sampling guidance falls back to
        // deterministic greedy decoding (temperature 0).
        let opts = sampling_opts_from_defaults(
            &GenerationDefaults::Text {
                temperature: None,
                min_p: None,
                top_p: None,
                top_k: None,
                repetition_penalty: None,
            },
            32,
        );
        assert!(
            opts.temperature.abs() < 1e-6,
            "all-unset manifest should be greedy: {}",
            opts.temperature
        );
    }

    #[test]
    fn sampling_opts_non_text_manifest_is_greedy() {
        // A non-text manifest (here: audio) carries no text sampling params, so
        // the detail pass stays greedy.
        let opts = sampling_opts_from_defaults(
            &GenerationDefaults::Audio {
                number_of_decoding_threads: None,
            },
            32,
        );
        assert!(
            opts.temperature.abs() < 1e-6,
            "non-text manifest should be greedy: {}",
            opts.temperature
        );
    }

    #[test]
    fn sampling_opts_applies_explicit_manifest_params() {
        let opts = sampling_opts_from_defaults(
            &GenerationDefaults::Text {
                temperature: Some(0.3),
                min_p: Some(0.05),
                top_p: Some(0.8),
                top_k: Some(15),
                repetition_penalty: Some(1.1),
            },
            64,
        );
        assert_eq!(opts.max_tokens, 64);
        assert!((opts.temperature - 0.3).abs() < 1e-6);
        assert!((opts.min_p - 0.05).abs() < 1e-6);
        assert!((opts.top_p - 0.8).abs() < 1e-6);
        assert_eq!(opts.top_k, 15);
        assert!((opts.repetition_penalty - 1.1).abs() < 1e-6);
    }
}
