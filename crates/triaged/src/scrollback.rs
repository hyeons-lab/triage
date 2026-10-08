//! Ingest-time scrollback journal: persist scrolled lines the byte log buries.
//!
//! Sessions whose output is dominated by in-place TUI redraws (scroll-region
//! updates, cursor-addressed repaints) hold no scrollback in any reachable
//! byte window: region scrolls never enter the scrollback buffer, so the
//! megabyte tail replays to a single screen. The byte log still records
//! everything, but windows measured in bytes cannot reach past the desert.
//!
//! The ingest path already runs every PTY byte through a full emulator
//! (`tattoy_wezterm_term::Terminal`), whose scrollback holds exactly the
//! scrolled lines. This module journals those lines to disk as SGR-encoded
//! bytes stamped with their log offset, so history serving can prefix the
//! scrolled lines older than the raw window ahead of the raw tail. The
//! client replays one byte stream and needs no changes: the prefix scrolls
//! in as scrollback, the raw tail re-anchors and repaints the viewport.
//!
//! Journal records carry the exact bytes served (encoded once at ingest),
//! each starting with a reset so rendition cannot bleed across records.
//! Wiped (3J) scrollback stays journaled: triage history is a record, not
//! a mirror of terminal scrollback. Alt-screen content is never journaled.

use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use tattoy_wezterm_surface::Line;
use tattoy_wezterm_term::color::{ColorAttribute, ColorPalette, SrgbaTuple};
use tattoy_wezterm_term::{Intensity, Underline};

/// Encode one emulator line as SGR-tagged bytes terminated by CRLF.
///
/// The record starts with a reset so rendition state from any previous
/// record cannot bleed in, then re-emits style runs (attributes first,
/// then foreground, then background, mirroring `terminal_style` in
/// `session.rs`) with each run change resetting before applying. Trailing
/// blank cells in the default style are dropped (wezterm lines are
/// full-width padded); control characters never survive into the text,
/// since a stray ESC would corrupt the replay stream.
pub fn encode_line(line: &mut Line, palette: &ColorPalette) -> Vec<u8> {
    // `cells_mut` coerces clustered (RLE) storage to a cell vec first;
    // the immutable accessor panics on clustered lines, which is how
    // rows come back from `lines_in_phys_range`.
    let cells = line.cells_mut();
    // Last significant cell: anything but a blank in the default style.
    // Style runs are compared by their encoded params, so "default" is
    // simply the empty param list. Scratch buffers are reused across
    // cells: encoding allocates nothing per cell, so scroll spam costs
    // O(bytes) instead of O(cells × allocs).
    let mut scratch = Vec::with_capacity(32);
    let mut end = 0;
    for (index, cell) in cells.iter().enumerate() {
        let text_blank = cell.str().trim().is_empty();
        scratch.clear();
        push_sgr_params(cell.attrs(), palette, &mut scratch);
        if !text_blank || !scratch.is_empty() {
            end = index + 1;
        }
    }
    let mut out = Vec::with_capacity(end * 2 + 16);
    out.extend_from_slice(b"\x1b[0m");
    let mut current: Vec<u8> = Vec::new();
    let mut skip_cells = 0;
    for cell in cells.iter().take(end) {
        if skip_cells > 0 {
            skip_cells -= 1;
            continue;
        }
        skip_cells = cell.width().max(1).saturating_sub(1);
        scratch.clear();
        push_sgr_params(cell.attrs(), palette, &mut scratch);
        if scratch != current {
            out.push(b'\x1b');
            out.push(b'[');
            if current.is_empty() {
                // First styled run: the record reset above already cleared.
                out.extend_from_slice(&scratch);
            } else {
                // Reset before applying so dropped attributes (e.g. bold
                // present in the old run but absent in the new one) clear.
                out.extend_from_slice(b"0");
                if !scratch.is_empty() {
                    out.push(b';');
                    out.extend_from_slice(&scratch);
                }
            }
            out.push(b'm');
            current.clear();
            current.extend_from_slice(&scratch);
        }
        for ch in cell.str().chars().filter(|c| !c.is_control()) {
            let mut buf = [0; 4];
            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
        }
    }
    out.extend_from_slice(b"\r\n");
    out
}

