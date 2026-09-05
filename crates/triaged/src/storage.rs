use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
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
const COMPRESSED_SUFFIX: &str = ".tlog.zst";
const UNCOMPRESSED_SUFFIX: &str = ".tlog";

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
    if let Some(num_str) = remainder.strip_suffix(COMPRESSED_SUFFIX) {
        num_str.parse::<u32>().ok().map(|idx| (idx, true))
    } else if let Some(num_str) = remainder.strip_suffix(UNCOMPRESSED_SUFFIX) {
        num_str.parse::<u32>().ok().map(|idx| (idx, false))
    } else {
        None
    }
}

/// Lists all segment files in a session directory, sorted in ascending chronological order by index.
///
/// If both an uncompressed and a compressed file exist for the same segment index, the compressed
/// `.tlog.zst` takes precedence if valid, as the uncompressed file may be in flight to be unlinked
/// by the background compression worker.
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
                    // Prefer compressed if valid: uncompressed may be in flight to be unlinked
                    if (is_compressed && file_size > 0)
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

/// Resolves the active uncompressed segment for a session directory.
///
/// If uncompressed segments exist, returns the latest uncompressed segment.
/// If all existing segments are compressed, targets the next sequential segment index with 0 bytes.
/// If no segments exist, returns the initial segment index (1) with 0 bytes.
pub fn resolve_active_segment(session_dir: &Path) -> Result<(PathBuf, u32, u64)> {
    let segments = list_session_segments(session_dir)?;
    if let Some(uncompressed) = segments.iter().rev().find(|s| !s.is_compressed) {
        Ok((
            uncompressed.path.clone(),
            uncompressed.index,
            uncompressed.file_size,
        ))
    } else if let Some(last) = segments.last() {
        let next_idx = last.index + 1;
        let next_path = session_dir.join(segment_file_name(next_idx));
        Ok((next_path, next_idx, 0))
    } else {
        let first_path = session_dir.join(segment_file_name(1));
        Ok((first_path, 1, 0))
    }
}

/// Compresses a raw `.tlog` segment file to `.tlog.zst` using zstd.
///
/// Writes to a PID-isolated temporary file first, then atomically renames to the final
/// compressed path, and finally unlinks the raw file.
pub fn compress_segment_file(raw_path: &Path, compressed_path: &Path) -> Result<u64> {
    ensure!(raw_path.exists(), "raw segment path does not exist");

    let tmp_name = format!(
        "{}.tmp.{}",
        compressed_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("segment"),
        std::process::id()
    );
    let tmp_path = compressed_path.with_file_name(tmp_name);
    let encode_res = (|| -> Result<()> {
        let raw_file = File::open(raw_path)
            .with_context(|| format!("opening raw segment {}", raw_path.display()))?;
        let raw_len = raw_file.metadata()?.len();
        let mut reader = BufReader::new(raw_file);

        let tmp_file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp_path)
            .with_context(|| format!("creating temp compressed segment {}", tmp_path.display()))?;
        let writer = BufWriter::new(tmp_file);

        let mut encoder = zstd::stream::Encoder::new(writer, ZSTD_COMPRESSION_LEVEL)?;
        encoder.set_pledged_src_size(Some(raw_len))?;
        std::io::copy(&mut reader, &mut encoder)?;
        let mut writer = encoder.finish()?;
        writer.flush()?;
        drop(writer);
        Ok(())
    })();

    if let Err(err) = encode_res {
        let _ = fs::remove_file(&tmp_path);
        return Err(err);
    }

    // Atomic rename
    if let Err(err) = fs::rename(&tmp_path, compressed_path) {
        let _ = fs::remove_file(&tmp_path);
        return Err(err).with_context(|| {
            format!(
                "renaming {} to {}",
                tmp_path.display(),
                compressed_path.display()
            )
        });
    }

    let compressed_len = fs::metadata(compressed_path)?.len();

    // Remove original uncompressed file
    let _ = fs::remove_file(raw_path);

    Ok(compressed_len)
}

