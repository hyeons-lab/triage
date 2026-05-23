//! VT byte-stream fixtures for terminal engine and session tests.

use vte::{Params, Parser, Perform};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Print(char),
    Execute(u8),
    Csi {
        params: Vec<Vec<u16>>,
        intermediates: String,
        ignore: bool,
        action: char,
    },
    Esc {
        intermediates: String,
        ignore: bool,
        byte: u8,
    },
    Osc {
        params: Vec<String>,
        bell_terminated: bool,
    },
    Hook {
        params: Vec<Vec<u16>>,
        intermediates: String,
        ignore: bool,
        action: char,
    },
    Put(u8),
    Unhook,
}

impl Event {
    pub fn to_snapshot_line(&self) -> String {
        match self {
            Self::Print(c) => format!("print {c:?}"),
            Self::Execute(byte) => format!("execute {}", control_name(*byte)),
            Self::Csi {
                params,
                intermediates,
                ignore,
                action,
            } => format!(
                "csi params={} intermediates={intermediates:?} ignore={ignore} action={action:?}",
                format_params(params)
            ),
            Self::Esc {
                intermediates,
                ignore,
                byte,
            } => format!(
                "esc intermediates={intermediates:?} ignore={ignore} byte={}",
                control_name(*byte)
            ),
            Self::Osc {
                params,
                bell_terminated,
            } => format!("osc params={params:?} bell_terminated={bell_terminated}"),
            Self::Hook {
                params,
                intermediates,
                ignore,
                action,
            } => format!(
                "hook params={} intermediates={intermediates:?} ignore={ignore} action={action:?}",
                format_params(params)
            ),
            Self::Put(byte) => format!("put {}", control_name(*byte)),
            Self::Unhook => "unhook".to_string(),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Transcript {
    events: Vec<Event>,
    plain_text: String,
}

impl Transcript {
    pub fn events(&self) -> &[Event] {
        &self.events
    }

    pub fn plain_text(&self) -> &str {
        &self.plain_text
    }

    pub fn events_as_lines(&self) -> String {
        self.events
            .iter()
            .map(Event::to_snapshot_line)
            .collect::<Vec<_>>()
            .join("\n")
    }
}

pub struct TerminalFixture {
    parser: Parser,
    transcript: Transcript,
}

impl Default for TerminalFixture {
    fn default() -> Self {
        Self {
            parser: Parser::new(),
            transcript: Transcript::default(),
        }
    }
}

impl TerminalFixture {
    pub fn feed(&mut self, bytes: &[u8]) {
        let Self { parser, transcript } = self;
        parser.advance(transcript, bytes);
    }

    pub fn transcript(&self) -> &Transcript {
        &self.transcript
    }

    pub fn plain_text(&self) -> &str {
        self.transcript.plain_text()
    }

    pub fn events_as_lines(&self) -> String {
        self.transcript.events_as_lines()
    }
}

impl Perform for Transcript {
    fn print(&mut self, c: char) {
        self.plain_text.push(c);
        self.events.push(Event::Print(c));
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            b'\n' => self.plain_text.push('\n'),
            b'\t' => self.plain_text.push('\t'),
            b'\r' => self.plain_text.push('\r'),
            _ => {}
        }
        self.events.push(Event::Execute(byte));
    }

    fn hook(&mut self, params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        self.events.push(Event::Hook {
            params: params_to_vec(params),
            intermediates: bytes_to_string(intermediates),
            ignore,
            action,
        });
    }

    fn put(&mut self, byte: u8) {
        self.events.push(Event::Put(byte));
    }

    fn unhook(&mut self) {
        self.events.push(Event::Unhook);
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        self.events.push(Event::Osc {
            params: params.iter().map(|param| bytes_to_string(param)).collect(),
            bell_terminated,
        });
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        self.events.push(Event::Csi {
            params: params_to_vec(params),
            intermediates: bytes_to_string(intermediates),
            ignore,
            action,
        });
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        self.events.push(Event::Esc {
            intermediates: bytes_to_string(intermediates),
            ignore,
            byte,
        });
    }
}

fn params_to_vec(params: &Params) -> Vec<Vec<u16>> {
    params.iter().map(|param| param.to_vec()).collect()
}

fn bytes_to_string(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn format_params(params: &[Vec<u16>]) -> String {
    let groups = params
        .iter()
        .map(|group| {
            let values = group
                .iter()
                .map(u16::to_string)
                .collect::<Vec<_>>()
                .join(":");
            format!("[{values}]")
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!("[{groups}]")
}

fn control_name(byte: u8) -> String {
    match byte {
        b'\n' => "LF".to_string(),
        b'\r' => "CR".to_string(),
        b'\t' => "TAB".to_string(),
        0x1b => "ESC".to_string(),
        _ if byte.is_ascii_graphic() => format!("{:?}", char::from(byte)),
        _ => format!("0x{byte:02x}"),
    }
}