/// Append SGR parameters for one cell's attributes, mirroring the attr
/// coverage of `terminal_style`: intensity, italic, underline, reverse,
/// and resolved RGB colors. Anything unmapped degrades to unstyled text.
fn push_sgr_params(
    attrs: &tattoy_wezterm_term::CellAttributes,
    palette: &ColorPalette,
    params: &mut Vec<u8>,
) {
    let mut first = true;
    let mut sep = |params: &mut Vec<u8>| {
        if !first {
            params.push(b';');
        }
        first = false;
    };
    match attrs.intensity() {
        Intensity::Bold => {
            sep(params);
            params.push(b'1');
        }
        Intensity::Half => {
            sep(params);
            params.push(b'2');
        }
        _ => {}
    }
    if attrs.italic() {
        sep(params);
        params.push(b'3');
    }
    if attrs.underline() != Underline::None {
        sep(params);
        params.push(b'4');
    }
    if attrs.reverse() {
        sep(params);
        params.push(b'7');
    }
    if attrs.foreground() != ColorAttribute::Default {
        let SrgbaTuple(red, green, blue, _) = palette.resolve_fg(attrs.foreground());
        sep(params);
        params.extend_from_slice(b"38;2;");
        push_decimal(params, srgb_component(red));
        params.push(b';');
        push_decimal(params, srgb_component(green));
        params.push(b';');
        push_decimal(params, srgb_component(blue));
    }
    if attrs.background() != ColorAttribute::Default {
        let SrgbaTuple(red, green, blue, _) = palette.resolve_bg(attrs.background());
        sep(params);
        params.extend_from_slice(b"48;2;");
        push_decimal(params, srgb_component(red));
        params.push(b';');
        push_decimal(params, srgb_component(green));
        params.push(b';');
        push_decimal(params, srgb_component(blue));
    }
}

fn push_decimal(out: &mut Vec<u8>, value: u8) {
    if value >= 100 {
        out.push(b'0' + value / 100);
    }
    if value >= 10 {
        out.push(b'0' + (value / 10) % 10);
    }
    out.push(b'0' + value % 10);
}

fn srgb_component(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * 255.0).round() as u8
}

/// Lines per journal file before rotation. Decoupled from log-segment
/// rotation on purpose: the journal tracks scrolled lines, whose density
/// per log byte ranges from zero (deserts) to one per few bytes (spam).
const JOURNAL_LINES_PER_FILE: usize = 10_000;

/// Sealed journal files retained per session (plus the active file).
/// Bounds worst-case scrollback disk to tens of megabytes, the same
/// order as log retention.
const JOURNAL_RETAINED_FILES: usize = 20;

/// Size of one record header: log offset (u64 LE) + payload length
/// (u32 LE).
const RECORD_HEADER_LEN: usize = 12;

/// Appends between writer flushes. Reads never flush (the serve paths
/// hold only a shared reference), so this bounds how many trailing
/// records a read can miss. The miss is nearly always irrelevant to
/// serving: unflushed records sit above the raw window's start, where
/// the strict seam would exclude them anyway.
const JOURNAL_FLUSH_EVERY: usize = 128;

/// One journaled scrollback line: the SGR-encoded bytes plus the absolute
/// log offset of the ingest chunk that scrolled it.
pub struct JournalRecord {
    /// Absolute `bytes_logged` end offset of the chunk that scrolled this
    /// line. Monotonic within a file; used for the serve-time seam.
    pub log_offset: u64,
    /// Exact bytes to serve (reset-prefixed SGR text + CRLF).
    pub bytes: Vec<u8>,
}

