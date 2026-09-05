use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};

use anyhow::{Context, Result, ensure};

/// Segment file size limit: 8 MiB.
pub const DEFAULT_SEGMENT_SIZE_BYTES: u64 = 8 * 1024 * 1024;

/// Default zstd compression level (level 3 provides high speed and ~80% compression on text/logs).
pub const ZSTD_COMPRESSION_LEVEL: i32 = 3;

pub const SEGMENT_EXT: &str = "tlog";
pub const COMPRESSED_SEGMENT_EXT: &str = "tlog.zst";

/// Information about a discovered segment file on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SegmentFileInfo {
    pub index: u32,
    pub path: PathBuf,
    pub is_compressed: bool,
    pub file_size: u64,
}

/// Generates the uncompressed segment filename for a given 1-based index (e.g. `segment-000001.tlog`).
pub fn segment_file_name(index: u32) -> String {
    format!("segment-{index:06}.{SEGMENT_EXT}")
}

/// Generates the compressed segment filename for a given 1-based index (e.g. `segment-000001.tlog.zst`).
pub fn compressed_segment_file_name(index: u32) -> String {
    format!("segment-{index:06}.{COMPRESSED_SEGMENT_EXT}")
}

/// Parses a filename to extract the segment index and whether it is compressed.
pub fn parse_segment_index(file_name: &str) -> Option<(u32, bool)> {
    let prefix = "segment-";
    if !file_name.starts_with(prefix) {
        return None;
    }
    let remainder = &file_name[prefix.len()..];
    if let Some(num_str) = remainder.strip_suffix(&format!(".{COMPRESSED_SEGMENT_EXT}")) {
        num_str.parse::<u32>().ok().map(|idx| (idx, true))
    } else if let Some(num_str) = remainder.strip_suffix(&format!(".{SEGMENT_EXT}")) {
        num_str.parse::<u32>().ok().map(|idx| (idx, false))
    } else {
        None
    }
}

/// Lists all segment files in a session directory, sorted in ascending chronological order by index.
///
/// If both an uncompressed and a compressed file exist for the same segment index (e.g. compression
/// was in-flight or interrupted), the uncompressed `.tlog` takes precedence unless it is zero-sized.
pub fn list_session_segments(session_dir: &Path) -> Result<Vec<SegmentFileInfo>> {
    if !session_dir.exists() {
        return Ok(Vec::new());
    }

    let entries = fs::read_dir(session_dir)
        .with_context(|| format!("reading session directory {}", session_dir.display()))?;

    let mut segments_by_index: std::collections::BTreeMap<u32, SegmentFileInfo> =
        std::collections::BTreeMap::new();

    for entry in entries {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if !file_type.is_file() {
            continue;
        }

        let file_name = entry.file_name();
        let file_name_str = file_name.to_string_lossy();
        if let Some((index, is_compressed)) = parse_segment_index(&file_name_str) {
            let path = entry.path();
            let file_size = entry.metadata()?.len();

            let info = SegmentFileInfo {
                index,
                path,
                is_compressed,
                file_size,
            };

            match segments_by_index.get(&index) {
                Some(existing) => {
                    // Prefer uncompressed if valid, otherwise prefer compressed
                    if (!is_compressed && file_size > 0)
                        || (existing.file_size == 0 && file_size > 0)
                    {
                        segments_by_index.insert(index, info);
                    }
                }
                None => {
                    segments_by_index.insert(index, info);
                }
            }
        }
    }

    Ok(segments_by_index.into_values().collect())
}

