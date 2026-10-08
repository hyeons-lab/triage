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
//! bytes stamped with their log offset, so history serving can carry the
//! scrolled lines at or older than the raw window seam in a separate
//! prefix field ahead of the raw tail. Full replays prepend the prefix,
//! which scrolls in as scrollback while the raw tail re-anchors and
//! repaints the viewport; delta merges ignore the prefix and run byte
//! accounting on the raw tail alone.
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
pub(crate) const JOURNAL_LINES_PER_FILE: usize = 10_000;

/// Sealed journal files retained per session (plus the active file).
/// Bounds worst-case scrollback disk to tens of megabytes, the same
/// order as log retention.
const JOURNAL_RETAINED_FILES: usize = 20;

/// Collect-stage-commit attempts per rebase. A benign seal completion
/// landing inside an attempt window trips that attempt exactly like a
/// peer write; attempts are bounded (not exactly two) so a worker
/// backlog of several seals absorbs across windows. No new rotations
/// can queue during the synchronous rebase, so any backlog strictly
/// drains, while a live peer trips every window and still fails closed.
const REBASE_ATTEMPTS: usize = 4;

/// Size of one record header: log offset (u64 LE) + payload length
/// (u32 LE).
const RECORD_HEADER_LEN: usize = 12;

/// File magic (`TSJ1`) + format version (u16 LE) written at the head of
/// every journal file at creation. Files predating the header (no magic)
/// parse as version 1; a version newer than
/// [`JOURNAL_FORMAT_VERSION`] fails closed (serves nothing, truncates
/// nothing) so a newer writer's files survive a downgraded reader.
const JOURNAL_MAGIC: &[u8; 4] = b"TSJ1";
const JOURNAL_FORMAT_VERSION: u16 = 1;
const JOURNAL_HEADER_LEN: usize = 6;

/// Appends between writer flushes. Reads never flush (the serve paths
/// hold only a shared reference), so this bounds how many trailing
/// records a read can miss. The miss is nearly always irrelevant to
/// serving: unflushed records sit above the raw window's start, where
/// the seam would exclude them anyway.
const JOURNAL_FLUSH_EVERY: usize = 128;

/// Head bytes decoded/read while peeking a file's first record (grown
/// geometrically to [`PEEK_HEAD_MAX`] for absurdly long first lines).
const PEEK_HEAD_BYTES: usize = 8192;
const PEEK_HEAD_MAX: usize = 1 << 20;