/// Append-only per-session journal of scrolled lines.
///
/// Layout beside the log segments: `scrollback-{:06}.slog` (active,
/// unsealed) plus `scrollback-{:06}.slog.zst` (sealed, newest-first
/// readable). All I/O failures degrade to "no journal" (empty prefix)
/// rather than failing ingest or attach: scrollback history is best
/// effort, the raw log is the source of truth.
pub struct ScrollbackJournal {
    dir: PathBuf,
    active_index: u32,
    active_lines: usize,
    writer: Option<BufWriter<File>>,
    /// Appends since the last flush (see [`JOURNAL_FLUSH_EVERY`]).
    since_flush: usize,
    /// Set on the first I/O failure; the journal stays inert afterwards.
    broken: bool,
    warned: bool,
}

/// Open (or create) the journal beside `log_path` (in its parent dir).
/// Never fails: problems produce a disabled journal serving nothing.
pub fn open_journal_for_log(log_path: &Path) -> ScrollbackJournal {
    match log_path.parent() {
        Some(dir) if !dir.as_os_str().is_empty() => ScrollbackJournal::open(dir),
        _ => ScrollbackJournal::disabled(),
    }
}

impl ScrollbackJournal {
    /// Open (or create) the journal in `session_dir`. Never fails: I/O
    /// problems produce a disabled journal that serves nothing.
    pub fn open(session_dir: &Path) -> Self {
        let mut journal = Self {
            dir: session_dir.to_path_buf(),
            active_index: 0,
            active_lines: 0,
            writer: None,
            since_flush: 0,
            broken: false,
            warned: false,
        };
        if let Err(err) = journal.open_active() {
            journal.note_broken(&err);
        }
        journal
    }

    /// A journal that is inert from the start (no usable dir).
    pub fn disabled() -> Self {
        Self {
            dir: PathBuf::new(),
            active_index: 0,
            active_lines: 0,
            writer: None,
            since_flush: 0,
            broken: true,
            warned: true,
        }
    }

    /// Returns true if the journal is operational (not broken or disabled).
    pub fn is_enabled(&self) -> bool {
        !self.broken
    }

    /// Append one scrolled line. Soft-fails into disabled mode.
    pub fn append(&mut self, log_offset: u64, bytes: &[u8]) {
        if self.broken {
            return;
        }
        if let Err(err) = self.append_inner(log_offset, bytes) {
            self.note_broken(&err);
        }
    }

