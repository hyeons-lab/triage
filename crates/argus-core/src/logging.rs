//! Shared tracing setup used by Argus binaries.
//!
//! Builds a layered subscriber: a JSON file layer writing to `config.log_file`
//! via a non-blocking appender, and an optional pretty stderr layer. Each
//! layer carries its own filter (configurable in [`Config`]); a set
//! `RUST_LOG` env var overrides both. Callers must keep the returned
//! [`WorkerGuard`] alive — dropping it flushes the appender thread.

use std::io::{self, IsTerminal};
use std::path::PathBuf;

use anyhow::{Context, Result};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::Layer;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, fmt};

const DEFAULT_FILTER: &str = "info,wezterm_term::terminalstate::performer=warn,tattoy_wezterm_term::terminalstate::performer=warn";

pub struct Config {
    pub log_file: PathBuf,
    pub console: bool,
    pub file_filter: String,
    pub console_filter: String,
}

pub fn default_config() -> Result<Config> {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .context("neither HOME nor USERPROFILE environment variable is set")?;
    let log_file = PathBuf::from(home).join(".local/state/argus/argus.log");
    Ok(Config {
        log_file,
        console: io::stderr().is_terminal(),
        file_filter: DEFAULT_FILTER.to_string(),
        console_filter: DEFAULT_FILTER.to_string(),
    })
}

pub fn init(config: Config) -> Result<WorkerGuard> {
    let parent = config
        .log_file
        .parent()
        .context("log_file has no parent directory")?;
    std::fs::create_dir_all(parent)
        .with_context(|| format!("creating log directory {}", parent.display()))?;

    let file_name = config
        .log_file
        .file_name()
        .context("log_file has no file name")?;
    let file_appender = tracing_appender::rolling::never(parent, file_name);
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);

    let file_filter = EnvFilter::try_from_default_env()
        .or_else(|_| EnvFilter::try_new(&config.file_filter))
        .context("parsing file filter")?;
    let file_layer = fmt::layer()
        .json()
        .with_writer(non_blocking)
        .with_filter(file_filter);

    let console_layer = if config.console {
        let console_filter = EnvFilter::try_from_default_env()
            .or_else(|_| EnvFilter::try_new(&config.console_filter))
            .context("parsing console filter")?;
        Some(
            fmt::layer()
                .with_writer(io::stderr)
                .pretty()
                .with_filter(console_filter),
        )
    } else {
        None
    };

    tracing_subscriber::registry()
        .with(file_layer)
        .with(console_layer)
        .try_init()
        .context("initializing tracing subscriber")?;

    Ok(guard)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_filters_suppress_terminal_bell_info_logs() {
        assert!(DEFAULT_FILTER.contains("wezterm_term::terminalstate::performer=warn"));
        assert!(DEFAULT_FILTER.contains("tattoy_wezterm_term::terminalstate::performer=warn"));
        EnvFilter::try_new(DEFAULT_FILTER).expect("valid default filter");
    }
}