/// Compresses a raw `.tlog` segment file to `.tlog.zst` using zstd.
///
/// Writes to a temporary file (`.tlog.zst.tmp`) first, then atomically renames to the final
/// compressed path, and finally unlinks the raw file.
pub fn compress_segment_file(raw_path: &Path, compressed_path: &Path) -> Result<u64> {
    ensure!(raw_path.exists(), "raw segment path does not exist");

    let tmp_path = compressed_path.with_extension("tmp");
    {
        let raw_file = File::open(raw_path)
            .with_context(|| format!("opening raw segment {}", raw_path.display()))?;
        let mut reader = BufReader::new(raw_file);

        let tmp_file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp_path)
            .with_context(|| format!("creating temp compressed segment {}", tmp_path.display()))?;
        let writer = BufWriter::new(tmp_file);

        zstd::stream::copy_encode(&mut reader, writer, ZSTD_COMPRESSION_LEVEL)
            .with_context(|| format!("compressing segment to {}", tmp_path.display()))?;
    }

    // Atomic rename
    fs::rename(&tmp_path, compressed_path).with_context(|| {
        format!(
            "renaming {} to {}",
            tmp_path.display(),
            compressed_path.display()
        )
    })?;

    let compressed_len = fs::metadata(compressed_path)?.len();

    // Remove original uncompressed file
    let _ = fs::remove_file(raw_path);

    Ok(compressed_len)
}

/// Reads the entire uncompressed content of a segment.
pub fn read_segment_uncompressed(info: &SegmentFileInfo) -> Result<Vec<u8>> {
    let file = File::open(&info.path)
        .with_context(|| format!("opening segment file {}", info.path.display()))?;

    if info.is_compressed {
        let mut decoder = zstd::stream::Decoder::new(BufReader::new(file))
            .with_context(|| format!("decoding zstd segment {}", info.path.display()))?;
        let mut buffer = Vec::new();
        decoder.read_to_end(&mut buffer)?;
        Ok(buffer)
    } else {
        let mut buffer = Vec::with_capacity(info.file_size as usize);
        let mut reader = BufReader::new(file);
        reader.read_to_end(&mut buffer)?;
        Ok(buffer)
    }
}

/// Reads the trailing `cap` bytes across the chronological chain of segments in a session directory.
///
/// Returns `(start_offset, combined_bytes)` where `start_offset` is the absolute byte offset
/// within the logical uncompressed stream.
pub fn read_multi_segment_tail(
    session_dir: &Path,
    total_uncompressed_bytes: u64,
    cap: u64,
) -> (u64, Vec<u8>) {
    if total_uncompressed_bytes == 0 || cap == 0 {
        return (0, Vec::new());
    }

    let start_offset = total_uncompressed_bytes.saturating_sub(cap);
    let needed_bytes = (total_uncompressed_bytes - start_offset) as usize;

    let segments = match list_session_segments(session_dir) {
        Ok(s) => s,
        Err(err) => {
            tracing::warn!(
                session_dir = %session_dir.display(),
                ?err,
                "failed to list segments; returning empty tail"
            );
            return (0, Vec::new());
        }
    };

    if segments.is_empty() {
        return (0, Vec::new());
    }

    // Read all segments in reverse order until we have accumulated at least `needed_bytes`
    let mut collected_chunks: Vec<Vec<u8>> = Vec::new();
    let mut accumulated_len = 0;

    for segment in segments.iter().rev() {
        if accumulated_len >= needed_bytes {
            break;
        }

        match read_segment_uncompressed(segment) {
            Ok(bytes) => {
                accumulated_len += bytes.len();
                collected_chunks.push(bytes);
            }
            Err(err) => {
                tracing::warn!(
                    path = %segment.path.display(),
                    ?err,
                    "failed to read segment uncompressed"
                );
            }
        }
    }

    // Reconstruct chunks in chronological order
    collected_chunks.reverse();
    let mut combined: Vec<u8> = Vec::with_capacity(accumulated_len);
    for chunk in collected_chunks {
        combined.extend_from_slice(&chunk);
    }

    // Slice to the requested tail
    if combined.len() > needed_bytes {
        let skip = combined.len() - needed_bytes;
        combined.drain(..skip);
    }

    (start_offset, combined)
}