/// Outcome of peeking a journal file's first record.
enum Peek {
    /// No records (empty or header-only file).
    Empty,
    /// Smallest record offset; records are monotonic within a file.
    Min(u64),
    /// Torn, corrupt, or undecodable head.
    Unreadable,
    /// Head budget exhausted without a complete first record (a valid
    /// record larger than the peek window): decode fully instead.
    Unknown,
    /// Newer-format data (downgrade skew): skip quietly, since it is
    /// version skew rather than corruption.
    Future,
}

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
    /// Scratch for assembling one record per `write_all` (see
    /// [`Self::append_inner`]).
    record_scratch: Vec<u8>,
    /// Raw/sealed pairs awaiting a seal after rotations (drained by
    /// [`Self::drain_pending_seals`], synchronously or via the worker).
    /// A list because one chunk can rotate more than once.
    pending_seals: Vec<(PathBuf, PathBuf)>,
    /// Set on the first I/O failure; the journal stays inert afterwards.
    broken: bool,
    warned: bool,
    /// Attempts consumed by the last rebase: lets racer tests assert the
    /// trip count instead of trusting seal execution alone.
    #[cfg(test)]
    attempts_used: usize,
    /// Test-only hook fired synchronously after staging, before the
    /// layout re-check: lets tests land a seal deterministically
    /// inside the window instead of racing a thread against it.
    /// `Send` so the journal stays thread-portable in test builds.
    #[cfg(test)]
    test_on_staged: Option<Box<dyn Fn() + Send>>,
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
            record_scratch: Vec::new(),
            pending_seals: Vec::new(),
            broken: false,
            warned: false,
            #[cfg(test)]
            attempts_used: 0,
            #[cfg(test)]
            test_on_staged: None,
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
            record_scratch: Vec::new(),
            pending_seals: Vec::new(),
            broken: true,
            warned: true,
            #[cfg(test)]
            attempts_used: 0,
            #[cfg(test)]
            test_on_staged: None,
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

    /// Serve prefix bytes: journaled lines at or older than `raw_start`,
    /// newest-first up to `max_bytes`, returned oldest-first for replay.
    /// Never fails; unreadable data yields a shorter prefix (with a warn,
    /// so "no scrollback" stays attributable).
    ///
    /// The seam is inclusive: a record stamped exactly `raw_start` covers
    /// chunk bytes entirely below the raw window, so it is in neither the
    /// raw tail (which starts there), nor (under a strict seam) the
    /// prefix. Including it cannot double-serve.
    ///
    /// Takes a shared reference because the serve paths hold no exclusive
    /// access: it reads only flushed bytes, so up to `JOURNAL_FLUSH_EVERY`
    /// trailing records may be missing (see the const for why that is
    /// nearly always above the seam anyway).
    /// Read prefix older than `raw_start` (alias for `read_prefix_at_or_older_than`).
    #[inline]
    pub fn read_prefix_older_than(&self, raw_start: u64, max_bytes: usize) -> Vec<u8> {
        self.read_prefix_at_or_older_than(raw_start, max_bytes)
    }

    pub fn read_prefix_at_or_older_than(&self, raw_start: u64, max_bytes: usize) -> Vec<u8> {
        if self.broken || max_bytes == 0 {
            return Vec::new();
        }
        // Collect newest-first, then reverse whole records (never bytes)
        // into oldest-first replay order.
        let mut collected: Vec<Vec<u8>> = Vec::new();
        let mut collected_len = 0;
        'files: for index in self.sealed_and_active_newest_first() {
            // Skip files entirely above the seam from their first record
            // alone: a full zstd decode per file per attach is what makes
            // empty prefixes expensive at retention scale.
            match self.peek_min_offset(index) {
                Peek::Empty => continue,
                Peek::Unreadable => {
                    tracing::warn!(index, dir = %self.dir.display(),
                        "skipping unreadable scrollback journal file");
                    continue;
                }
                // Sound when records are offset-ordered; a handover
                // predecessor's late flushes can append older offsets after
                // newer ones, in which case a head above the seam
                // transiently skips servable tail records until the seam
                // advances past the head (accepted: rare, self-healing;
                // the rebase skip keys the other direction and is
                // unaffected).
                Peek::Min(min) if min > raw_start => continue,
                Peek::Future => {
                    tracing::debug!(index, dir = %self.dir.display(),
                        "skipping newer-format scrollback journal file");
                    continue;
                }
                // Min within the seam and Unknown (oversized-but-valid
                // first record) both fall through to the full decode.
                Peek::Min(_) | Peek::Unknown => {}
            }
            let records = match self.read_file_records(index) {
                Ok(records) => records,
                Err(err) => {
                    tracing::warn!(index, dir = %self.dir.display(), ?err,
                        "skipping unreadable scrollback journal file");
                    break 'files;
                }
            };
            for record in records.iter().rev() {
                if record.log_offset > raw_start {
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

    /// Whether either copy (sealed twin preferred) at `index` is
    /// newer-format data, reading only the 6-byte head so skipped files
    /// stay undecoded. Missing or unreadable files are not future.
    fn journal_file_is_future(&self, index: u32) -> bool {
        let sealed = self.sealed_path(index);
        if sealed.exists() {
            let Ok(file) = File::open(&sealed) else {
                return false;
            };
            let Ok(mut decoder) = zstd::stream::Decoder::new(BufReader::new(file)) else {
                return false;
            };
            let mut head = [0u8; JOURNAL_HEADER_LEN];
            return decoder.read_exact(&mut head).is_ok() && file_header_len(&head).is_none();
        }
        let mut head = [0u8; JOURNAL_HEADER_LEN];
        File::open(self.active_path(index))
            .and_then(|mut f| {
                f.read_exact(&mut head)
                    .map(|_| file_header_len(&head).is_none())
            })
            .unwrap_or(false)
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
    /// stale own-stem seal tmps are deleted (live peers' are kept); a
    /// same-index active+sealed pair keeps the sealed copy (the seal won,
    /// only its cleanup was lost). Rotated-but-unsealed raws (a crash
    /// between rotation and the background seal) are sealed
    /// best-effort; the raw fallback serves them either way.
    fn open_active(&mut self) -> anyhow::Result<()> {
        let mut highest_sealed: Option<u32> = None;
        let mut highest_active: Option<u32> = None;
        let mut seen: Vec<u32> = Vec::new();
        let entries = std::fs::read_dir(&self.dir)?;
        for entry in entries {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if Self::is_stale_own_tmp(&name) {
                let _ = std::fs::remove_file(entry.path());
                continue;
            }
            if let Some((index, sealed)) = Self::parse_journal_index(&name) {
                if sealed {
                    highest_sealed = Some(highest_sealed.map_or(index, |h| h.max(index)));
                } else {
                    highest_active = Some(highest_active.map_or(index, |h| h.max(index)));
                }
                if !seen.contains(&index) {
                    seen.push(index);
                }
            }
        }
        if let (Some(active), Some(sealed)) = (highest_active, highest_sealed)
            && active == sealed
        {
            // Crashed between seal rename and active unlink: the twin
            // holds the same bytes, so the raw copy is debris. Swept for
            // every index below, not just the highest: once the active
            // tail advances past a crashed pair, the highest-only check
            // would leave its raw twin behind forever.
            let _ = std::fs::remove_file(self.active_path(active));
            // Clearing the head also disables the orphan seal sweep below
            // (it keys off highest_active): twin-less raws stay unsealed
            // until the next open. Accepted: they still serve via the raw
            // fallback, so the seal is deferred, not lost.
            highest_active = None;
        }
        // Both sweeps below iterate the collected listing, not 0..=top:
        // rebase never reuses an index, so the top grows without bound
        // and a range sweep would stat every integer up to it on each
        // open.
        for index in &seen {
            if Some(*index) == highest_active {
                continue;
            }
            if self.sealed_path(*index).exists() && self.active_path(*index).exists() {
                let _ = std::fs::remove_file(self.active_path(*index));
            }
        }
        // Seal rotated raws the background seal never reached (crash in
        // the window). Best effort: failure warns and the raw fallback
        // keeps serving, so it must never latch the journal broken.
        if let Some(active) = highest_active {
            for index in seen.iter().filter(|i| **i < active).copied() {
                if !self.sealed_path(index).exists() && self.active_path(index).exists() {
                    let raw = self.active_path(index);
                    let sealed = self.sealed_path(index);
                    if let Err(err) = crate::storage::compress_segment_file(&raw, &sealed) {
                        tracing::warn!(?err, index, dir = %self.dir.display(),
                            "scrollback journal orphan seal failed; raw fallback serves");
                    }
                }
            }
        }
        // Resume appending the active tail, or start a fresh index after
        // the sealed head (never reuse a sealed index).
        let resume = match (highest_active, highest_sealed) {
            (Some(active), Some(sealed)) if active > sealed => active,
            (_, Some(sealed)) => sealed.checked_add(1).ok_or_else(|| {
                anyhow::anyhow!("scrollback journal index space exhausted; open refused")
            })?,
            (Some(active), None) => active,
            (None, None) => 0,
        };
        self.active_index = resume;
        let resume_path = self.active_path(resume);
        if is_future_journal_file(&resume_path) {
            // A newer daemon owns this file: opening an append writer
            // would splice v1 records after future data. Bail so open()
            // latches broken (serves nothing, appends nothing, file kept).
            anyhow::bail!("scrollback journal active file is a newer format; disabling");
        }
        self.active_lines = Self::truncate_to_valid_prefix(&resume_path);
        self.writer = None;
        Ok(())
    }

    fn ensure_writer(&mut self) -> anyhow::Result<&mut BufWriter<File>> {
        if self.writer.is_none() {
            let path = self.active_path(self.active_index);
            let fresh =
                !path.exists() || path.metadata().map(|m| m.len()).unwrap_or(0) == 0;
            let file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)?;
            let mut writer = BufWriter::new(file);
            if fresh {
                writer.write_all(&journal_header())?;
                writer.flush()?;
            }
            self.writer = Some(writer);
        }
        Ok(self.writer.as_mut().expect("writer initialized above"))
    }

    /// True only for this journal's own dead seal debris:
    /// `scrollback-*.tmp.<pid>` (covers seal tmps and rebase staging)
    /// whose owner pid is gone. Anything else (storage's tmps, live
    /// peers' tmps, unparseable names) is left alone.
    fn is_stale_own_tmp(file_name: &str) -> bool {
        if !file_name.starts_with("scrollback-") || !file_name.contains(".tmp.") {
            return false;
        }
        let Some(pid) = file_name
            .rsplit('.')
            .next()
            .and_then(|s| s.parse::<u32>().ok())
        else {
            return false;
        };
        !pid_is_alive(pid)
    }

    /// Names + sizes of the journal files, for detecting peer writes
    /// across a rebase collect (sorted for comparison). Transient seal
    /// and staging tmps are excluded: they are never collected, so their
    /// churn must not abort a rebase, and the rebase's own staging file
    /// must not mismatch the pre-stage snapshot.
    fn journal_layout_snapshot(dir: &Path) -> Vec<(String, u64)> {
        let mut layout = Vec::new();
        let Ok(entries) = std::fs::read_dir(dir) else {
            return layout;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with("scrollback-") || name.contains(".tmp.") {
                continue;
            }
            let len = entry.metadata().map(|m| m.len()).unwrap_or(u64::MAX);
            layout.push((name, len));
        }
        layout.sort();
        layout
    }

    /// Count intact records, truncating a torn tail at its record
    /// boundary so post-tear appends stay readable. Truncates only a
    /// stable tear: a handover predecessor may be appending to this same
    /// file, and the read snapshot can race its flush (torn read), so
    /// growth since the snapshot means a live appender, not crash debris
    /// (which persists for a later open to reap).
    fn truncate_to_valid_prefix(path: &Path) -> usize {
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(_) => return 0,
        };
        let (records, valid_len) = parse_records_with_len(&bytes);
        if valid_len < bytes.len() {
            Self::truncate_stable_tear(path, bytes.len(), valid_len);
        }
        records.len()
    }

    /// Chop a torn tail, but only when the file has not grown since the
    /// snapshot was read: growth means a live appender completed the
    /// apparent tear, while a stable size means crash debris. Split from
    /// the read so tests can stage the racing append deterministically.
    /// Returns whether it truncated.
    fn truncate_stable_tear(path: &Path, snapshot_len: usize, valid_len: usize) -> bool {
        let Ok(file) = std::fs::OpenOptions::new().write(true).open(path) else {
            return false;
        };
        let now = file.metadata().map(|m| m.len()).unwrap_or(u64::MAX);
        if now == snapshot_len as u64 {
            if let Err(err) = file.set_len(valid_len as u64) {
                tracing::warn!(path = %path.display(), ?err,
                    "scrollback journal torn tail survived truncate; later appends may not serve");
                return false;
            }
            true
        } else {
            false
        }
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
        // The seal runs outside ingest (see drain_pending_seals): zstd on
        // a full file costs milliseconds the PTY read loop should not pay.
        // Reads prefer the sealed twin but fall back to the raw file, so
        // the window between rotation and seal serves correctly.
        let raw_path = self.active_path(self.active_index);
        let sealed_path = self.sealed_path(self.active_index);
        self.pending_seals.push((raw_path, sealed_path));
        self.enforce_retention()?;
        self.active_index = self.active_index.checked_add(1).ok_or_else(|| {
            anyhow::anyhow!("scrollback journal index space exhausted; rotation refused")
        })?;
        self.active_lines = 0;
        self.since_flush = 0;
        Ok(())
    }

    /// Seal the files left by rotations since the last drain:
    /// background worker when one is offered, synchronously otherwise.
    /// Called from ingest after appends (beside the flush). The worker
    /// channel is unbounded, so send fails only when the worker is gone.
    pub(crate) fn drain_pending_seals(
        &mut self,
        tx: &Option<std::sync::mpsc::Sender<crate::storage::WorkerMessage>>,
    ) {
        for (raw_path, sealed_path) in std::mem::take(&mut self.pending_seals) {
            let sent = tx
                .as_ref()
                .map(|tx| {
                    tx.send(crate::storage::WorkerMessage::Job(
                        crate::storage::CompressionJob {
                            raw_path: raw_path.clone(),
                            compressed_path: sealed_path.clone(),
                            // A rebase may delete this raw between
                            // queueing and encoding: benign NotFound.
                            allow_missing_raw: true,
                        },
                    ))
                    .is_ok()
                })
                .unwrap_or(false);
            if sent {
                continue;
            }
            // No worker, or it is gone: seal inline. A failed seal
            // degrades exactly like the old inline rotation did.
            if let Err(err) = crate::storage::compress_segment_file(&raw_path, &sealed_path) {
                self.note_broken(&err);
                return;
            }
        }
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

    /// Sealed-then-active indices, newest first. The active file is
    /// newest overall (it holds the tail) and reads first; a sealed twin
    /// at the same index (crash debris, same bytes) reads exactly once.
    fn sealed_and_active_newest_first(&self) -> Vec<u32> {
        let mut indices: Vec<u32> = Vec::new();
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            tracing::warn!(dir = %self.dir.display(),
                "scrollback journal directory unreadable; serving no prefix");
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

    /// Cheapest useful fact about a file: its first record's offset.
    /// Decodes only the stream head (sealed) or reads the file head
    /// (raw), so files above the seam skip without a full decode.
    fn peek_min_offset(&self, index: u32) -> Peek {
        let sealed = self.sealed_path(index);
        if sealed.exists() {
            let file = match File::open(&sealed) {
                Ok(file) => file,
                Err(_) => return Peek::Unreadable,
            };
            let mut decoder = match zstd::stream::Decoder::new(BufReader::new(file)) {
                Ok(decoder) => decoder,
                Err(_) => return Peek::Unreadable,
            };
            Self::peek_stream_head(&mut decoder)
        } else {
            let path = self.active_path(index);
            let mut file = match File::open(&path) {
                Ok(file) => file,
                Err(_) => return Peek::Empty,
            };
            Self::peek_stream_head(&mut file)
        }
    }

    /// First record from a partially read head, whether a zstd stream
    /// or a raw file: one grow-and-parse loop so the head budget and
    /// first-record rule cannot drift between the two callers. A read
    /// error with no parsed record is unreadable either way (a raw
    /// read error with zero bytes filled used to read Empty; both
    /// skip the file in serve, and rebase falls back to decoding).
    fn peek_stream_head(reader: &mut impl std::io::Read) -> Peek {
        let mut head = vec![0u8; PEEK_HEAD_BYTES];
        let mut filled = 0;
        let mut errored = false;
        let mut exhausted = false;
        loop {
            if filled == head.len() {
                if head.len() >= PEEK_HEAD_MAX {
                    exhausted = true;
                    break;
                }
                head.resize(head.len() * 2, 0);
            }
            match reader.read(&mut head[filled..]) {
                Ok(0) => break,
                Ok(n) => {
                    filled += n;
                    if !parse_records(&head[..filled]).is_empty() {
                        break;
                    }
                }
                Err(_) => {
                    errored = true;
                    break;
                }
            }
        }
        if exhausted && parse_records(&head[..filled]).is_empty() {
            // The head window filled without one complete record: the
            // first record is valid but oversized, not corrupt. Serve
            // falls through to a full decode; rebase already decodes on
            // any non-Min peek.
            return Peek::Unknown;
        }
        Self::peek_parsed_head(&head[..filled], filled == 0 && !errored)
    }

    /// Classify a decoded head: first record wins, empty input is empty,
    /// anything else is unreadable (torn or corrupt first record poisons
    /// the whole file, since parsing stops at the first tear anyway).
    fn peek_parsed_head(head: &[u8], empty: bool) -> Peek {
        if let Some(first) = parse_records(head).first() {
            return Peek::Min(first.log_offset);
        }
        if empty {
            return Peek::Empty;
        }
        // A full head with our magic but a newer version is downgrade
        // skew, not corruption (short heads cannot tell and stay
        // Unreadable, as before).
        if file_header_len(head).is_none() {
            return Peek::Future;
        }
        Peek::Unreadable
    }

    fn rebase_inner(&mut self, cut: u64) -> anyhow::Result<()> {
        if let Some(writer) = self.writer.as_mut() {
            let _ = writer.flush();
        }
        self.writer = None;
        // A benign same-process seal landing inside an attempt window
        // trips the layout guard exactly like a peer write; attempt
        // again while the backlog drains, and fail closed only when
        // every window trips (a live peer, still writing).
        #[cfg(test)]
        {
            self.attempts_used = 0;
        }
        for _ in 0..REBASE_ATTEMPTS {
            #[cfg(test)]
            {
                self.attempts_used += 1;
            }
            if self.rebase_attempt(cut)? {
                return Ok(());
            }
        }
        anyhow::bail!("journal changed during rebase; peer handover suspected");
    }

    /// One collect-stage-commit attempt. Returns true when committed (or
    /// when there was nothing to rewrite); returns false with the staging
    /// dropped and every original untouched when the layout moved under
    /// the attempt, so the caller can retry. Hard errors propagate.
    fn rebase_attempt(&mut self, cut: u64) -> anyhow::Result<bool> {
        // Collect oldest-first across every file, then rewrite compacted.
        let mut indices = self.sealed_and_active_newest_first();
        indices.reverse();
        for index in &indices {
            if self.journal_file_is_future(*index) {
                // Newer-format data we cannot decode: collecting would
                // succeed vacuously and the removal loop would destroy
                // it. Bail before staging anything (broken latch, serving
                // falls back to the raw tail, files untouched).
                anyhow::bail!("scrollback journal holds newer-format data; rebase refused");
            }
        }
        // Peek first-offsets oldest-first: record offsets are monotonic
        // non-strict across files (each file fills before the next starts,
        // but a rotation landing mid-chunk stamps the same chunk-end offset
        // in both files, and even a handover predecessor's late flushes
        // carry older offsets than the successor's newer files), so a file
        // whose successor starts strictly below the cut holds only dropped
        // records and is deleted without decoding: at `next_min == cut`
        // the older file may still hold an `offset == cut` survivor (which
        // the collect path keeps). The newest file is always collected;
        // an empty or unreadable successor bounds nothing and falls back
        // to decoding. Peeked firsts are upper bounds on true minimums
        // (a handover tail can sit below its file's head), which keeps
        // the rule sound: it only ever skips decoding, never survivors.
        let firsts: Vec<Option<u64>> = indices
            .iter()
            .map(|index| match self.peek_min_offset(*index) {
                Peek::Min(min) => Some(min),
                _ => None,
            })
            .collect();
        let before = Self::journal_layout_snapshot(&self.dir);
        let mut survivors: Vec<JournalRecord> = Vec::new();
        // Proved-journaled flags for the early return below: the collect
        // is the only witness distinguishing an empty journal from one
        // whose records all fell below the cut.
        let mut decoded_any = false;
        let mut skipped_any = false;
        for (pos, index) in indices.iter().enumerate() {
            let fully_cut = pos + 1 < firsts.len()
                && matches!(firsts[pos + 1], Some(next_min) if next_min < cut);
            if fully_cut {
                // Contributes zero survivors; the removal loop below
                // deletes it undecoded.
                skipped_any = true;
                continue;
            }
            let records = self.read_file_records(*index)?;
            decoded_any |= !records.is_empty();
            for mut record in records {
                if record.log_offset < cut {
                    continue;
                }
                record.log_offset -= cut;
                survivors.push(record);
            }
        }
        if survivors.is_empty() && !decoded_any && !skipped_any {
            // Genuinely nothing journaled: no rewrite, no window of loss.
            return Ok(true);
        }
        if !self.pending_seals.is_empty() {
            // These raws were collected from disk above and are deleted
            // below: sealing them is wasted work, and a worker completion
            // landing past the layout snapshot trips the peer-write guard.
            self.pending_seals.clear();
        }
        // Stage the compacted journal BEFORE touching the originals; a
        // staging failure returns early with the journal untouched (the
        // caller latches broken, but the files on disk stay readable).
        // The staging name matches the open sweep (own stem, .tmp., pid).
        let staging = self
            .dir
            .join(format!("scrollback-rebase.tmp.{}", std::process::id()));
        // The originals are untouched on this path, so a stage-write
        // failure removes the partial file: every failure exit before
        // the delete loop leaves no staging behind. Past the deletes
        // the staging file is the sole surviving copy, so the rename
        // keeps it on failure (the open sweep reaps it at restart).
        let staged_ok = (|| -> anyhow::Result<()> {
            let file = std::fs::OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .open(&staging)?;
            let mut staged = BufWriter::new(file);
            staged.write_all(&journal_header())?;
            for record in &survivors {
                staged.write_all(&record.log_offset.to_le_bytes())?;
                staged.write_all(&(record.bytes.len() as u32).to_le_bytes())?;
                staged.write_all(&record.bytes)?;
            }
            staged.flush()?;
            staged.get_ref().sync_all()?;
            Ok(())
        })();
        if staged_ok.is_err() {
            let _ = std::fs::remove_file(&staging);
        }
        staged_ok?;
        // Deterministic fault seam for the racer tests (compiled out of
        // production): a seal landed here trips exactly like a worker
        // completion inside the window, minus the thread choreography.
        #[cfg(test)]
        if let Some(hook) = &self.test_on_staged {
            hook();
        }
        if Self::journal_layout_snapshot(&self.dir) != before {
            // The layout moved under the attempt: a handover peer wrote
            // during the collect or the (slow) staging write, or a
            // benign same-process seal completed inside the window.
            // Either way replacing the files now is unsafe (peer data
            // clobbered, coordinate spaces mixed), so drop the staging
            // and report false: the caller retries while attempts remain
            // (see REBASE_ATTEMPTS) and fails closed only when every
            // window trips (a live peer, still writing) into disabled
            // mode (serving falls back to the full raw tail). Checked
            // after staging, since
            // checking before it left the whole staging window uncovered.
            let _ = std::fs::remove_file(&staging);
            return Ok(false);
        }
        // Never reuse an index across a rebase: a seal job sent before
        // the rebase but executed after it would otherwise encode the
        // recycled file (the identity re-check compares the new file
        // against itself and passes) and then unlink the live active
        // file out from under the writer. A fresh index turns that
        // stale job into a harmless NotFound on a deleted path.
        let fresh = match indices.iter().max() {
            Some(&u32::MAX) => {
                let _ = std::fs::remove_file(&staging);
                anyhow::bail!("scrollback journal index space exhausted; rebase refused")
            }
            Some(&max) => max + 1,
            None => 0,
        };
        if self.active_path(fresh).exists() || self.sealed_path(fresh).exists() {
            // A peer advanced past our collected max between the listing
            // and now; bail with every original untouched.
            let _ = std::fs::remove_file(&staging);
            anyhow::bail!("scrollback journal grew during rebase; peer handover suspected");
        }
        for index in &indices {
            let _ = std::fs::remove_file(self.sealed_path(*index));
            let _ = std::fs::remove_file(self.active_path(*index));
        }
        std::fs::rename(&staging, self.active_path(fresh))?;
        // Defense in depth: a worker seal that passed its identity
        // re-check before the deletes above may still land after them,
        // resurrecting a stale sealed twin at a collected index (reads
        // prefer sealed). Every pre-rebase file was deleted, so any
        // sealed twin at those indices now is either that race or a
        // failed delete: remove it. Residual, review-only: a seal
        // landing after this sweep is indistinguishable from a live
        // file (no sleep on that path; microsecond window, untestable
        // from outside a single call).
        self.remove_sealed_twins(&indices);
        self.writer = None;
        self.active_index = fresh;
        self.active_lines = survivors.len();
        self.since_flush = 0;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.active_path(fresh))?;
        self.writer = Some(BufWriter::new(file));
        Ok(true)
    }

    /// Delete sealed twins at the given indices (post-rebase sweep for
    /// seals that landed between the deletes and now). Split out so the
    /// mechanism is unit-testable; the timing (runs right after the
    /// rename) is structural and stays review-only.
    fn remove_sealed_twins(&self, indices: &[u32]) {
        for index in indices {
            let _ = std::fs::remove_file(self.sealed_path(*index));
        }
    }
        }
    }
}

