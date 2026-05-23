use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::Line;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi;
use triage_test_support::terminal_acceptance::{SCENARIOS, TerminalScenario};

const ROWS: usize = 8;
const COLS: usize = 32;

struct SpikeSize {
    columns: usize,
    screen_lines: usize,
}

impl Dimensions for SpikeSize {
    fn total_lines(&self) -> usize {
        self.screen_lines
    }

    fn screen_lines(&self) -> usize {
        self.screen_lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}

fn terminal() -> Term<VoidListener> {
    Term::new(
        Config::default(),
        &SpikeSize {
            columns: COLS,
            screen_lines: ROWS,
        },
        VoidListener,
    )
}

fn visible_rows(terminal: &Term<VoidListener>) -> Vec<String> {
    let grid = terminal.grid();

    (0..terminal.screen_lines())
        .map(|row| {
            let mut row: String = grid[Line(row as i32)][..]
                .iter()
                .map(|cell| cell.c)
                .collect();
            let trimmed_len = row.trim_end().len();
            row.truncate(trimmed_len);
            row
        })
        .collect()
}

fn visible_snapshot(terminal: &Term<VoidListener>) -> String {
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

fn feed_contiguous(scenario: TerminalScenario) -> Term<VoidListener> {
    let mut terminal = terminal();
    let mut parser = ansi::Processor::<ansi::StdSyncHandler>::new();
    parser.advance(&mut terminal, scenario.bytes);
    terminal
}

fn feed_chunked(scenario: TerminalScenario) -> Term<VoidListener> {
    let mut terminal = terminal();
    let mut parser = ansi::Processor::<ansi::StdSyncHandler>::new();
    for chunk in scenario.replay_chunks {
        parser.advance(&mut terminal, chunk);
    }
    terminal
}

#[test]
fn alacritty_terminal_accepts_chunked_pty_bytes() {
    let mut terminal = terminal();
    let mut parser = ansi::Processor::<ansi::StdSyncHandler>::new();
    parser.advance(&mut terminal, b"one\r\n");
    parser.advance(&mut terminal, b"\x1b[31mtwo");
    parser.advance(&mut terminal, b"\x1b[0m\r\nthree");

    assert_eq!(terminal.screen_lines(), ROWS);
    assert_eq!(terminal.columns(), COLS);
    assert_eq!(terminal.grid().display_offset(), 0);
}

#[test]
fn alacritty_terminal_visible_snapshots_cover_acceptance_scenarios() {
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

    insta::assert_snapshot!("alacritty_engine_visible_snapshots", snapshot);
}

#[test]
fn alacritty_terminal_chunked_replay_equivalence() {
    for scenario in SCENARIOS {
        assert_eq!(
            visible_rows(&feed_contiguous(*scenario)),
            visible_rows(&feed_chunked(*scenario)),
            "scenario {:?} changed visible cells when split across replay chunks",
            scenario.name
        );
    }
}