    /// Serve prefix bytes: journaled lines strictly older than
    /// `raw_start`, newest-first up to `max_bytes`, returned oldest-first
    /// for replay. Never fails; unreadable data yields a shorter prefix.
    ///
    /// Takes a shared reference because the serve paths hold no exclusive
    /// access: it reads only flushed bytes, so up to `JOURNAL_FLUSH_EVERY`
    /// trailing records may be missing (see the const for why that is
    /// nearly always above the seam anyway).
    pub fn read_prefix_older_than(&self, raw_start: u64, max_bytes: usize) -> Vec<u8> {
        if self.broken || max_bytes == 0 {
            return Vec::new();
        }
        // Collect newest-first, then reverse whole records (never bytes)
        // into oldest-first replay order.
        let mut collected: Vec<Vec<u8>> = Vec::new();
        let mut collected_len = 0;
        'files: for index in self.sealed_and_active_newest_first() {
            let records = match self.read_file_records(index) {
                Ok(records) => records,
                Err(err) => {
                    tracing::warn!(?err, index, dir = %self.dir.display(), "skipping unreadable scrollback file");
                    break 'files;
                }
            };
            for record in records.iter().rev() {
                if record.log_offset >= raw_start {
                    continue;
                }
                if collected_len + record.bytes.len() > max_bytes {
                    break 'files;
                }
                collected_len += record.bytes.len();
                collected.push(record.bytes.clone());
            }
        }
        collected.reverse();
        collected.concat()
    }

    /// Rebase offsets after a legacy log trim cut the head at `cut`
    /// (absolute): drop records below the cut, shift survivors. Segmented
    /// sessions never call this (absolute offsets, immutable segments).
    pub fn rebase(&mut self, cut: u64) {
        if self.broken {
            return;
        }
        if let Err(err) = self.rebase_inner(cut) {
            self.note_broken(&err);
        }
    }

    /// Bytes currently journaled (active + sealed), for observability.
    #[allow(dead_code)]
    pub fn journaled_bytes(&self) -> u64 {
        self.sealed_and_active_newest_first()
            .iter()
            .filter_map(|index| {
                let path = self.sealed_path(*index);
                let candidate = if path.exists() {
                    path
                } else {
                    self.active_path(*index)
                };
                std::fs::metadata(candidate).ok().map(|m| m.len())
            })
            .sum()
    }

    fn note_broken<E: std::fmt::Debug>(&mut self, err: &E) {
        if !self.warned {
            self.warned = true;
            tracing::warn!(?err, dir = %self.dir.display(), "scrollback journal disabled");
        }
        self.broken = true;
        self.writer = None;
    }

    fn journal_file_stem(index: u32) -> String {
        format!("scrollback-{index:06}.slog")
    }

    fn active_path(&self, index: u32) -> PathBuf {
        self.dir.join(Self::journal_file_stem(index))
    }

    fn sealed_path(&self, index: u32) -> PathBuf {
        let mut name = Self::journal_file_stem(index);
        name.push_str(".zst");
        self.dir.join(name)
    }

    fn parse_journal_index(file_name: &str) -> Option<(u32, bool)> {
        let (stem, sealed) = match file_name.strip_suffix(".zst") {
            Some(stem) => (stem, true),
            None => (file_name, false),
        };
        let digits = stem.strip_prefix("scrollback-")?.strip_suffix(".slog")?;
        digits.parse::<u32>().ok().map(|index| (index, sealed))
    }

    /// Highest active-file index present, sweeping crash leftovers:
    /// `.tmp.*` seal debris is deleted; a same-index active+sealed pair
    /// keeps the sealed copy (the seal won, only its cleanup was lost).
    fn open_active(&mut self) -> anyhow::Result<()> {
        let mut highest_sealed: Option<u32> = None;
        let mut highest_active: Option<u32> = None;
        let entries = std::fs::read_dir(&self.dir)?;
        for entry in entries {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("scrollback-") && name.contains(".tmp.") {
                let _ = std::fs::remove_file(entry.path());
                continue;
            }
            if let Some((index, sealed)) = Self::parse_journal_index(&name) {
                if sealed {
                    highest_sealed = Some(highest_sealed.map_or(index, |h| h.max(index)));
                } else {
                    highest_active = Some(highest_active.map_or(index, |h| h.max(index)));
                }
            }
        }
        if let (Some(active), Some(sealed)) = (highest_active, highest_sealed)
            && active == sealed
        {
            // Crashed between seal rename and active unlink.
            let _ = std::fs::remove_file(self.active_path(active));
            highest_active = None;
        }
        // Resume appending the active tail, or start a fresh index after
        // the sealed head (never reuse a sealed index).
        let resume = match (highest_active, highest_sealed) {
            (Some(active), Some(sealed)) if active > sealed => active,
            (_, Some(sealed)) => sealed + 1,
            (Some(active), None) => active,
            (None, None) => 0,
        };
        self.active_index = resume;
        self.active_lines = Self::count_records(&self.active_path(resume));
        self.writer = None;
        Ok(())
    }

    fn ensure_writer(&mut self) -> anyhow::Result<&mut BufWriter<File>> {
        if self.writer.is_none() {
            let file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.active_path(self.active_index))?;
            self.writer = Some(BufWriter::new(file));
        }
        Ok(self.writer.as_mut().expect("writer initialized above"))
    }

    fn count_records(path: &Path) -> usize {
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(_) => return 0,
        };
        let mut count = 0;
        let mut cursor = 0;
        while cursor + RECORD_HEADER_LEN <= bytes.len() {
            let len =
                u32::from_le_bytes(bytes[cursor + 8..cursor + 12].try_into().unwrap_or([0; 4]))
                    as usize;
            cursor += RECORD_HEADER_LEN;
            if len > bytes.len().saturating_sub(cursor) {
                break;
            }
            count += 1;
            cursor += len;
        }
        count
    }

    fn append_inner(&mut self, log_offset: u64, bytes: &[u8]) -> anyhow::Result<()> {
        let writer = self.ensure_writer()?;
        writer.write_all(&log_offset.to_le_bytes())?;
        writer.write_all(&(bytes.len() as u32).to_le_bytes())?;
        writer.write_all(bytes)?;
        self.active_lines += 1;
        self.since_flush += 1;
        if self.since_flush >= JOURNAL_FLUSH_EVERY
            && let Some(writer) = self.writer.as_mut()
        {
            writer.flush()?;
            self.since_flush = 0;
        }
        if self.active_lines >= JOURNAL_LINES_PER_FILE {
            self.rotate()?;
        }
        Ok(())
    }

    /// Flush buffered appends so reads see them. Reads serve only
    /// flushed bytes (the serve paths hold no exclusive access), so the
    /// ingest path calls this after every chunk: an empty buffer makes
    /// it a branch, a dirty one costs a single write.
    pub(crate) fn flush_buffer(&mut self) {
        if self.since_flush == 0 {
            return;
        }
        if let Some(writer) = self.writer.as_mut()
            && let Err(err) = writer.flush()
        {
            self.note_broken(&err);
            return;
        }
        self.since_flush = 0;
    }

    fn rotate(&mut self) -> anyhow::Result<()> {
        if let Some(writer) = self.writer.as_mut() {
            writer.flush()?;
        }
        self.writer = None;
        let raw_path = self.active_path(self.active_index);
        if raw_path.exists() {
            let sealed_path = self.sealed_path(self.active_index);
            crate::storage::compress_segment_file(&raw_path, &sealed_path)?;
            self.enforce_retention()?;
        }
        self.active_index += 1;
        self.active_lines = 0;
        self.since_flush = 0;
        Ok(())
    }

    fn enforce_retention(&mut self) -> anyhow::Result<()> {
        let mut sealed: Vec<u32> = Vec::new();
        for entry in std::fs::read_dir(&self.dir)? {
            let entry = entry?;
            if let Some((index, true)) =
                Self::parse_journal_index(&entry.file_name().to_string_lossy())
            {
                sealed.push(index);
            }
        }
        sealed.sort_unstable();
        while sealed.len() > JOURNAL_RETAINED_FILES {
            let oldest = sealed.remove(0);
            let _ = std::fs::remove_file(self.sealed_path(oldest));
        }
        Ok(())
    }

    /// Sealed-then-active indices, newest first. The active file always
    /// sorts as newest (it holds the tail).
    fn sealed_and_active_newest_first(&self) -> Vec<u32> {
        let mut indices: Vec<u32> = Vec::new();
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return indices;
        };
        for entry in entries.flatten() {
            if let Some((index, _sealed)) =
                Self::parse_journal_index(&entry.file_name().to_string_lossy())
                && !indices.contains(&index)
            {
                indices.push(index);
            }
        }
        if !indices.contains(&self.active_index) {
            indices.push(self.active_index);
        }
        indices.sort_unstable_by(|a, b| b.cmp(a));
        indices
    }

    fn read_file_records(&self, index: u32) -> anyhow::Result<Vec<JournalRecord>> {
        let sealed = self.sealed_path(index);
        let bytes = if sealed.exists() {
            let file = File::open(&sealed)?;
            let mut decoder = zstd::stream::Decoder::new(BufReader::new(file))?;
            let mut bytes = Vec::new();
            decoder.read_to_end(&mut bytes)?;
            bytes
        } else {
            let active = self.active_path(index);
            if !active.exists() {
                return Ok(Vec::new());
            }
            std::fs::read(active)?
        };
        Ok(parse_records(&bytes))
    }

    fn rebase_inner(&mut self, cut: u64) -> anyhow::Result<()> {
        if let Some(writer) = self.writer.as_mut() {
            let _ = writer.flush();
        }
        self.writer = None;
        // Collect oldest-first across every file, then rewrite compacted.
        let mut indices = self.sealed_and_active_newest_first();
        indices.reverse();
        let mut survivors: Vec<JournalRecord> = Vec::new();
        for index in &indices {
            let records = self.read_file_records(*index)?;
            for mut record in records {
                if record.log_offset < cut {
                    continue;
                }
                record.log_offset -= cut;
                survivors.push(record);
            }
        }
        for index in &indices {
            let _ = std::fs::remove_file(self.sealed_path(*index));
            let _ = std::fs::remove_file(self.active_path(*index));
        }
        self.active_index = 0;
        self.active_lines = 0;
        for record in survivors {
            self.append_inner(record.log_offset, &record.bytes)?;
        }
        if let Some(writer) = self.writer.as_mut() {
            writer.flush()?;
        }
        Ok(())
    }
}

