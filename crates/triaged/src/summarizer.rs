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

use cera::session::{FinishReason, ModalitySink};
use cera::tokenizer::{BpeTokenizer, ChatMessage};
use triage_core::session::SessionId;

/// Instruction given to the model. Kept terse; the model only needs to label.
const SYSTEM_PROMPT: &str = "You label terminal sessions. Reply with a terse description of what \
the session is doing, at most 8 words, no trailing punctuation, no quotes. Output only the label.";

/// Hard cap on the sanitized snippet length (characters).
const MAX_SNIPPET_CHARS: usize = 60;
/// Hard cap on the sanitized snippet length (words).
const MAX_SNIPPET_WORDS: usize = 8;

/// Runtime parameters for the summarizer worker. Built from the daemon config.
#[derive(Debug, Clone)]
pub struct SummarizerConfig {
    pub bundle_id: String,
    pub quant: String,
    pub context_size: u32,
    pub max_tokens: u32,
    pub cache_dir: PathBuf,
    pub queue_depth: usize,
}

/// A request to summarize one session's current screen.
pub struct SummarizeJob {
    pub session_id: SessionId,
    pub prompt_text: String,
    pub output_seq: u64,
}

/// A produced snippet, delivered to the `on_result` callback on the worker thread.
pub struct SnippetResult {
    pub session_id: SessionId,
    pub text: String,
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
                Ok(Some(text)) => on_result(SnippetResult {
                    session_id: job.session_id,
                    text,
                    generated_at_output_seq: job.output_seq,
                }),
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
    let mut session = engine.new_session(cera::SessionConfig::default());
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
    let opts = cera::GenerateOpts {
        max_tokens: config.max_tokens,
        temperature: 0.0,
        ..Default::default()
    };
    session.generate(&opts, &mut sink)?;

    Ok(sanitize_one_line(&sink.text))
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
        }));

        // First call downloads the model, so allow a generous timeout.
        let result = rx
            .recv_timeout(Duration::from_secs(600))
            .expect("a snippet within timeout");
        eprintln!("GENERATED SNIPPET: {:?}", result.text);
        assert!(!result.text.is_empty(), "snippet should be non-empty");
        assert!(
            result.text.split_whitespace().count() <= MAX_SNIPPET_WORDS,
            "snippet should respect the word cap: {:?}",
            result.text
        );
    }
}