/// Returns the uncompressed byte length of a segment.
///
/// For uncompressed `.tlog` files, returns `info.file_size`.
/// For compressed `.tlog.zst` files, inspects the zstd frame header for the pledged
/// uncompressed frame size in O(1) time without decompressing. If the frame header
/// does not store the content size, falls back to decoding the stream into `io::sink()`.
pub fn get_segment_uncompressed_size(info: &SegmentFileInfo) -> Result<u64> {
    if !info.is_compressed {
        return Ok(info.file_size);
    }

    let mut file = match File::open(&info.path) {
        Ok(f) => f,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let uncompressed_path = info.path.with_file_name(segment_file_name(info.index));
            if let Ok(meta) = fs::metadata(&uncompressed_path) {
                return Ok(meta.len());
            }
            return Err(err).with_context(|| format!("opening segment {}", info.path.display()));
        }
        Err(err) => {
            return Err(err).with_context(|| format!("opening segment {}", info.path.display()));
        }
    };

    let mut header_buf = [0u8; 256];
    if let Ok(n) = file.read(&mut header_buf)
        && let Ok(Some(size)) = zstd::zstd_safe::get_frame_content_size(&header_buf[..n])
    {
        return Ok(size);
    }

    let fallback_file = File::open(&info.path)
        .with_context(|| format!("opening fallback segment file {}", info.path.display()))?;
    let mut decoder = zstd::stream::Decoder::new(BufReader::new(fallback_file))
        .with_context(|| format!("decoding zstd segment {}", info.path.display()))?;
    let count = std::io::copy(&mut decoder, &mut std::io::sink())?;
    Ok(count)
}

/// Reads the entire uncompressed content of a segment.
pub fn read_segment_uncompressed(info: &SegmentFileInfo) -> Result<Vec<u8>> {
    let (file, is_compressed) = match File::open(&info.path) {
        Ok(f) => (f, info.is_compressed),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound && !info.is_compressed => {
            let compressed_path = info
                .path
                .with_file_name(compressed_segment_file_name(info.index));
            let f = File::open(&compressed_path).with_context(|| {
                format!(
                    "opening fallback compressed segment {}",
                    compressed_path.display()
                )
            })?;
            (f, true)
        }
        Err(err) => {
            return Err(err)
                .with_context(|| format!("opening segment file {}", info.path.display()));
        }
    };

    if is_compressed {
        let mut decoder = zstd::stream::Decoder::new(BufReader::new(file))
            .with_context(|| format!("decoding zstd segment {}", info.path.display()))?;
        let mut buffer = Vec::with_capacity(DEFAULT_SEGMENT_SIZE_BYTES as usize);
        decoder.read_to_end(&mut buffer)?;
        Ok(buffer)
    } else {
        let mut buffer = Vec::with_capacity(info.file_size as usize);
        let mut reader = BufReader::new(file);
        reader.read_to_end(&mut buffer)?;
        Ok(buffer)
    }
}

/// Reads up to `tail_bytes` from the tail of an uncompressed `.tlog` segment file using `Seek`.
pub fn read_segment_tail_uncompressed(
    info: &SegmentFileInfo,
    tail_bytes: usize,
) -> Result<Vec<u8>> {
    let mut file = match File::open(&info.path) {
        Ok(f) => f,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            // If the segment was concurrently compressed by the worker, fall back to decompressing
            return read_segment_uncompressed(info);
        }
        Err(err) => {
            return Err(err)
                .with_context(|| format!("opening segment file {}", info.path.display()));
        }
    };

    let file_size = file.metadata()?.len();
    let to_read = (tail_bytes as u64).min(file_size) as usize;
    let start_offset = file_size.saturating_sub(to_read as u64);
    file.seek(SeekFrom::Start(start_offset))?;
    let mut buffer = vec![0u8; to_read];
    file.read_exact(&mut buffer)?;
    Ok(buffer)
}

/// Reads up to `tail_bytes` from the tail of a segment.
///
/// For uncompressed `.tlog` files, seeks directly to the end of the file on disk and reads
/// only the requested trailing slice, avoiding loading the entire segment into memory.
/// For compressed `.tlog.zst` files, decompresses the segment and takes the trailing slice.
pub fn read_segment_tail(info: &SegmentFileInfo, tail_bytes: usize) -> Result<Vec<u8>> {
    if !info.is_compressed {
        return read_segment_tail_uncompressed(info, tail_bytes);
    }
    let mut buffer = read_segment_uncompressed(info)?;
    if buffer.len() > tail_bytes {
        let skip = buffer.len() - tail_bytes;
        buffer.drain(..skip);
    }
    Ok(buffer)
}