/// Parse length-prefixed records, stopping at the first truncation or
/// corruption (a torn tail from a crash yields its intact prefix).
fn parse_records(bytes: &[u8]) -> Vec<JournalRecord> {
    parse_records_with_len(bytes).0
}

/// Parse records plus the consumed length (always at a record boundary,
/// so reopen can truncate a torn tail exactly).
fn parse_records_with_len(bytes: &[u8]) -> (Vec<JournalRecord>, usize) {
    let mut records = Vec::new();
    let mut cursor = match file_header_len(bytes) {
        Some(len) => len,
        // Future format: serve nothing but report the whole file valid
        // so reopen never truncates a newer writer's data.
        None => return (records, bytes.len()),
    };
    while cursor + RECORD_HEADER_LEN <= bytes.len() {
        let offset = u64::from_le_bytes(
            *bytes[cursor..cursor + 8]
                .first_chunk()
                .expect("8-byte slice"),
        );
        let len = u32::from_le_bytes(
            *bytes[cursor + 8..cursor + 12]
                .first_chunk()
                .expect("4-byte slice"),
        ) as usize;
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
    (records, cursor)
}

/// Length of the file header to skip: 6 past a known magic, 0 for
/// headerless legacy files, or `None` for a newer format (fail closed).
fn file_header_len(bytes: &[u8]) -> Option<usize> {
    if bytes.len() >= JOURNAL_HEADER_LEN && bytes[..4] == *JOURNAL_MAGIC {
        let version = u16::from_le_bytes(*bytes[4..6].first_chunk().expect("2-byte slice"));
        if version > JOURNAL_FORMAT_VERSION {
            return None;
        }
        return Some(JOURNAL_HEADER_LEN);
    }
    Some(0)
}

/// Whether a journal file was written by a newer daemon: magic present
/// but version above ours. Legacy files (no magic) are not future.
/// Used to fail closed instead of mutating data we cannot parse.
fn is_future_journal_file(path: &Path) -> bool {
    match std::fs::read(path) {
        Ok(bytes) => !bytes.is_empty() && file_header_len(&bytes).is_none(),
        Err(_) => false,
    }
}

/// Magic + version bytes written at the head of every created file.
fn journal_header() -> [u8; JOURNAL_HEADER_LEN] {
    let mut header = [0u8; JOURNAL_HEADER_LEN];
    header[..4].copy_from_slice(JOURNAL_MAGIC);
    header[4..].copy_from_slice(&JOURNAL_FORMAT_VERSION.to_le_bytes());
    header
}

/// Whether `pid` names a live process (sweep guard for a handover
/// peer's in-flight seal tmps). On unix, errors fail toward alive: an
/// unsweepable tmp is debris, while a swept live tmp fails its owner's
/// seal (fail-safe either way, but the warn is spurious). Elsewhere the
/// check is unavailable and tmps sweep as before.
#[cfg(unix)]
fn pid_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    // Signal 0 performs error checking without delivering; EPERM still
    // means a live process owned by someone else.
    let signaled = unsafe { libc::kill(pid as libc::pid_t, 0) == 0 };
    signaled || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn pid_is_alive(_pid: u32) -> bool {
    false
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
            journal.read_prefix_at_or_older_than(1000, 1024),
            b"first\r\nsecond\r\nthird\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_seam_includes_the_boundary_chunk() {
        let dir = unique_journal_dir("seam");
        let mut journal = ScrollbackJournal::open(&dir);
        journal.append(100, b"old\r\n");
        journal.append(200, b"boundary\r\n");
        journal.append(300, b"new\r\n");
        journal.flush_buffer();
        // A record stamped exactly raw_start covers chunk bytes entirely
        // below the raw window: neither in the tail (which starts there)
        // nor reproducible from it, so the prefix must serve it.
        assert_eq!(
            journal.read_prefix_at_or_older_than(200, 1024),
            b"old\r\nboundary\r\n"
        );
        assert_eq!(journal.read_prefix_at_or_older_than(199, 1024), b"old\r\n");
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
            journal.read_prefix_at_or_older_than(1000, 12),
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
        assert_eq!(
            journal.read_prefix_at_or_older_than(1000, 1024),
            b"keep\r\n"
        );
        // Survivor offsets shift by the cut: the seam still works.
        assert_eq!(journal.read_prefix_at_or_older_than(51, 1024), b"keep\r\n");
        assert_eq!(journal.read_prefix_at_or_older_than(50, 1024), b"keep\r\n");
        assert!(journal.read_prefix_at_or_older_than(49, 1024).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A rebase across files drops a wholly-cut sealed file and compacts
    /// the survivors: the sealed file below the cut is gone, the
    /// survivor shifts onto the new head, and the seam keeps working in
    /// the rebased space. With the successor starting exactly at the
    /// cut, the strict skip rule decodes file 0; it contributes zero
    /// survivors and the removal loop deletes it.
    #[test]
    fn journal_rebase_drops_wholly_cut_files_across_the_seam() {
        let dir = unique_journal_dir("rebase-multi");
        let mut sealed = journal_header().to_vec();
        sealed.extend_from_slice(&10u64.to_le_bytes());
        sealed.extend_from_slice(&5u32.to_le_bytes());
        sealed.extend_from_slice(b"old\r\n");
        let scratch = dir.join("seal-scratch");
        std::fs::write(&scratch, &sealed).expect("seed scratch");
        crate::storage::compress_segment_file(&scratch, &dir.join("scrollback-000000.slog.zst"))
            .expect("seal file 0");
        // The active file starts at the cut, so file 0 is provably
        // wholly cut (cross-file monotonicity); it decodes to zero
        // survivors and the removal loop deletes it.
        let mut active = journal_header().to_vec();
        active.extend_from_slice(&25u64.to_le_bytes());
        active.extend_from_slice(&5u32.to_le_bytes());
        active.extend_from_slice(b"mid\r\n");
        active.extend_from_slice(&30u64.to_le_bytes());
        active.extend_from_slice(&5u32.to_le_bytes());
        active.extend_from_slice(b"new\r\n");
        std::fs::write(dir.join("scrollback-000001.slog"), &active).expect("seed file 1");

        let mut journal = ScrollbackJournal::open(&dir);
        assert_eq!(journal.active_index, 1);
        journal.rebase(25);

        assert!(
            !dir.join("scrollback-000000.slog.zst").exists(),
            "wholly-cut sealed file must be deleted"
        );
        assert_eq!(journal.active_index, 2);
        assert_eq!(
            journal.read_prefix_at_or_older_than(1000, 1024),
            b"mid\r\nnew\r\n"
        );
        // Survivors shift by the cut (25 - 25, 30 - 25): the seam
        // keeps working in the rebased space.
        assert_eq!(
            journal.read_prefix_at_or_older_than(5, 1024),
            b"mid\r\nnew\r\n"
        );
        assert_eq!(journal.read_prefix_at_or_older_than(0, 1024), b"mid\r\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A rotation landing mid-chunk stamps the same chunk-end offset in
    /// two files: with the cut equal to that offset, both records are
    /// survivors (the collect path keeps `offset == cut`), so the older
    /// file must be decoded, not skipped.
    #[test]
    fn journal_rebase_keeps_straddling_survivors_at_the_cut() {
        let dir = unique_journal_dir("rebase-straddle");
        let mut older = journal_header().to_vec();
        older.extend_from_slice(&25u64.to_le_bytes());
        older.extend_from_slice(&11u32.to_le_bytes());
        older.extend_from_slice(b"straddle0\r\n");
        let scratch = dir.join("seal-scratch");
        std::fs::write(&scratch, &older).expect("seed scratch");
        crate::storage::compress_segment_file(&scratch, &dir.join("scrollback-000000.slog.zst"))
            .expect("seal file 0");
        let mut active = journal_header().to_vec();
        active.extend_from_slice(&25u64.to_le_bytes());
        active.extend_from_slice(&11u32.to_le_bytes());
        active.extend_from_slice(b"straddle1\r\n");
        active.extend_from_slice(&30u64.to_le_bytes());
        active.extend_from_slice(&5u32.to_le_bytes());
        active.extend_from_slice(b"new\r\n");
        std::fs::write(dir.join("scrollback-000001.slog"), &active).expect("seed file 1");

        let mut journal = ScrollbackJournal::open(&dir);
        journal.rebase(25);

        assert_eq!(
            journal.read_prefix_at_or_older_than(1000, 1024),
            b"straddle0\r\nstraddle1\r\nnew\r\n",
            "both straddling records survive at the cut"
        );
        assert_eq!(
            journal.read_prefix_at_or_older_than(0, 1024),
            b"straddle0\r\nstraddle1\r\n",
            "cut-equal survivors shift to 0"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A rebase refuses newer-format data instead of destroying it: the
    /// future file decodes to zero survivors, so without the pre-staging
    /// check the collect would succeed vacuously and the removal loop
    /// would delete data this daemon could never read.
    #[test]
    fn journal_rebase_refuses_future_version_files() {
        let dir = unique_journal_dir("rebase-future");
        let mut future = b"TSJ1".to_vec();
        future.extend_from_slice(&u16::MAX.to_le_bytes());
        future.extend_from_slice(&[7u8; 64]);
        std::fs::write(dir.join("scrollback-000000.slog"), &future).expect("seed future");
        let mut active = journal_header().to_vec();
        active.extend_from_slice(&30u64.to_le_bytes());
        active.extend_from_slice(&5u32.to_le_bytes());
        active.extend_from_slice(b"new\r\n");
        std::fs::write(dir.join("scrollback-000001.slog"), &active).expect("seed active");

        let mut journal = ScrollbackJournal::open(&dir);
        journal.rebase(25);

        // The orphan sweep may losslessly transcode the future raw to its
        // sealed twin at open; either way the bytes must survive intact.
        let raw = dir.join("scrollback-000000.slog");
        let sealed = dir.join("scrollback-000000.slog.zst");
        if raw.exists() {
            assert_eq!(
                std::fs::read(&raw).expect("reread"),
                future,
                "rebase must leave newer-format data byte-identical"
            );
        } else {
            let encoded = std::fs::read(&sealed).expect("sealed must exist");
            let decoded = zstd::stream::decode_all(encoded.as_slice()).expect("decode");
            assert_eq!(
                decoded, future,
                "rebase must leave newer-format data byte-identical"
            );
        }
        assert!(
            dir.join("scrollback-000001.slog").exists(),
            "rebase must not compact around refused data"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A rebase drops pending seals for the files it deletes: draining
    /// after a rebase must not seal deleted raws (which fails and latches
    /// the journal broken right after a successful rebase).
    #[test]
    fn journal_rebase_drops_pending_seals_for_deleted_files() {
        let dir = unique_journal_dir("rebase-seals");
        let mut journal = ScrollbackJournal::open(&dir);
        for i in 0..JOURNAL_LINES_PER_FILE {
            journal.append(i as u64, b"x\r\n");
        }
        // Rotation queued a seal for file 0; the next append starts file 1.
        journal.append(u64::MAX, b"survivor\r\n");
        journal.flush_buffer();
        journal.rebase(10_000);
        // Without the pre-staging clear, this drain seals a deleted raw,
        // fails, and latches the journal broken.
        journal.drain_pending_seals(&None);
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, 1024),
            b"survivor\r\n",
            "journal must keep serving after rebase + drain"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Rebase compacts onto a fresh max+1 index instead of recycling 0,
    /// so a seal job sent pre-rebase but executed after it meets deleted
    /// paths (harmless NotFound) instead of encoding and unlinking the
    /// live recycled file. Post-rebase appends land in the live file.
    #[test]
    fn journal_rebase_recycles_to_a_fresh_index() {
        let dir = unique_journal_dir("rebase-fresh");
        let mut sealed = journal_header().to_vec();
        sealed.extend_from_slice(&10u64.to_le_bytes());
        sealed.extend_from_slice(&5u32.to_le_bytes());
        sealed.extend_from_slice(b"old\r\n");
        let scratch = dir.join("seal-scratch");
        std::fs::write(&scratch, &sealed).expect("seed scratch");
        crate::storage::compress_segment_file(&scratch, &dir.join("scrollback-000000.slog.zst"))
            .expect("seal file 0");
        let mut active = journal_header().to_vec();
        active.extend_from_slice(&20u64.to_le_bytes());
        active.extend_from_slice(&6u32.to_le_bytes());
        active.extend_from_slice(b"keep\r\n");
        std::fs::write(dir.join("scrollback-000001.slog"), &active).expect("seed file 1");

        let mut journal = ScrollbackJournal::open(&dir);
        journal.rebase(15);
        assert!(!journal.broken, "rebase must succeed");
        assert_eq!(journal.active_index, 2, "rebase must use a fresh index");
        assert!(
            dir.join("scrollback-000002.slog").exists(),
            "survivors must land at the fresh index"
        );
        assert!(
            !dir.join("scrollback-000000.slog").exists()
                && !dir.join("scrollback-000000.slog.zst").exists()
                && !dir.join("scrollback-000001.slog").exists(),
            "collected indices must be deleted, never recycled"
        );
        // The stale seal job a worker may still hold for index 0 now
        // fails NotFound on the deleted path instead of unlinking live
        // data.
        let stale = crate::storage::compress_segment_file(
            &dir.join("scrollback-000000.slog"),
            &dir.join("scrollback-000000.slog.zst"),
        );
        let err = stale.expect_err("stale seal must fail on the deleted path");
        assert!(
            err.downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound),
            "stale seal must fail NotFound, got {err:?}"
        );
        journal.append(25, b"more\r\n");
        journal.flush_buffer();
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, 1024),
            b"keep\r\nmore\r\n",
            "post-rebase appends must land in the live file and serve"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A seal-shaped layout change (raw replaced by its same-index twin)
    /// landing inside the rebase window trips the first attempt and the
    /// retry commits: the journal keeps serving instead of latching
    /// broken over a benign same-process seal. The seal lands through
    /// the synchronous `test_on_staged` hook (same filesystem ops the
    /// worker performs), so the trip is deterministic, not choreographed
    /// off a thread race; without the retry the trip latches broken and
    /// the serve asserts fail.
    #[test]
    fn journal_rebase_retries_a_seal_shaped_layout_trip() {
        let dir = unique_journal_dir("rebase-retry");
        let mut journal = ScrollbackJournal::open(&dir);
        // A tiny rotated raw (the realistic worker seal shape) ahead of
        // a fat tail (a realistic wide collect): the hook lands the seal
        // synchronously, so no timing margin is needed.
        for i in 0..10u64 {
            journal.append(100 + i, format!("l{i:05}\r\n").as_bytes());
        }
        journal.rotate().expect("rotate raw");
        for i in 0..20_000u64 {
            journal.append(200 + i, format!("l{i:05}\r\n").as_bytes());
        }
        journal.flush_buffer();
        let raw = dir.join("scrollback-000000.slog");
        let twin = dir.join("scrollback-000000.slog.zst");
        let fired = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let hook_fired = fired.clone();
        journal.test_on_staged = Some(Box::new(move || {
            let n = hook_fired.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
            if n == 1 {
                // Exactly one seal completion: raw becomes its twin. A
                // zero or error result is a real failure (nothing else
                // runs concurrently in this test).
                let sealed = crate::storage::compress_segment_file(&raw, &twin)
                    .expect("hook seal must succeed");
                assert!(sealed > 0, "hook seal must seal, not drop");
            }
        }));
        journal.rebase(100);
        assert_eq!(
            fired.load(std::sync::atomic::Ordering::SeqCst),
            2,
            "hook must fire once per attempt"
        );
        assert!(!journal.broken, "benign seal trip must retry, not latch");
        assert_eq!(
            journal.attempts_used, 2,
            "the seal must trip the first window, then commit"
        );
        assert_eq!(
            journal
                .read_prefix_at_or_older_than(u64::MAX, usize::MAX)
                .len(),
            20_010 * 8,
            "all survivors must serve after the retried rebase"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A file the rebase cannot decode is dropped with a warning while
    /// healthy survivors keep serving (warn-and-continue, matching the
    /// serve path): one bad file must not disable the journal. The warn
    /// itself is review-only (no log capture in this suite); the test
    /// pins the continue (bailing latches broken and serves nothing).
    #[test]
    fn journal_rebase_continues_past_unreadable_files() {
        let dir = unique_journal_dir("rebase-unreadable");
        std::fs::write(dir.join("scrollback-000000.slog.zst"), b"not zstd at all")
            .expect("seed corrupt sealed");
        let mut active = journal_header().to_vec();
        active.extend_from_slice(&20u64.to_le_bytes());
        active.extend_from_slice(&6u32.to_le_bytes());
        active.extend_from_slice(b"keep\r\n");
        std::fs::write(dir.join("scrollback-000001.slog"), &active).expect("seed file 1");

        let mut journal = ScrollbackJournal::open(&dir);
        journal.rebase(15);
        assert!(!journal.broken, "one bad file must not disable the journal");
        assert!(
            !dir.join("scrollback-000000.slog.zst").exists(),
            "unreadable file must still be deleted"
        );
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, 1024),
            b"keep\r\n",
            "healthy survivors must keep serving"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Coverage for the skip-positive arm (`next_min < cut`): file 0 is
    /// dropped without decoding. Skip and decode agree by design here,
    /// so this walks the arm rather than pinning the skip (pinning would
    /// need log capture for the absence of a decode; the straddle test
    /// pins the `<` boundary itself).
    #[test]
    fn journal_rebase_walks_the_strict_skip_arm() {
        let dir = unique_journal_dir("rebase-skip");
        let mut sealed = journal_header().to_vec();
        sealed.extend_from_slice(&5u64.to_le_bytes());
        sealed.extend_from_slice(&5u32.to_le_bytes());
        sealed.extend_from_slice(b"old\r\n");
        let scratch = dir.join("seal-scratch");
        std::fs::write(&scratch, &sealed).expect("seed scratch");
        crate::storage::compress_segment_file(&scratch, &dir.join("scrollback-000000.slog.zst"))
            .expect("seal file 0");
        // Successor starts strictly below the cut: file 0 contributes
        // zero survivors and is deleted without decoding.
        let mut active = journal_header().to_vec();
        active.extend_from_slice(&10u64.to_le_bytes());
        active.extend_from_slice(&6u32.to_le_bytes());
        active.extend_from_slice(b"drop\r\n");
        active.extend_from_slice(&20u64.to_le_bytes());
        active.extend_from_slice(&6u32.to_le_bytes());
        active.extend_from_slice(b"keep\r\n");
        std::fs::write(dir.join("scrollback-000001.slog"), &active).expect("seed file 1");

        let mut journal = ScrollbackJournal::open(&dir);
        journal.rebase(15);
        assert!(!journal.broken, "rebase must succeed");
        assert!(
            !dir.join("scrollback-000000.slog.zst").exists(),
            "skipped file must be deleted"
        );
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, 1024),
            b"keep\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Two benign seal completions landing in consecutive attempt windows
    /// are both absorbed: attempts are bounded, not exactly two, and a
    /// worker backlog strictly drains across them (no new rotations queue
    /// during the synchronous rebase). The seals land through the
    /// synchronous `test_on_staged` hook (same filesystem ops the worker
    /// performs), so both trips are deterministic, not choreographed off
    /// a thread race; with exactly-two attempts the second trip latches
    /// broken and the serve asserts fail.
    #[test]
    fn journal_rebase_absorbs_a_seal_per_window() {
        let dir = unique_journal_dir("rebase-two-seals");
        let mut journal = ScrollbackJournal::open(&dir);
        // Two tiny rotated raws (the realistic worker seal shape) ahead
        // of a fat multi-file tail (a realistic wide collect): the hook
        // lands each seal synchronously, so no timing margin is needed.
        for i in 0..10u64 {
            journal.append(100 + i, format!("l{i:05}\r\n").as_bytes());
        }
        journal.rotate().expect("rotate raw0");
        for i in 0..10u64 {
            journal.append(200 + i, format!("l{i:05}\r\n").as_bytes());
        }
        journal.rotate().expect("rotate raw1");
        for i in 0..40_000u64 {
            journal.append(300 + i, format!("l{i:05}\r\n").as_bytes());
        }
        journal.flush_buffer();
        let raw0 = dir.join("scrollback-000000.slog");
        let raw1 = dir.join("scrollback-000001.slog");
        let twin0 = dir.join("scrollback-000000.slog.zst");
        let twin1 = dir.join("scrollback-000001.slog.zst");
        let fired = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let hook_fired = fired.clone();
        journal.test_on_staged = Some(Box::new(move || {
            let n = hook_fired.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
            // One seal completion per window: each raw becomes its twin.
            // A zero or error result is a real failure (nothing else
            // runs concurrently in this test).
            let (raw, twin) = match n {
                1 => (&raw0, &twin0),
                2 => (&raw1, &twin1),
                _ => return,
            };
            let sealed =
                crate::storage::compress_segment_file(raw, twin).expect("hook seal must succeed");
            assert!(sealed > 0, "hook seal must seal, not drop");
        }));
        journal.rebase(100);
        assert_eq!(
            fired.load(std::sync::atomic::Ordering::SeqCst),
            3,
            "hook must fire once per attempt"
        );
        assert!(!journal.broken, "two benign trips must absorb, not latch");
        assert_eq!(
            journal.attempts_used, 3,
            "both seals must trip their windows, then commit"
        );
        assert_eq!(
            journal
                .read_prefix_at_or_older_than(u64::MAX, usize::MAX)
                .len(),
            40_020 * 8,
            "all survivors must serve after the absorbed rebase"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An all-dropping rebase still rewrites: sealed files holding only
    /// below-cut records are deleted and serve goes empty, never retained
    /// with pre-cut offsets for later cuts to shift into garbage.
    #[test]
    fn journal_rebase_reaps_stale_sealed_files_on_empty_survivors() {
        let dir = unique_journal_dir("rebase-stale");
        let mut sealed = journal_header().to_vec();
        sealed.extend_from_slice(&10u64.to_le_bytes());
        sealed.extend_from_slice(&5u32.to_le_bytes());
        sealed.extend_from_slice(b"old\r\n");
        let scratch = dir.join("seal-scratch");
        std::fs::write(&scratch, &sealed).expect("seed scratch");
        crate::storage::compress_segment_file(&scratch, &dir.join("scrollback-000000.slog.zst"))
            .expect("seal file 0");
        // Header-only active file: active_lines == 0, the shape that used
        // to take the early return and retain file 0 with stale offsets.
        std::fs::write(dir.join("scrollback-000001.slog"), journal_header()).expect("seed file 1");

        let mut journal = ScrollbackJournal::open(&dir);
        journal.rebase(25);
        assert!(!journal.broken, "rebase must succeed");
        assert!(
            !dir.join("scrollback-000000.slog.zst").exists(),
            "stale sealed file must be deleted"
        );
        assert!(
            journal
                .read_prefix_at_or_older_than(u64::MAX, 1024)
                .is_empty(),
            "serve must be empty after an all-dropping rebase"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The post-rename sweep deletes sealed twins at exactly the listed
    /// indices (mechanism pin; the timing, right after the rename, is
    /// structural and stays review-only).
    #[test]
    fn journal_remove_sealed_twins_deletes_listed_twins() {
        let dir = unique_journal_dir("sweep-twins");
        let journal = ScrollbackJournal::open(&dir);
        std::fs::write(dir.join("scrollback-000000.slog.zst"), b"twin0").expect("seed");
        std::fs::write(dir.join("scrollback-000001.slog.zst"), b"twin1").expect("seed");
        journal.remove_sealed_twins(&[0]);
        assert!(!dir.join("scrollback-000000.slog.zst").exists());
        assert!(dir.join("scrollback-000001.slog.zst").exists());
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
                journal.read_prefix_at_or_older_than(1000, 1024),
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
                journal.read_prefix_at_or_older_than(1000, 1024),
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
            journal.read_prefix_at_or_older_than(1000, 1024),
            b"file0_rec1\r\nfile0_rec2\r\nfile1_rec1\r\nfile1_rec2\r\n"
        );

        // Budget caps should pull the newest records across the seam
        assert_eq!(
            journal.read_prefix_at_or_older_than(1000, 24),
            b"file1_rec1\r\nfile1_rec2\r\n"
        );

        // Rebase should compact across sealed and active files
        journal.rebase(250);
        assert_eq!(
            journal.read_prefix_at_or_older_than(1000, 1024),
            b"file1_rec1\r\nfile1_rec2\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
    /// The stable-tear guard skips truncation when the file grew since
    /// the snapshot: the apparent tear was a live appender mid-flush.
    /// Staged deterministically (append between the snapshot size and
    /// the guard call), since real interleaving cannot be scheduled.
    #[test]
    fn journal_truncate_skips_grown_tail() {
        use std::io::Write;

        let dir = unique_journal_dir("truncate-grown");
        let path = dir.join("scrollback-000000.slog");
        let mut seed = journal_header().to_vec();
        seed.extend_from_slice(&42u64.to_le_bytes());
        seed.extend_from_slice(&5u32.to_le_bytes());
        seed.extend_from_slice(b"o\r\n\r\n");
        seed.extend_from_slice(&43u64.to_le_bytes());
        seed.extend_from_slice(&[5, 0]);
        std::fs::write(&path, &seed).expect("seed torn tail");
        // The racing completion lands between the snapshot and the guard.
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("open appender");
        file.write_all(&[0, 0]).expect("complete len");
        file.write_all(b"m\r\n\r\n").expect("complete body");
        file.write_all(&44u64.to_le_bytes()).expect("append record");
        file.write_all(&5u32.to_le_bytes()).expect("append len");
        file.write_all(b"n\r\n\r\n").expect("append body");
        drop(file);

        let truncated = ScrollbackJournal::truncate_stable_tear(&path, seed.len(), seed.len() - 10);
        assert!(!truncated, "grown tail must not truncate");
        let bytes = std::fs::read(&path).expect("reread");
        assert!(bytes.len() > seed.len(), "racing bytes must survive");
        let records = parse_records(&bytes);
        assert_eq!(records.len(), 3, "all three records must parse");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The stable-tear guard reaps a genuinely stable tear (crash debris):
    /// same size at guard time as at snapshot time means no live writer.
    #[test]
    fn journal_truncate_reaps_stable_tear() {
        let dir = unique_journal_dir("truncate-stable");
        let path = dir.join("scrollback-000000.slog");
        let mut seed = journal_header().to_vec();
        seed.extend_from_slice(&42u64.to_le_bytes());
        seed.extend_from_slice(&5u32.to_le_bytes());
        seed.extend_from_slice(b"o\r\n\r\n");
        seed.extend_from_slice(&[1, 2, 3]);
        std::fs::write(&path, &seed).expect("seed torn tail");

        let valid = seed.len() - 3;
        let truncated = ScrollbackJournal::truncate_stable_tear(&path, seed.len(), valid);
        assert!(truncated, "stable tear must truncate");
        let bytes = std::fs::read(&path).expect("reread");
        assert_eq!(bytes.len(), valid);
        assert_eq!(parse_records(&bytes).len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// End to end under real concurrency: while a peer thread appends
    /// sequenced records through its own O_APPEND fd, repeated opens must
    /// leave the parsed offsets a contiguous 0..k. A torn tail is fine;
    /// a gap means committed bytes were cut.
    ///
    /// Coverage split (deliberate): the two staged tests above pin the
    /// guard decision both ways (mutant-killed: flipping the comparison
    /// fails them); this test guards the wiring end to end but cannot
    /// schedule the interleaving, so it passes under scheduling luck as
    /// well as under a correct guard and pins nothing alone.
    #[test]
    fn journal_truncate_keeps_live_appender_bytes() {
        use std::io::Write;
        use std::sync::atomic::{AtomicBool, Ordering};

        let dir = unique_journal_dir("truncate-race");
        let path = dir.join("scrollback-000000.slog");
        std::fs::write(&path, journal_header()).expect("seed header");
        let done = AtomicBool::new(false);
        std::thread::scope(|s| {
            s.spawn(|| {
                let mut file = std::fs::OpenOptions::new()
                    .append(true)
                    .open(&path)
                    .expect("open appender");
                for seq in 0..300u64 {
                    // One write per record, matching the daemon flush:
                    // multi-syscall records would tear between writes in
                    // ways production never does (and no re-stat can fix
                    // a writer descheduled mid-record; only locking could,
                    // which this best-effort journal does not take on).
                    let payload = format!("r{seq:05}\r\n");
                    let mut record = seq.to_le_bytes().to_vec();
                    record.extend_from_slice(&(payload.len() as u32).to_le_bytes());
                    record.extend_from_slice(payload.as_bytes());
                    file.write_all(&record).expect("write record");
                }
                done.store(true, Ordering::Release);
            });
            let mut spins = 0;
            while !done.load(Ordering::Acquire) && spins < 5000 {
                ScrollbackJournal::truncate_to_valid_prefix(&path);
                spins += 1;
            }
        });

        let bytes = std::fs::read(&path).expect("reread");
        let records = parse_records(&bytes);
        assert!(!records.is_empty(), "appender must have landed records");
        for (i, record) in records.iter().enumerate() {
            assert_eq!(
                record.log_offset, i as u64,
                "gap at {i}: truncate amputated live bytes"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Rotation seals the head and serves across the seam oldest-first;
    /// a binding budget keeps the newest tail, not stale sealed lines.
    #[test]
    fn journal_rotates_and_reads_across_the_sealed_seam() {
        let dir = unique_journal_dir("rotate");
        let mut journal = ScrollbackJournal::open(&dir);
        for i in 0..JOURNAL_LINES_PER_FILE + 1 {
            journal.append(i as u64, format!("line{i:05}\r\n").as_bytes());
        }
        journal.flush_buffer();
        journal.drain_pending_seals(&None);
        assert!(dir.join("scrollback-000000.slog.zst").exists());
        let text =
            String::from_utf8_lossy(&journal.read_prefix_at_or_older_than(u64::MAX, usize::MAX))
                .into_owned();
        assert!(text.contains("line00000") && text.contains("line10000"));
        assert_eq!(text.matches("\r\n").count(), JOURNAL_LINES_PER_FILE + 1);
        let (head, tail) = (text.find("line00000"), text.find("line10000"));
        assert!(
            matches!((head, tail), (Some(h), Some(t)) if h < t),
            "sealed head must replay before the active tail"
        );
        // Newest-first budget fill: 11-byte records, 20-byte budget.
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, 20),
            b"line10000\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Retention keeps the 20 newest sealed files and drops the rest.
    #[test]
    fn journal_retention_keeps_twenty_sealed() {
        let dir = unique_journal_dir("retention");
        for i in 0..JOURNAL_RETAINED_FILES + 1 {
            let raw = dir.join(format!("scrollback-{i:06}.slog"));
            std::fs::write(&raw, journal_header()).expect("seed raw");
            let sealed = dir.join(format!("scrollback-{i:06}.slog.zst"));
            crate::storage::compress_segment_file(&raw, &sealed).expect("seal");
        }
        let mut journal = ScrollbackJournal::open(&dir);
        journal.enforce_retention().expect("retention runs");
        assert!(!dir.join("scrollback-000000.slog.zst").exists());
        for i in 1..JOURNAL_RETAINED_FILES + 1 {
            assert!(
                dir.join(format!("scrollback-{i:06}.slog.zst")).exists(),
                "sealed file {i} must survive"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Open sweeps only dead own-stem tmps and keeps the sealed copy
    /// of a same-index crash pair.
    #[test]
    fn journal_open_recovers_debris_and_pairs() {
        let dir = unique_journal_dir("recover");
        // Storage's tmp: foreign stem, never touched.
        std::fs::write(dir.join("segment-000001.tlog.zst.tmp.0"), b"x").expect("seed");
        // Own dead tmp (pid 0 never lives): swept.
        std::fs::write(dir.join("scrollback-000009.slog.zst.tmp.0"), b"x").expect("seed");
        // Own live tmp (this process): kept.
        let live = format!("scrollback-000008.slog.zst.tmp.{}", std::process::id());
        std::fs::write(dir.join(&live), b"x").expect("seed");
        // Rebase staging debris: swept.
        std::fs::write(dir.join("scrollback-rebase.tmp.0"), b"x").expect("seed");
        // Same-index pair at the top: sealed wins, resume past it.
        let raw9 = dir.join("scrollback-000009.slog");
        std::fs::write(&raw9, journal_header()).expect("seed");
        let sealed9 = dir.join("scrollback-000009.slog.zst");
        crate::storage::compress_segment_file(&raw9, &sealed9).expect("seal pair");
        std::fs::write(&raw9, journal_header()).expect("replant raw twin");

        let journal = ScrollbackJournal::open(&dir);
        assert!(dir.join("segment-000001.tlog.zst.tmp.0").exists());
        assert!(!dir.join("scrollback-000009.slog.zst.tmp.0").exists());
        assert!(dir.join(&live).exists());
        assert!(!dir.join("scrollback-rebase.tmp.0").exists());
        assert!(!dir.join("scrollback-000009.slog").exists());
        assert!(dir.join("scrollback-000009.slog.zst").exists());
        assert_eq!(journal.active_index, 10);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A valid first record larger than the peek window is Unknown, not
    /// Unreadable: serve falls through to a full decode instead of
    /// skipping the file with a misleading warn.
    #[test]
    fn journal_serve_decodes_oversized_first_record() {
        let dir = unique_journal_dir("oversize");
        let mut journal = ScrollbackJournal::open(&dir);
        let mut payload = vec![b'x'; PEEK_HEAD_MAX + 1024];
        payload.extend_from_slice(b"\r\n");
        journal.append(100, &payload);
        journal.flush_buffer();
        drop(journal);

        let journal = ScrollbackJournal::open(&dir);
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, usize::MAX),
            payload,
            "oversized-but-valid first record must serve"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Open seals a rotated-but-unsealed raw (a crash between rotation
    /// and the background seal) and resumes past it.
    #[test]
    fn journal_open_seals_orphan_raws() {
        let dir = unique_journal_dir("orphan");
        let mut orphan = journal_header().to_vec();
        orphan.extend_from_slice(&42u64.to_le_bytes());
        orphan.extend_from_slice(&5u32.to_le_bytes());
        orphan.extend_from_slice(b"o\r\n\r\n");
        std::fs::write(dir.join("scrollback-000000.slog"), &orphan).expect("seed");
        std::fs::write(dir.join("scrollback-000001.slog"), journal_header()).expect("seed");

        let journal = ScrollbackJournal::open(&dir);
        assert!(dir.join("scrollback-000000.slog.zst").exists());
        assert_eq!(journal.active_index, 1);
        // The orphan's line serves from its sealed twin.
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, 1024),
            b"o\r\n\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Open sweeps raw twins below the live tail, not just the highest
    /// pair: once the tail advances past a crashed seal, a highest-only
    /// sweep would leave the raw twin behind forever.
    #[test]
    fn journal_open_sweeps_twin_debris_below_the_live_tail() {
        let dir = unique_journal_dir("twin-sweep");
        let mut orphan = journal_header().to_vec();
        orphan.extend_from_slice(&42u64.to_le_bytes());
        orphan.extend_from_slice(&5u32.to_le_bytes());
        orphan.extend_from_slice(b"o\r\n\r\n");
        std::fs::write(dir.join("scrollback-000000.slog"), &orphan).expect("seed raw");
        // Seal from a scratch copy so the raw twin survives beside it.
        let scratch = dir.join("seal-scratch");
        std::fs::write(&scratch, &orphan).expect("seed scratch");
        crate::storage::compress_segment_file(&scratch, &dir.join("scrollback-000000.slog.zst"))
            .expect("seal twin");
        // Live tail two indices up, with no twin of its own.
        std::fs::write(dir.join("scrollback-000002.slog"), journal_header()).expect("seed tail");

        let journal = ScrollbackJournal::open(&dir);
        assert!(
            !dir.join("scrollback-000000.slog").exists(),
            "raw twin below the tail must be swept"
        );
        assert!(dir.join("scrollback-000000.slog.zst").exists());
        assert!(dir.join("scrollback-000002.slog").exists());
        assert_eq!(journal.active_index, 2);
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, 1024),
            b"o\r\n\r\n",
            "the swept twin's lines still serve from the sealed copy"
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
    /// The rebase layout snapshot ignores transient tmps: seal debris
    /// and the rebase's own staging file are never collected, so their
    /// churn must not read as a peer write.
    #[test]
    fn journal_layout_snapshot_ignores_transient_tmps() {
        let dir = unique_journal_dir("layout-tmp");
        std::fs::write(dir.join("scrollback-000000.slog"), journal_header()).expect("seed");
        std::fs::write(dir.join("scrollback-000000.slog.zst.tmp.0"), b"debris").expect("seed");
        std::fs::write(dir.join("scrollback-rebase.tmp.0"), b"staging").expect("seed");
        std::fs::write(dir.join("segment-000001.tlog.zst.tmp.0"), b"storage").expect("seed");

        let layout = ScrollbackJournal::journal_layout_snapshot(&dir);
        assert_eq!(layout.len(), 1, "only the real journal file: {layout:?}");
        assert_eq!(layout[0].0, "scrollback-000000.slog");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A torn tail truncates at reopen, so records appended after the
    /// tear stay readable (without the truncate they land past
    /// unparseable bytes and never serve).
    #[test]
    fn journal_reopen_truncates_torn_tail_for_new_appends() {
        let dir = unique_journal_dir("tear-append");
        {
            let mut journal = ScrollbackJournal::open(&dir);
            journal.append(100, b"a\r\n");
            journal.flush_buffer();
        }
        {
            use std::io::Write;
            let mut file = std::fs::OpenOptions::new()
                .append(true)
                .open(dir.join("scrollback-000000.slog"))
                .expect("open active");
            file.write_all(&[9, 9, 9, 9]).expect("tear tail");
        }
        {
            let mut journal = ScrollbackJournal::open(&dir);
            journal.append(300, b"c\r\n");
            journal.flush_buffer();
            assert_eq!(
                journal.read_prefix_at_or_older_than(1000, 1024),
                b"a\r\nc\r\n"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Headerless (pre-magic) files keep serving as version 1.
    #[test]
    fn journal_reads_legacy_files_without_magic() {
        let dir = unique_journal_dir("legacy");
        let mut legacy = Vec::new();
        legacy.extend_from_slice(&100u64.to_le_bytes());
        legacy.extend_from_slice(&5u32.to_le_bytes());
        legacy.extend_from_slice(b"a\r\n\r\n");
        std::fs::write(dir.join("scrollback-000000.slog"), &legacy).expect("seed legacy");
        let journal = ScrollbackJournal::open(&dir);
        assert_eq!(
            journal.read_prefix_at_or_older_than(1000, 1024),
            b"a\r\n\r\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A newer format fails closed: serves nothing, truncates nothing.
    #[test]
    fn journal_future_version_fails_closed_without_truncating() {
        let dir = unique_journal_dir("future");
        let mut future = b"TSJ1".to_vec();
        future.extend_from_slice(&u16::MAX.to_le_bytes());
        future.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
        std::fs::write(dir.join("scrollback-000000.slog"), &future).expect("seed future");
        let mut journal = ScrollbackJournal::open(&dir);
        assert!(
            journal
                .read_prefix_at_or_older_than(u64::MAX, 1 << 20)
                .is_empty()
        );
        // Appends must not splice v1 records after future data: the open
        // latches broken, so even past the flush threshold the file stays
        // byte-identical for the newer daemon to reclaim on upgrade.
        for i in 0..200 {
            journal.append(i, b"x\r\n");
        }
        journal.flush_buffer();
        assert_eq!(
            std::fs::read(dir.join("scrollback-000000.slog")).expect("reread"),
            future,
            "a newer writer's file must survive a downgraded reader"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_sweeps_only_scrollback_tmp_files() {
        let dir = unique_journal_dir("tmp_sweep");
        let scrollback_tmp = dir.join("scrollback-000000.slog.zst.tmp.4194300");
        let segment_tmp = dir.join("segment-000001.tlog.zst.tmp.4194300");
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
    /// A newer-format sealed file peeks Future (downgrade skew), not
    /// Unreadable: serve skips it quietly at debug instead of warning
    /// per attach. Pins the classification (the log level itself is
    /// review-only: no log capture in this suite).
    #[test]
    fn journal_future_version_peeks_future_not_unreadable() {
        let dir = unique_journal_dir("future-peek");
        let mut future = b"TSJ1".to_vec();
        future.extend_from_slice(&u16::MAX.to_le_bytes());
        future.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
        let scratch = dir.join("seal-scratch");
        std::fs::write(&scratch, &future).expect("seed scratch");
        crate::storage::compress_segment_file(&scratch, &dir.join("scrollback-000000.slog.zst"))
            .expect("seal future file");
        let mut active = journal_header().to_vec();
        active.extend_from_slice(&20u64.to_le_bytes());
        active.extend_from_slice(&6u32.to_le_bytes());
        active.extend_from_slice(b"keep\r\n");
        std::fs::write(dir.join("scrollback-000001.slog"), &active).expect("seed file 1");

        let journal = ScrollbackJournal::open(&dir);
        assert!(
            matches!(journal.peek_min_offset(0), Peek::Future),
            "future file must peek Future"
        );
        assert_eq!(
            journal.read_prefix_at_or_older_than(u64::MAX, 1024),
            b"keep\r\n",
            "serve must skip the future file and serve the rest"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Rotation defers the seal: the worker takes it when offered, else
    /// the drain seals inline (old behavior, off the append path).
    #[test]
    fn journal_drain_seals_inline_without_a_worker() {
        let dir = unique_journal_dir("drain");
        let mut journal = ScrollbackJournal::open(&dir);
        for i in 0..JOURNAL_LINES_PER_FILE {
            journal.append(i as u64, b"x\r\n");
        }
        assert_eq!(journal.pending_seals.len(), 1);
        assert!(!dir.join("scrollback-000000.slog.zst").exists());
        journal.drain_pending_seals(&None);
        assert!(journal.pending_seals.is_empty());
        assert!(dir.join("scrollback-000000.slog.zst").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_drain_hands_the_seal_to_the_worker() {
        let dir = unique_journal_dir("drain-worker");
        let mut journal = ScrollbackJournal::open(&dir);
        for i in 0..JOURNAL_LINES_PER_FILE {
            journal.append(i as u64, b"x\r\n");
        }
        let (tx, rx) = std::sync::mpsc::channel();
        journal.drain_pending_seals(&Some(tx));
        assert!(journal.pending_seals.is_empty());
        let job = rx.try_recv().expect("seal job sent");
        let crate::storage::WorkerMessage::Job(job) = job else {
            panic!("expected a compression job");
        };
        assert!(job.raw_path.ends_with("scrollback-000000.slog"));
        assert!(job.compressed_path.ends_with("scrollback-000000.slog.zst"));
        // The worker owns the seal now: no inline file appears.
        assert!(!dir.join("scrollback-000000.slog.zst").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