/// Reads the trailing `cap` bytes of a session directory for terminal replay during restore or resize.
///
/// Returns `(total_uncompressed_len, tail_bytes)`.
pub fn read_multi_segment_replay_tail(session_dir: &Path, cap: u64) -> Result<(u64, Vec<u8>)> {
    let segments = list_session_segments(session_dir)?;
    if segments.is_empty() {
        return Ok((0, Vec::new()));
    }

    let mut total_uncompressed_len: u64 = 0;
    let mut uncompressed_segments: Vec<Vec<u8>> = Vec::new();

    for segment in &segments {
        let bytes = read_segment_uncompressed(segment)?;
        total_uncompressed_len += bytes.len() as u64;
        uncompressed_segments.push(bytes);
    }

    let needed_bytes = (total_uncompressed_len.min(cap)) as usize;
    let mut combined = Vec::with_capacity(needed_bytes);

    let start_offset = total_uncompressed_len.saturating_sub(cap) as usize;
    let mut current_offset: usize = 0;

    for chunk in uncompressed_segments {
        let chunk_len = chunk.len();
        let chunk_end = current_offset + chunk_len;

        if chunk_end > start_offset {
            let slice_start = start_offset.saturating_sub(current_offset);
            combined.extend_from_slice(&chunk[slice_start..]);
        }
        current_offset = chunk_end;
    }

    Ok((total_uncompressed_len, combined))
}

/// A job sent to the background compression worker.
#[derive(Debug)]
pub struct CompressionJob {
    pub raw_path: PathBuf,
    pub compressed_path: PathBuf,
}

/// Handle to the background segment compression worker thread.
pub struct CompressionWorker {
    tx: Option<Sender<CompressionJob>>,
    handle: Option<JoinHandle<()>>,
}

impl CompressionWorker {
    pub fn start() -> Self {
        let (tx, rx) = mpsc::channel::<CompressionJob>();
        let handle = thread::Builder::new()
            .name("triage-compression-worker".into())
            .spawn(move || {
                Self::run_worker(rx);
            })
            .expect("spawn compression worker");

        Self {
            tx: Some(tx),
            handle: Some(handle),
        }
    }

    pub fn sender(&self) -> Option<Sender<CompressionJob>> {
        self.tx.clone()
    }

    fn run_worker(rx: Receiver<CompressionJob>) {
        while let Ok(job) = rx.recv() {
            if let Err(err) = compress_segment_file(&job.raw_path, &job.compressed_path) {
                tracing::warn!(
                    raw_path = %job.raw_path.display(),
                    compressed_path = %job.compressed_path.display(),
                    ?err,
                    "failed to compress rotated segment file"
                );
            } else {
                tracing::debug!(
                    raw_path = %job.raw_path.display(),
                    compressed_path = %job.compressed_path.display(),
                    "successfully compressed segment file"
                );
            }
        }
    }
}