/// Reads the trailing `cap` bytes across the chronological chain of segments in a session directory.
///
/// Returns `(start_offset, combined_bytes)` where `start_offset` is the absolute byte offset
/// within the logical uncompressed stream.
pub fn read_multi_segment_tail(
    session_dir: &Path,
    total_uncompressed_bytes: u64,
    cap: u64,
) -> Result<(u64, Vec<u8>)> {
    if total_uncompressed_bytes == 0 || cap == 0 {
        return Ok((0, Vec::new()));
    }

    let start_offset = total_uncompressed_bytes.saturating_sub(cap);
    let needed_bytes = (total_uncompressed_bytes - start_offset) as usize;

    // A listing failure is reported, never folded into the empty tail that a
    // session with no segments returns. The two are indistinguishable to a
    // caller, so swallowing the error renders intact on-disk history as empty
    // scrollback; and because the condition is usually transient (`EMFILE`
    // against the daemon's descriptor ceiling), it looks like data loss rather
    // than the retryable I/O error it is.
    let segments = list_session_segments(session_dir)?;

    if segments.is_empty() {
        return Ok((0, Vec::new()));
    }

    // Read all segments in reverse order until we have accumulated at least `needed_bytes`
    let mut collected_chunks: Vec<Vec<u8>> = Vec::new();
    let mut accumulated_len = 0;

    for segment in segments.iter().rev() {
        if accumulated_len >= needed_bytes {
            break;
        }

        let remaining_needed = needed_bytes - accumulated_len;
        // Skipping a failed segment is not a safe degradation: `start_offset` is
        // derived below from the *length* of what was collected, so dropping a
        // segment from the middle of the chain silently relabels the surviving
        // bytes with offsets that belong to the missing ones. Clients index live
        // writes against those offsets, so the result is misaligned scrollback
        // rather than a short read. Fail instead, and let the caller retry.
        let bytes = read_segment_tail(segment, remaining_needed)
            .with_context(|| format!("reading segment tail {}", segment.path.display()))?;
        accumulated_len += bytes.len();
        collected_chunks.push(bytes);
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

    let start_offset = total_uncompressed_bytes.saturating_sub(combined.len() as u64);
    Ok((start_offset, combined))
}

/// Reads the trailing `cap` bytes of a session directory for terminal replay during restore or resize.
///
/// Returns `(total_uncompressed_len, tail_bytes)`. Memory usage is bounded strictly by `cap`.
pub fn read_multi_segment_replay_tail(session_dir: &Path, cap: u64) -> Result<(u64, Vec<u8>)> {
    let segments = list_session_segments(session_dir)?;
    if segments.is_empty() {
        return Ok((0, Vec::new()));
    }

    // Compute total uncompressed stream length across all segments in O(1) time per segment
    let mut total_uncompressed_len = 0u64;
    for segment in &segments {
        total_uncompressed_len += get_segment_uncompressed_size(segment)?;
    }

    let cap_usize = cap as usize;
    let mut collected_chunks: Vec<Vec<u8>> = Vec::new();
    let mut accumulated_tail_len = 0;

    for segment in segments.iter().rev() {
        if accumulated_tail_len >= cap_usize {
            break;
        }
        let remaining_needed = cap_usize - accumulated_tail_len;
        let bytes = read_segment_tail(segment, remaining_needed)?;
        accumulated_tail_len += bytes.len();
        collected_chunks.push(bytes);
    }

    collected_chunks.reverse();
    let mut combined = Vec::with_capacity(accumulated_tail_len.min(cap_usize));
    for chunk in collected_chunks {
        combined.extend_from_slice(&chunk);
    }

    if combined.len() > cap_usize {
        let skip = combined.len() - cap_usize;
        combined.drain(..skip);
    }

    Ok((total_uncompressed_len, combined))
}

/// A job sent to the background compression worker.
#[derive(Debug, Clone)]
pub struct CompressionJob {
    pub raw_path: PathBuf,
    pub compressed_path: PathBuf,
}

/// Message sent across the worker channel.
#[derive(Debug)]
pub enum WorkerMessage {
    Job(CompressionJob),
    Stop,
}

/// Handle to the background segment compression worker thread.
pub struct CompressionWorker {
    tx: Option<Sender<WorkerMessage>>,
    handle: Option<JoinHandle<()>>,
}

impl CompressionWorker {
    pub fn start() -> Self {
        let (tx, rx) = mpsc::channel::<WorkerMessage>();
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

    pub fn sender(&self) -> Option<Sender<WorkerMessage>> {
        self.tx.clone()
    }

    fn run_worker(rx: Receiver<WorkerMessage>) {
        while let Ok(msg) = rx.recv() {
            let job = match msg {
                WorkerMessage::Job(job) => job,
                WorkerMessage::Stop => {
                    while let Ok(WorkerMessage::Job(pending_job)) = rx.try_recv() {
                        if let Err(err) = compress_segment_file(
                            &pending_job.raw_path,
                            &pending_job.compressed_path,
                        ) {
                            tracing::warn!(
                                raw_path = %pending_job.raw_path.display(),
                                compressed_path = %pending_job.compressed_path.display(),
                                ?err,
                                "failed to compress segment file during worker teardown"
                            );
                        }
                    }
                    break;
                }
            };
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
        if let Some(tx) = self.tx.take() {
            let _ = tx.send(WorkerMessage::Stop);
        }
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// Strips standard ANSI and VT100 escape sequences from byte streams for plain-text search.
pub fn strip_ansi_escapes(input: &[u8]) -> String {
    let mut output_bytes = Vec::with_capacity(input.len());
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
            output_bytes.push(b);
        }

        i += 1;
    }

    String::from_utf8_lossy(&output_bytes).into_owned()
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
            if line_matches_query(line, query, &query_lower, case_insensitive) {
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

/// Matches a line of text against a query string with minimal heap allocations.
pub fn line_matches_query(
    line: &str,
    query: &str,
    query_lower: &str,
    case_insensitive: bool,
) -> bool {
    if !case_insensitive {
        return line.contains(query);
    }
    if line.len() < query.len() {
        return false;
    }
    if line.is_ascii() && query.is_ascii() {
        let line_bytes = line.as_bytes();
        let query_bytes = query_lower.as_bytes();
        line_bytes
            .windows(query_bytes.len())
            .any(|window| window.eq_ignore_ascii_case(query_bytes))
    } else {
        line.to_lowercase().contains(query_lower)
    }
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

    ensure!(segment_size > 0, "segment size must be greater than zero");

    let file = File::open(legacy_log_path)
        .with_context(|| format!("opening legacy log {}", legacy_log_path.display()))?;
    let total_len = file.metadata()?.len();

    let parent = session_dir.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)
        .with_context(|| format!("creating parent directory {}", parent.display()))?;

    let tmp_dir_name = format!(
        ".tmp-migrate-{}-{}",
        std::process::id(),
        session_dir
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("session")
    );
    let tmp_dir = parent.join(tmp_dir_name);
    let _ = fs::remove_dir_all(&tmp_dir);
    fs::create_dir_all(&tmp_dir)
        .with_context(|| format!("creating temp migration dir {}", tmp_dir.display()))?;

    let migrate_res = (|| -> Result<()> {
        if total_len == 0 {
            let active_path = tmp_dir.join(segment_file_name(1));
            File::create(&active_path)?;
            return Ok(());
        }

        let mut reader = BufReader::new(file);
        let mut segment_index: u32 = 1;
        let mut bytes_remaining = total_len;
        let mut buffer = vec![0u8; segment_size as usize];

        while bytes_remaining > 0 {
            let chunk_size = bytes_remaining.min(segment_size) as usize;
            let chunk_slice = &mut buffer[..chunk_size];
            reader.read_exact(chunk_slice)?;

            let is_last_segment = bytes_remaining <= segment_size;

            if is_last_segment {
                let segment_path = tmp_dir.join(segment_file_name(segment_index));
                let mut seg_file = File::create(&segment_path)?;
                seg_file.write_all(chunk_slice)?;
                seg_file.flush()?;
                drop(seg_file);
            } else {
                let compressed_path = tmp_dir.join(compressed_segment_file_name(segment_index));
                let tmp_compressed_name =
                    format!("segment-{segment_index:06}.tmp.{}", std::process::id());
                let tmp_compressed_path = tmp_dir.join(tmp_compressed_name);

                let tmp_file = File::create(&tmp_compressed_path)?;
                let writer = BufWriter::new(tmp_file);

                let mut encoder = zstd::stream::Encoder::new(writer, ZSTD_COMPRESSION_LEVEL)?;
                encoder.set_pledged_src_size(Some(chunk_size as u64))?;
                std::io::copy(&mut &*chunk_slice, &mut encoder)?;
                let mut writer = encoder.finish()?;
                writer.flush()?;
                drop(writer);

                fs::rename(&tmp_compressed_path, &compressed_path)?;
            }

            bytes_remaining -= chunk_size as u64;
            segment_index += 1;
        }
        Ok(())
    })();

    if let Err(err) = migrate_res {
        let _ = fs::remove_dir_all(&tmp_dir);
        return Err(err);
    }

    if session_dir.exists() {
        let _ = fs::remove_dir_all(session_dir);
    }
    if let Err(err) = fs::rename(&tmp_dir, session_dir) {
        let _ = fs::remove_dir_all(&tmp_dir);
        return Err(err).with_context(|| {
            format!(
                "renaming migration temp dir {} to {}",
                tmp_dir.display(),
                session_dir.display()
            )
        });
    }

    // Rename legacy file to .migrated
    let migrated_path = legacy_log_path.with_extension("log.migrated");
    let _ = fs::rename(legacy_log_path, migrated_path);

    Ok(total_len)
}
