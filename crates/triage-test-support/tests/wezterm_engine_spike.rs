use std::sync::Arc;

use triage_test_support::terminal_acceptance::{SCENARIOS, TerminalScenario};
use wezterm_term::color::ColorPalette;
use wezterm_term::{Terminal, TerminalConfiguration, TerminalSize};

const ROWS: usize = 8;
const COLS: usize = 32;

#[derive(Debug)]
struct SpikeConfig;

impl TerminalConfiguration for SpikeConfig {
    fn color_palette(&self) -> ColorPalette {
        ColorPalette::default()
    }
}

fn terminal() -> Terminal {
    Terminal::new(
        TerminalSize {
            rows: ROWS,
            cols: COLS,
            pixel_width: 640,
            pixel_height: 384,
            dpi: 96,
        },
        Arc::new(SpikeConfig),
        "Triage",
        env!("CARGO_PKG_VERSION"),
        Box::new(Vec::<u8>::new()),
    )
}

fn visible_rows(terminal: &Terminal) -> Vec<String> {
    let screen = terminal.screen();
    let end = screen.scrollback_rows();
    let start = end.saturating_sub(screen.physical_rows);

    screen
        .lines_in_phys_range(start..end)
        .iter()
        .map(|line| {
            let mut row = line.as_str();
            let trimmed_len = row.trim_end().len();
            row.to_mut().truncate(trimmed_len);
            row.into_owned()
        })
        .collect()
}

fn visible_snapshot(terminal: &Terminal) -> String {
    let visible = visible_rows(terminal)
        .iter()
        .enumerate()
        .filter(|(_, row)| !row.is_empty())
        .map(|(index, row)| format!("{index:02}: {row}"))
        .collect::<Vec<_>>();

    if visible.is_empty() {
        "(blank)".to_owned()
    } else {
        visible.join("\n")
    }
}

fn feed_contiguous(scenario: TerminalScenario) -> Terminal {
    let mut terminal = terminal();
    terminal.advance_bytes(scenario.bytes);
    terminal
}

fn feed_chunked(scenario: TerminalScenario) -> Terminal {
    let mut terminal = terminal();
    for chunk in scenario.replay_chunks {
        terminal.advance_bytes(chunk);
    }
    terminal
}

#[test]
fn wezterm_term_accepts_chunked_pty_bytes() {
    let mut terminal = terminal();
    let initial_seqno = terminal.current_seqno();

    terminal.advance_bytes(b"one\r\n");
    terminal.advance_bytes(b"\x1b[31mtwo");
    terminal.advance_bytes(b"\x1b[0m\r\nthree");

    assert_eq!(terminal.get_size().rows, ROWS);
    assert_eq!(terminal.get_size().cols, COLS);
    assert_ne!(terminal.current_seqno(), initial_seqno);
    assert!(terminal.screen().scrollback_rows() >= ROWS);
}

#[test]
fn wezterm_term_visible_snapshots_cover_acceptance_scenarios() {
    let snapshot = SCENARIOS
        .iter()
        .map(|scenario| {
            let terminal = feed_contiguous(*scenario);
            format!(
                "## {} ({})\n{}\n",
                scenario.name,
                scenario.capability.as_str(),
                visible_snapshot(&terminal)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");

    insta::assert_snapshot!("wezterm_engine_visible_snapshots", snapshot);
}

#[test]
fn wezterm_term_chunked_replay_equivalence() {
    for scenario in SCENARIOS {
        assert_eq!(
            visible_rows(&feed_contiguous(*scenario)),
            visible_rows(&feed_chunked(*scenario)),
            "scenario {:?} changed visible cells when split across replay chunks",
            scenario.name
        );
    }
}