impl Drop for CompressionWorker {
    fn drop(&mut self) {
        drop(self.tx.take());
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// Strips standard ANSI and VT100 escape sequences from byte streams for plain-text search.
pub fn strip_ansi_escapes(input: &[u8]) -> String {
    let mut output = String::with_capacity(input.len());
    let mut in_escape = false;
    let mut in_csi = false;
    let mut in_osc = false;

    let mut i = 0;
    while i < input.len() {
        let b = input[i];

        if in_escape {
            if b == b'[' {
                in_csi = true;
                in_escape = false;
            } else if b == b']' {
                in_osc = true;
                in_escape = false;
            } else {
                in_escape = false;
            }
            i += 1;
            continue;
        }

        if in_csi {
            // CSI sequences terminate with characters in range 0x40..=0x7E (@ through ~)
            if (0x40..=0x7E).contains(&b) {
                in_csi = false;
            }
            i += 1;
            continue;
        }

        if in_osc {
            // OSC sequences terminate with BEL (0x07) or ST (ESC \)
            if b == 0x07 {
                in_osc = false;
            } else if b == 0x1B && i + 1 < input.len() && input[i + 1] == b'\\' {
                in_osc = false;
                i += 1;
            }
            i += 1;
            continue;
        }

        if b == 0x1B {
            in_escape = true;
            i += 1;
            continue;
        }

        // Keep printable ASCII, newlines, tabs, and valid UTF-8 sequences
        if b == b'\n' || b == b'\r' || b == b'\t' || b >= 0x20 {
            output.push(b as char);
        }

        i += 1;
    }

    output
}

/// A search hit found in a session segment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    pub segment_index: u32,
    pub line_number: usize,
    pub line_text: String,
}

/// Searches all segment files in a session directory on-demand for a given query string.
pub fn search_session_segments(
    session_dir: &Path,
    query: &str,
    case_insensitive: bool,
) -> Result<Vec<SearchHit>> {
    if query.trim().is_empty() {
        return Ok(Vec::new());
    }

    let segments = list_session_segments(session_dir)?;
    let mut hits = Vec::new();

    let query_lower = query.to_lowercase();

    for segment in segments {
        let uncompressed = match read_segment_uncompressed(&segment) {
            Ok(b) => b,
            Err(err) => {
                tracing::warn!(
                    path = %segment.path.display(),
                    ?err,
                    "skipping unreadable segment during search"
                );
                continue;
            }
        };

        let clean_text = strip_ansi_escapes(&uncompressed);

        for (line_idx, line) in clean_text.lines().enumerate() {
            let matches = if case_insensitive {
                line.to_lowercase().contains(&query_lower)
            } else {
                line.contains(query)
            };

            if matches {
                hits.push(SearchHit {
                    segment_index: segment.index,
                    line_number: line_idx + 1,
                    line_text: line.to_string(),
                });
            }
        }
    }

    Ok(hits)
}

/// Migrates a legacy unsegmented `session-*.log` file into 8 MiB segments in `session_dir`.
///
/// Non-active historical segments are compressed to `.tlog.zst`. The legacy log is renamed
/// to `.log.migrated`.
pub fn migrate_legacy_session_log(
    legacy_log_path: &Path,
    session_dir: &Path,
    segment_size: u64,
) -> Result<u64> {
    if !legacy_log_path.exists() {
        return Ok(0);
    }

    let file = File::open(legacy_log_path)
        .with_context(|| format!("opening legacy log {}", legacy_log_path.display()))?;
    let total_len = file.metadata()?.len();

    fs::create_dir_all(session_dir).with_context(|| {
        format!(
            "creating session directory for migration: {}",
            session_dir.display()
        )
    })?;

    if total_len == 0 {
        let active_path = session_dir.join(segment_file_name(1));
        File::create(&active_path)?;
        let migrated_path = legacy_log_path.with_extension("log.migrated");
        let _ = fs::rename(legacy_log_path, migrated_path);
        return Ok(0);
    }

    let mut reader = BufReader::new(file);
    let mut segment_index: u32 = 1;
    let mut bytes_remaining = total_len;

    while bytes_remaining > 0 {
        let chunk_size = bytes_remaining.min(segment_size) as usize;
        let mut buffer = vec![0u8; chunk_size];
        reader.read_exact(&mut buffer)?;

        let is_last_segment = bytes_remaining <= segment_size;
        let segment_path = session_dir.join(segment_file_name(segment_index));

        if is_last_segment {
            // Write active segment uncompressed
            let mut seg_file = File::create(&segment_path)?;
            seg_file.write_all(&buffer)?;
        } else {
            // Compress closed segment immediately
            let compressed_path = session_dir.join(compressed_segment_file_name(segment_index));
            let tmp_compressed_path = compressed_path.with_extension("tmp");

            let tmp_file = File::create(&tmp_compressed_path)?;
            let writer = BufWriter::new(tmp_file);

            zstd::stream::copy_encode(&buffer[..], writer, ZSTD_COMPRESSION_LEVEL)?;
            fs::rename(&tmp_compressed_path, &compressed_path)?;
        }

        bytes_remaining -= chunk_size as u64;
        segment_index += 1;
    }

    // Rename legacy file to .migrated
    let migrated_path = legacy_log_path.with_extension("log.migrated");
    let _ = fs::rename(legacy_log_path, migrated_path);

    Ok(total_len)
}