/// Parse length-prefixed records, stopping at the first truncation or
/// corruption (a torn tail from a crash yields its intact prefix).
fn parse_records(bytes: &[u8]) -> Vec<JournalRecord> {
    let mut records = Vec::new();
    let mut cursor = 0;
    while cursor + RECORD_HEADER_LEN <= bytes.len() {
        let offset = u64::from_le_bytes(bytes[cursor..cursor + 8].try_into().unwrap_or([0; 8]));
        let len = u32::from_le_bytes(bytes[cursor + 8..cursor + 12].try_into().unwrap_or([0; 4]))
            as usize;
        cursor += RECORD_HEADER_LEN;
        if len > bytes.len().saturating_sub(cursor) {
            break;
        }
        records.push(JournalRecord {
            log_offset: offset,
            bytes: bytes[cursor..cursor + len].to_vec(),
        });
        cursor += len;
    }
    records
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use tattoy_wezterm_term::{Terminal, TerminalConfiguration, TerminalSize};

    #[derive(Debug)]
    struct TestConfig;

    impl TerminalConfiguration for TestConfig {
        fn color_palette(&self) -> ColorPalette {
            ColorPalette::default()
        }
    }

    fn test_terminal(cols: usize, rows: usize) -> Terminal {
        Terminal::new(
            TerminalSize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
                dpi: 0,
            },
            Arc::new(TestConfig),
            "TriageTest",
            "0.0.0",
            Box::new(std::io::sink()),
        )
    }

    fn first_line(term: &Terminal) -> Vec<u8> {
        let screen = term.screen();
        let mut lines = screen.lines_in_phys_range(0..1);
        encode_line(&mut lines[0], &ColorPalette::default())
    }

    #[test]
    fn plain_line_encodes_text_with_reset_and_crlf() {
        let mut term = test_terminal(80, 24);
        term.advance_bytes(b"hello");
        assert_eq!(first_line(&term), b"\x1b[0mhello\r\n");
    }

    #[test]
    fn trailing_blanks_are_dropped() {
        let mut term = test_terminal(80, 24);
        term.advance_bytes(b"hi   ");
        assert_eq!(first_line(&term), b"\x1b[0mhi\r\n");
    }

    #[test]
    fn rgb_colors_emit_truecolor_sgr() {
        let mut term = test_terminal(80, 24);
        term.advance_bytes(b"\x1b[38;2;255;193;7mgold\x1b[0m plain");
        assert_eq!(
            first_line(&term),
            b"\x1b[0m\x1b[38;2;255;193;7mgold\x1b[0m plain\r\n"
        );
    }

    #[test]
    fn attributes_map_to_sgr_params() {
        let mut term = test_terminal(80, 24);
        term.advance_bytes(b"\x1b[1mb\x1b[0m\x1b[2md\x1b[0m\x1b[3mi\x1b[0m\x1b[4mu\x1b[0m\x1b[7mv");
        assert_eq!(
            first_line(&term),
            b"\x1b[0m\x1b[1mb\x1b[0;2md\x1b[0;3mi\x1b[0;4mu\x1b[0;7mv\r\n"
        );
    }

    #[test]
    fn background_and_foreground_combine() {
        let mut term = test_terminal(80, 24);
        term.advance_bytes(b"\x1b[48;2;10;20;30m\x1b[38;2;1;2;3mX");
        assert_eq!(
            first_line(&term),
            b"\x1b[0m\x1b[38;2;1;2;3;48;2;10;20;30mX\r\n"
        );
    }

    #[test]
    fn palette_colors_resolve_to_rgb() {
        let mut term = test_terminal(80, 24);
        term.advance_bytes(b"\x1b[31mred");
        let encoded = first_line(&term);
        // Palette red resolves through the default palette to RGB.
        assert!(
            encoded.starts_with(b"\x1b[0m\x1b[38;2;"),
            "unexpected encoding: {encoded:?}"
        );
        assert!(encoded.ends_with(b"mred\r\n"));
    }

    #[test]
    fn wide_chars_survive_with_continuations_skipped() {
        let mut term = test_terminal(80, 24);
        term.advance_bytes("⏵ok".as_bytes());
        let mut expected = b"\x1b[0m".to_vec();
        expected.extend_from_slice("⏵ok".as_bytes());
        expected.extend_from_slice(b"\r\n");
        assert_eq!(first_line(&term), expected);
    }

    #[test]
    fn empty_line_encodes_reset_and_crlf_only() {
        let term = test_terminal(80, 24);
        assert_eq!(first_line(&term), b"\x1b[0m\r\n");
    }

    fn unique_journal_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "triage-scrollback-{}-{:?}-{tag}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create journal dir");
        dir
    }

    #[test]
    fn journal_round_trips_records_oldest_first() {
        let dir = unique_journal_dir("roundtrip");
        let mut journal = ScrollbackJournal::open(&dir);
        journal.append(100, b"first\r\n");
        journal.append(200, b"second\r\n");
        journal.append(300, b"third\r\n");
        journal.flush_buffer();
        // raw_start beyond every record: everything is older.
        assert_eq!(
            journal.read_prefix_older_than(1000, 1024),
            b"first\r\nsecond\r\nthird\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_seam_is_strictly_older_than_raw_start() {
        let dir = unique_journal_dir("seam");
        let mut journal = ScrollbackJournal::open(&dir);
        journal.append(100, b"old\r\n");
        journal.append(200, b"boundary\r\n");
        journal.append(300, b"new\r\n");
        journal.flush_buffer();
        // Records at or above raw_start belong to the raw window, not
        // the prefix: overlap would replay lines twice.
        assert_eq!(journal.read_prefix_older_than(200, 1024), b"old\r\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_prefix_respects_the_byte_budget_newest_first() {
        let dir = unique_journal_dir("budget");
        let mut journal = ScrollbackJournal::open(&dir);
        journal.append(100, b"aaaa\r\n");
        journal.append(200, b"bbbb\r\n");
        journal.append(300, b"cccc\r\n");
        journal.flush_buffer();
        // Six bytes each: budget fits the two newest, oldest-first.
        assert_eq!(
            journal.read_prefix_older_than(1000, 12),
            b"bbbb\r\ncccc\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_rebase_drops_the_cut_head_and_shifts() {
        let dir = unique_journal_dir("rebase");
        let mut journal = ScrollbackJournal::open(&dir);
        journal.append(100, b"cut\r\n");
        journal.append(200, b"keep\r\n");
        journal.rebase(150);
        assert_eq!(journal.read_prefix_older_than(1000, 1024), b"keep\r\n");
        // Survivor offsets shift by the cut: the seam still works.
        assert_eq!(journal.read_prefix_older_than(51, 1024), b"keep\r\n");
        assert!(journal.read_prefix_older_than(50, 1024).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_survives_reopen_and_torn_tails() {
        let dir = unique_journal_dir("reopen");
        {
            let mut journal = ScrollbackJournal::open(&dir);
            journal.append(100, b"a\r\n");
            journal.append(200, b"b\r\n");
        }
        {
            let mut journal = ScrollbackJournal::open(&dir);
            journal.append(300, b"c\r\n");
            journal.flush_buffer();
            assert_eq!(
                journal.read_prefix_older_than(1000, 1024),
                b"a\r\nb\r\nc\r\n"
            );
        }
        // A torn tail (crash mid-append) yields its intact prefix.
        {
            use std::io::Write;
            let mut file = std::fs::OpenOptions::new()
                .append(true)
                .open(dir.join("scrollback-000000.slog"))
                .expect("open active");
            file.write_all(&[1, 2, 3]).expect("tear tail");
        }
        {
            let journal = ScrollbackJournal::open(&dir);
            assert_eq!(
                journal.read_prefix_older_than(1000, 1024),
                b"a\r\nb\r\nc\r\n"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_rotation_and_sealed_read() {
        let dir = unique_journal_dir("rotation");
        let mut journal = ScrollbackJournal::open(&dir);
        journal.append(100, b"file0_rec1\r\n");
        journal.append(200, b"file0_rec2\r\n");
        journal.rotate().expect("rotate file 0");
        journal.append(300, b"file1_rec1\r\n");
        journal.append(400, b"file1_rec2\r\n");

        assert_eq!(
            journal.sealed_and_active_newest_first(),
            vec![1, 0],
            "active index 1 should precede sealed index 0 in newest-first order"
        );

        // Read prefix spanning sealed and active files in oldest-first chronological order
        assert_eq!(
            journal.read_prefix_older_than(1000, 1024),
            b"file0_rec1\r\nfile0_rec2\r\nfile1_rec1\r\nfile1_rec2\r\n"
        );

        // Budget caps should pull the newest records across the seam
        assert_eq!(
            journal.read_prefix_older_than(1000, 24),
            b"file1_rec1\r\nfile1_rec2\r\n"
        );

        // Rebase should compact across sealed and active files
        journal.rebase(250);
        assert_eq!(
            journal.read_prefix_older_than(1000, 1024),
            b"file1_rec1\r\nfile1_rec2\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_lazy_file_creation() {
        let dir = unique_journal_dir("lazy");
        let mut journal = ScrollbackJournal::open(&dir);
        assert!(journal.is_enabled());

        // Opening should not eagerly create a 0-byte active file
        let active_path = journal.active_path(0);
        assert!(
            !active_path.exists(),
            "active file should not exist before first append"
        );

        // First append creates the file
        journal.append(100, b"lazy_content\r\n");
        assert!(
            active_path.exists(),
            "active file must exist after first append"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_sweeps_only_scrollback_tmp_files() {
        let dir = unique_journal_dir("tmp_sweep");
        let scrollback_tmp = dir.join("scrollback-000000.slog.zst.tmp.12345");
        let segment_tmp = dir.join("segment-000001.tlog.zst.tmp.12345");
        std::fs::write(&scrollback_tmp, b"debris").expect("write scrollback tmp");
        std::fs::write(&segment_tmp, b"in-flight segment").expect("write segment tmp");

        let _journal = ScrollbackJournal::open(&dir);
        assert!(
            !scrollback_tmp.exists(),
            "scrollback tmp file should be swept"
        );
        assert!(
            segment_tmp.exists(),
            "segment tmp file must be preserved for storage worker"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
