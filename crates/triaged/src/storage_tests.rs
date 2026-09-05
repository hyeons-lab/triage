use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::storage::*;

fn unique_test_dir() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let unique = format!(
        "triage-storage-test-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let dir = std::env::temp_dir().join(unique);
    fs::create_dir_all(&dir).expect("create unique test dir");
    dir
}

#[test]
fn segment_file_naming_and_parsing() {
    assert_eq!(segment_file_name(1), "segment-000001.tlog");
    assert_eq!(segment_file_name(42), "segment-000042.tlog");
    assert_eq!(compressed_segment_file_name(1), "segment-000001.tlog.zst");
    assert_eq!(compressed_segment_file_name(42), "segment-000042.tlog.zst");

    assert_eq!(parse_segment_index("segment-000001.tlog"), Some((1, false)));
    assert_eq!(
        parse_segment_index("segment-000042.tlog.zst"),
        Some((42, true))
    );
    assert_eq!(parse_segment_index("other_file.txt"), None);
    assert_eq!(parse_segment_index("segment-invalid.tlog"), None);
}

#[test]
fn segment_compression_and_decompression() {
    let temp_dir = unique_test_dir();
    let raw_path = temp_dir.join("segment-000001.tlog");
    let compressed_path = temp_dir.join("segment-000001.tlog.zst");

    let test_data =
        b"Hello, world! This is a test string repeated multiple times for compression.\n"
            .repeat(500);
    fs::write(&raw_path, &test_data).expect("write raw file");

    let raw_len = fs::metadata(&raw_path).expect("metadata").len();
    assert_eq!(raw_len, test_data.len() as u64);

    let compressed_len =
        compress_segment_file(&raw_path, &compressed_path).expect("compress segment");
    assert!(compressed_len > 0);
    assert!(compressed_len < raw_len);
    assert!(!raw_path.exists());
    assert!(compressed_path.exists());

    let segment_info = SegmentFileInfo {
        index: 1,
        path: compressed_path,
        is_compressed: true,
        file_size: compressed_len,
    };

    let decompressed = read_segment_uncompressed(&segment_info).expect("read decompressed");
    assert_eq!(decompressed, test_data);

    let mut f = File::open(&segment_info.path).expect("open compressed");
    let mut header_buf = [0u8; 256];
    let n = f.read(&mut header_buf).expect("read header");
    let frame_size = zstd::zstd_safe::get_frame_content_size(&header_buf[..n]);
    assert_eq!(frame_size.ok().flatten(), Some(raw_len));

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn multi_segment_tail_assembly() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("session-1");
    fs::create_dir_all(&session_dir).expect("mkdir");

    // Segment 1 (compressed): 1000 bytes
    let seg1_raw = session_dir.join("segment-000001.tlog");
    let seg1_data = vec![b'A'; 1000];
    fs::write(&seg1_raw, &seg1_data).expect("write seg1");
    compress_segment_file(&seg1_raw, &session_dir.join("segment-000001.tlog.zst"))
        .expect("compress seg1");

    // Segment 2 (compressed): 1000 bytes
    let seg2_raw = session_dir.join("segment-000002.tlog");
    let seg2_data = vec![b'B'; 1000];
    fs::write(&seg2_raw, &seg2_data).expect("write seg2");
    compress_segment_file(&seg2_raw, &session_dir.join("segment-000002.tlog.zst"))
        .expect("compress seg2");

    // Segment 3 (uncompressed active): 500 bytes
    let seg3_raw = session_dir.join("segment-000003.tlog");
    let seg3_data = vec![b'C'; 500];
    fs::write(&seg3_raw, &seg3_data).expect("write seg3");

    let total_bytes: u64 = 1000 + 1000 + 500; // 2500

    // Request tail of 800 bytes: should get 300 bytes of 'B' + 500 bytes of 'C'
    let (start_offset, tail) =
        read_multi_segment_tail(&session_dir, total_bytes, 800).expect("read tail");
    assert_eq!(start_offset, 1700);
    assert_eq!(tail.len(), 800);
    assert_eq!(&tail[..300], &vec![b'B'; 300][..]);
    assert_eq!(&tail[300..], &vec![b'C'; 500][..]);

    // Request tail of 2000 bytes: should get 500 bytes of 'A', 1000 bytes of 'B', 500 bytes of 'C'
    let (start_offset, tail) =
        read_multi_segment_tail(&session_dir, total_bytes, 2000).expect("read tail");
    assert_eq!(start_offset, 500);
    assert_eq!(tail.len(), 2000);
    assert_eq!(&tail[..500], &vec![b'A'; 500][..]);
    assert_eq!(&tail[500..1500], &vec![b'B'; 1000][..]);
    assert_eq!(&tail[1500..], &vec![b'C'; 500][..]);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn multi_segment_replay_tail() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("session-replay");
    fs::create_dir_all(&session_dir).expect("mkdir");

    let seg1_raw = session_dir.join("segment-000001.tlog");
    fs::write(&seg1_raw, b"FIRST_SEGMENT_").expect("write seg1");
    compress_segment_file(&seg1_raw, &session_dir.join("segment-000001.tlog.zst"))
        .expect("compress seg1");

    let seg2_raw = session_dir.join("segment-000002.tlog");
    fs::write(&seg2_raw, b"SECOND_SEGMENT").expect("write seg2");

    let (total_len, replay_tail) =
        read_multi_segment_replay_tail(&session_dir, 1024).expect("read replay tail");
    assert_eq!(total_len, b"FIRST_SEGMENT_SECOND_SEGMENT".len() as u64);
    assert_eq!(replay_tail, b"FIRST_SEGMENT_SECOND_SEGMENT");

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn ansi_stripping_and_search() {
    let raw_ansi = b"\x1b[31mError:\x1b[0m Failed to connect to server \x1b[32m[OK]\x1b[0m\nSecond line normal text\n";
    let stripped = strip_ansi_escapes(raw_ansi);
    assert_eq!(
        stripped,
        "Error: Failed to connect to server [OK]\nSecond line normal text\n"
    );

    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("search-session");
    fs::create_dir_all(&session_dir).expect("mkdir");

    let seg1_raw = session_dir.join("segment-000001.tlog");
    fs::write(&seg1_raw, raw_ansi).expect("write seg1");
    compress_segment_file(&seg1_raw, &session_dir.join("segment-000001.tlog.zst"))
        .expect("compress seg1");

    let seg2_raw = session_dir.join("segment-000002.tlog");
    fs::write(
        &seg2_raw,
        b"Another line with error in lowercase\nFinal line\n",
    )
    .expect("write seg2");

    let hits = search_session_segments(&session_dir, "error", true).expect("search");
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].segment_index, 1);
    assert_eq!(hits[0].line_number, 1);
    assert!(hits[0].line_text.contains("Error: Failed to connect"));

    assert_eq!(hits[1].segment_index, 2);
    assert_eq!(hits[1].line_number, 1);
    assert!(hits[1].line_text.contains("Another line with error"));

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn legacy_log_migration() {
    let temp_dir = unique_test_dir();
    let legacy_log = temp_dir.join("session-99-12345.log");
    let session_dir = temp_dir.join("sessions").join("session-99");

    // Write 2.5 KiB of data to legacy log
    let chunk_a = vec![b'X'; 1024];
    let chunk_b = vec![b'Y'; 1024];
    let chunk_c = vec![b'Z'; 512];

    let mut legacy_file = File::create(&legacy_log).expect("create legacy log");
    legacy_file.write_all(&chunk_a).expect("write chunk a");
    legacy_file.write_all(&chunk_b).expect("write chunk b");
    legacy_file.write_all(&chunk_c).expect("write chunk c");
    drop(legacy_file);

    // Migrate with a small segment size of 1024 bytes
    let migrated_bytes =
        migrate_legacy_session_log(&legacy_log, &session_dir, 1024).expect("migrate");
    assert_eq!(migrated_bytes, 2560);
    assert!(!legacy_log.exists());
    assert!(legacy_log.with_extension("log.migrated").exists());

    let segments = list_session_segments(&session_dir).expect("list segments");
    assert_eq!(segments.len(), 3);
    assert_eq!(segments[0].index, 1);
    assert!(segments[0].is_compressed); // segment 1 was closed and compressed
    assert_eq!(segments[1].index, 2);
    assert!(segments[1].is_compressed); // segment 2 was closed and compressed
    assert_eq!(segments[2].index, 3);
    assert!(!segments[2].is_compressed); // segment 3 is active uncompressed

    let tail = read_multi_segment_tail(&session_dir, 2560, 2560).expect("read tail");
    assert_eq!(tail.0, 0);
    assert_eq!(tail.1.len(), 2560);
    assert_eq!(&tail.1[..1024], &chunk_a[..]);
    assert_eq!(&tail.1[1024..2048], &chunk_b[..]);
    assert_eq!(&tail.1[2048..], &chunk_c[..]);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn compression_worker_background_processing() {
    let temp_dir = unique_test_dir();
    let raw_path = temp_dir.join("segment-000001.tlog");
    let compressed_path = temp_dir.join("segment-000001.tlog.zst");

    fs::write(&raw_path, b"Worker test data").expect("write raw file");

    let worker = CompressionWorker::start();
    let tx = worker.sender().expect("sender");

    tx.send(WorkerMessage::Job(CompressionJob {
        raw_path: raw_path.clone(),
        compressed_path: compressed_path.clone(),
    }))
    .expect("send job");

    // Wait for worker to finish job
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while !compressed_path.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    assert!(compressed_path.exists());
    assert!(!raw_path.exists());

    // Drop worker and verify thread joins cleanly
    drop(worker);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn strip_ansi_escapes_preserves_multibyte_utf8() {
    let unicode_text = "✨ \x1b[1;34mTerminal\x1b[0m 🚀 \x1b[32m日本語\x1b[0m ┌─┐\n";
    let stripped = strip_ansi_escapes(unicode_text.as_bytes());
    assert_eq!(stripped, "✨ Terminal 🚀 日本語 ┌─┐\n");
}

#[test]
fn replay_tail_memory_bounded_across_many_segments() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("session-many-segments");
    fs::create_dir_all(&session_dir).expect("mkdir");

    // Create 10 segments of 1000 bytes each (10,000 bytes total)
    for i in 1..=10 {
        let seg_name = segment_file_name(i);
        let raw_path = session_dir.join(&seg_name);
        let pattern = format!("SEGMENT_{:06}_\n", i);
        let data = pattern.repeat(100); // 1500 bytes
        fs::write(&raw_path, &data).expect("write segment");

        if i < 10 {
            let comp_name = compressed_segment_file_name(i);
            compress_segment_file(&raw_path, &session_dir.join(comp_name))
                .expect("compress segment");
        }
    }

    // Request tail of 2000 bytes: total bytes must reflect the entire stream, while returned tail is capped
    let (total_len, tail) =
        read_multi_segment_replay_tail(&session_dir, 2000).expect("read replay tail");
    assert_eq!(total_len, 1600 * 10);
    assert_eq!(tail.len(), 2000);
    assert!(String::from_utf8_lossy(&tail).contains("SEGMENT_000010_"));

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn read_segment_uncompressed_fallback_on_deleted_raw() {
    let temp_dir = unique_test_dir();
    let raw_path = temp_dir.join("segment-000005.tlog");
    let compressed_path = temp_dir.join("segment-000005.tlog.zst");

    fs::write(&raw_path, b"Segment content to compress").expect("write raw");
    compress_segment_file(&raw_path, &compressed_path).expect("compress");

    // Raw file was deleted by compress_segment_file.
    // Simulate SegmentFileInfo pointing to raw_path but is_compressed false (TOCTOU race)
    let info = SegmentFileInfo {
        index: 5,
        path: raw_path,
        is_compressed: false,
        file_size: 27,
    };

    let content = read_segment_uncompressed(&info).expect("read fallback");
    assert_eq!(content, b"Segment content to compress");

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn resolve_active_segment_cases() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("session-active-seg");
    fs::create_dir_all(&session_dir).expect("mkdir");

    // Case 1: empty dir -> segment-000001.tlog, index 1, len 0
    let (path, idx, len) = resolve_active_segment(&session_dir).expect("empty dir");
    assert_eq!(idx, 1);
    assert_eq!(len, 0);
    assert_eq!(path, session_dir.join("segment-000001.tlog"));

    // Case 2: uncompressed segment 1 exists
    fs::write(&path, b"hello").expect("write seg1");
    let (path2, idx2, len2) = resolve_active_segment(&session_dir).expect("uncompressed seg");
    assert_eq!(idx2, 1);
    assert_eq!(len2, 5);
    assert_eq!(path2, path);

    // Case 3: segment 1 is compressed; no uncompressed segment exists -> segment-000002.tlog
    let comp1 = session_dir.join("segment-000001.tlog.zst");
    compress_segment_file(&path, &comp1).expect("compress");
    let (path3, idx3, len3) = resolve_active_segment(&session_dir).expect("all compressed");
    assert_eq!(idx3, 2);
    assert_eq!(len3, 0);
    assert_eq!(path3, session_dir.join("segment-000002.tlog"));

    // Case 4: uncompressed segment 2 created
    fs::write(&path3, b"world!").expect("write seg2");
    let (path4, idx4, len4) = resolve_active_segment(&session_dir).expect("seg 2 active");
    assert_eq!(idx4, 2);
    assert_eq!(len4, 6);
    assert_eq!(path4, path3);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn get_segment_uncompressed_size_and_tail_offset() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("session-tail-offset");
    fs::create_dir_all(&session_dir).expect("mkdir");

    let raw_path = session_dir.join("segment-000001.tlog");
    let comp_path = session_dir.join("segment-000001.tlog.zst");
    let payload = b"1234567890".repeat(50); // 500 bytes
    fs::write(&raw_path, &payload).expect("write payload");

    compress_segment_file(&raw_path, &comp_path).expect("compress");

    let info = SegmentFileInfo {
        index: 1,
        path: comp_path,
        is_compressed: true,
        file_size: fs::metadata(session_dir.join("segment-000001.tlog.zst"))
            .expect("meta")
            .len(),
    };

    let size = get_segment_uncompressed_size(&info).expect("get size");
    assert_eq!(size, 500);

    // Request tail larger than available content: start_offset must equal total_uncompressed_bytes - combined.len()
    let (start_offset, tail) = read_multi_segment_tail(&session_dir, 500, 1000).expect("read tail");
    assert_eq!(start_offset, 0);
    assert_eq!(tail.len(), 500);

    // Request tail smaller than available content
    let (start_offset2, tail2) =
        read_multi_segment_tail(&session_dir, 500, 100).expect("read tail");
    assert_eq!(start_offset2, 400);
    assert_eq!(tail2.len(), 100);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn get_segment_uncompressed_size_fallback_to_uncompressed() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("session-fallback-size");
    fs::create_dir_all(&session_dir).expect("mkdir");

    let raw_path = session_dir.join("segment-000001.tlog");
    fs::write(&raw_path, b"fallback uncompressed content").expect("write raw");

    // Point info to compressed path that does not exist on disk
    let comp_path = session_dir.join("segment-000001.tlog.zst");
    assert!(!comp_path.exists());

    let info = SegmentFileInfo {
        index: 1,
        path: comp_path,
        is_compressed: true,
        file_size: 0,
    };

    let size = get_segment_uncompressed_size(&info).expect("fallback size");
    assert_eq!(size, 29);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn line_matches_query_ascii_and_unicode() {
    // Exact case match
    assert!(line_matches_query("Hello World", "World", "world", false));
    assert!(!line_matches_query("Hello World", "world", "world", false));

    // ASCII case insensitive match
    assert!(line_matches_query("Hello World", "WORLD", "world", true));
    assert!(line_matches_query(
        "cargo build --release",
        "BUILD",
        "build",
        true
    ));
    assert!(!line_matches_query(
        "short",
        "longer query",
        "longer query",
        true
    ));

    // Unicode case insensitive match
    assert!(line_matches_query(
        "Grüße aus Berlin",
        "GRÜSSE",
        "grüße",
        true
    ));
}

#[test]
fn read_segment_tail_uncompressed_seeking() {
    let temp_dir = unique_test_dir();
    let file_path = temp_dir.join("segment-000001.tlog");

    // Create 10_000 bytes with distinct head and tail patterns
    let mut data = vec![b'A'; 9_900];
    let tail_marker = b"TAIL_100_BYTES_END_MARKER_FOR_TESTING_SEEK_READS_0123456789abcdefghijklmnopqrstuvwxyz0123456789abcde";
    assert_eq!(tail_marker.len(), 100);
    data.extend_from_slice(tail_marker);
    assert_eq!(data.len(), 10_000);
    fs::write(&file_path, &data).expect("write data");

    let info = SegmentFileInfo {
        index: 1,
        path: file_path,
        is_compressed: false,
        file_size: 10_000,
    };

    // Seek read the trailing 100 bytes
    let tail = read_segment_tail_uncompressed(&info, 100).expect("read tail");
    assert_eq!(tail.len(), 100);
    assert_eq!(tail, &data[9_900..]);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn search_session_segments_multibyte_utf8() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("session-multibyte-search");
    fs::create_dir_all(&session_dir).expect("mkdir");

    // Segment 1 (uncompressed): contains emojis and Japanese
    let seg1_path = session_dir.join("segment-000001.tlog");
    fs::write(
        &seg1_path,
        "Line 1: \x1b[32m🚀 Starting engine\x1b[0m\nLine 2: 🦀 Rust 1.85 release\nLine 3: 日本語のログ出力\n",
    )
    .expect("write seg1");

    // Segment 2 (compressed): contains Unicode symbols and French
    let seg2_raw = session_dir.join("segment-000002.tlog");
    fs::write(
        &seg2_raw,
        "Line 4: ✨ Sparkles and stars\nLine 5: Café au lait\nLine 6: 🚀 Second launch\n",
    )
    .expect("write seg2 raw");
    let seg2_comp = session_dir.join("segment-000002.tlog.zst");
    compress_segment_file(&seg2_raw, &seg2_comp).expect("compress seg2");

    // Search for emoji
    let rocket_hits = search_session_segments(&session_dir, "🚀", false).expect("search rocket");
    assert_eq!(rocket_hits.len(), 2);
    assert_eq!(rocket_hits[0].segment_index, 1);
    assert_eq!(rocket_hits[0].line_number, 1);
    assert!(rocket_hits[0].line_text.contains("🚀 Starting engine"));
    assert_eq!(rocket_hits[1].segment_index, 2);
    assert_eq!(rocket_hits[1].line_number, 3);
    assert!(rocket_hits[1].line_text.contains("🚀 Second launch"));

    // Search for crab emoji
    let crab_hits = search_session_segments(&session_dir, "🦀", false).expect("search crab");
    assert_eq!(crab_hits.len(), 1);
    assert_eq!(crab_hits[0].segment_index, 1);
    assert_eq!(crab_hits[0].line_number, 2);
    assert!(crab_hits[0].line_text.contains("🦀 Rust 1.85 release"));

    // Search for Japanese characters
    let jp_hits = search_session_segments(&session_dir, "日本語", false).expect("search japanese");
    assert_eq!(jp_hits.len(), 1);
    assert_eq!(jp_hits[0].segment_index, 1);
    assert_eq!(jp_hits[0].line_number, 3);
    assert!(jp_hits[0].line_text.contains("日本語のログ出力"));

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn legacy_log_migration_cleans_up_on_error() {
    let temp_dir = unique_test_dir();
    let legacy_log = temp_dir.join("session-err-123.log");
    fs::write(&legacy_log, b"some initial content").expect("write log");

    let session_dir = temp_dir.join("sessions").join("session-err");

    // Zero segment size should error immediately
    let res = migrate_legacy_session_log(&legacy_log, &session_dir, 0);
    assert!(res.is_err());

    // Verify no stray .tmp-migrate directories were leaked in parent directory
    let parent = session_dir.parent().unwrap();
    if parent.exists() {
        for entry in fs::read_dir(parent).expect("read parent") {
            let entry = entry.expect("entry");
            let name = entry.file_name().to_string_lossy().to_string();
            assert!(
                !name.starts_with(".tmp-migrate-"),
                "stray temp migration dir found: {name}"
            );
        }
    }

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn line_matches_query_empty_query_no_panic() {
    assert!(line_matches_query("hello world", "", "", false));
    assert!(line_matches_query("hello world", "", "", true));
    assert!(line_matches_query("日本語", "", "", false));
    assert!(line_matches_query("日本語", "", "", true));
    assert!(line_matches_query("", "", "", false));
    assert!(line_matches_query("", "", "", true));
}

#[test]
fn resolve_active_segment_ignores_historical_uncompressed() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("sessions").join("session-active-test");
    fs::create_dir_all(&session_dir).expect("create session dir");

    // Segment 1 is uncompressed
    let seg1_path = session_dir.join("segment-000001.tlog");
    fs::write(&seg1_path, b"historical uncompressed").expect("write seg1");

    // Segment 2 is compressed
    let seg2_raw = session_dir.join("segment-000002.tlog");
    fs::write(&seg2_raw, b"historical segment 2").expect("write seg2 raw");
    let seg2_comp = session_dir.join("segment-000002.tlog.zst");
    compress_segment_file(&seg2_raw, &seg2_comp).expect("compress seg2");

    // Since the latest segment (2) is compressed, active segment must be 3 with 0 bytes
    let (active_path, index, bytes) =
        resolve_active_segment(&session_dir).expect("resolve active segment");
    assert_eq!(index, 3);
    assert_eq!(bytes, 0);
    assert_eq!(active_path, session_dir.join("segment-000003.tlog"));

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn read_segment_tail_uncompressed_fallback_clamping() {
    let temp_dir = unique_test_dir();
    let raw_path = temp_dir.join("segment-000001.tlog");
    let comp_path = temp_dir.join("segment-000001.tlog.zst");

    let test_data = b"0123456789".repeat(100); // 1000 bytes
    fs::write(&raw_path, &test_data).expect("write raw");
    compress_segment_file(&raw_path, &comp_path).expect("compress");

    // Construct SegmentFileInfo pointing to raw_path (marked uncompressed),
    // simulating concurrent compression where the raw file was removed.
    let info = SegmentFileInfo {
        index: 1,
        path: raw_path.clone(),
        is_compressed: false,
        file_size: test_data.len() as u64,
    };
    assert!(!raw_path.exists());
    assert!(comp_path.exists());

    // Request tail of 25 bytes
    let tail = read_segment_tail_uncompressed(&info, 25).expect("read tail");
    assert_eq!(tail.len(), 25);
    assert_eq!(tail, &test_data[test_data.len() - 25..]);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn line_matches_query_ascii_on_mixed_unicode_line() {
    let mixed_line = "┌── [OK] 🚀 error occurred ──┐";
    assert!(line_matches_query(mixed_line, "error", "error", false));
    assert!(line_matches_query(mixed_line, "ERROR", "error", true));
    assert!(line_matches_query(mixed_line, "ok", "ok", true));
    assert!(!line_matches_query(mixed_line, "missing", "missing", true));
}

#[test]
fn search_session_segments_hit_cap() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("sessions").join("session-cap");
    fs::create_dir_all(&session_dir).expect("create session dir");

    // Create 12,000 lines of matching text
    let mut data = Vec::new();
    for i in 0..12_000 {
        data.extend_from_slice(format!("match line {i}\n").as_bytes());
    }
    let seg1_path = session_dir.join("segment-000001.tlog");
    fs::write(&seg1_path, &data).expect("write seg1");

    let hits = search_session_segments(&session_dir, "match", false).expect("search");
    assert_eq!(hits.len(), MAX_SEARCH_HITS);
    assert_eq!(hits[0].line_number, 1);
    assert_eq!(hits[MAX_SEARCH_HITS - 1].line_number, MAX_SEARCH_HITS);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn search_session_segments_multibyte_across_compressed_and_uncompressed() {
    let temp_dir = unique_test_dir();
    let session_dir = temp_dir.join("sessions").join("session-multibyte");
    fs::create_dir_all(&session_dir).expect("create session dir");

    // Segment 1: compressed with emojis and CJK characters
    let seg1_path = session_dir.join("segment-000001.tlog");
    let comp1_path = session_dir.join("segment-000001.tlog.zst");
    let seg1_data =
        "line 1: standard ascii\nline 2: 🚀 Rocket launch in progress\nline 3: こんにちは 世界\n";
    fs::write(&seg1_path, seg1_data).expect("write seg1");
    compress_segment_file(&seg1_path, &comp1_path).expect("compress seg1");

    // Segment 2: raw uncompressed with matching emojis and Unicode symbols
    let seg2_path = session_dir.join("segment-000002.tlog");
    let seg2_data = "line 4: ✨ Sparkles and 🚀 Rocket landing\nline 5: plain line\n";
    fs::write(&seg2_path, seg2_data).expect("write seg2");

    // Search for emoji query
    let hits = search_session_segments(&session_dir, "🚀", false).expect("search emoji");
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].segment_index, 1);
    assert_eq!(hits[0].line_number, 2);
    assert!(hits[0].line_text.contains("Rocket launch"));
    assert_eq!(hits[1].segment_index, 2);
    assert_eq!(hits[1].line_number, 1);
    assert!(hits[1].line_text.contains("Rocket landing"));

    // Search for CJK characters
    let cjk_hits = search_session_segments(&session_dir, "こんにちは", false).expect("search CJK");
    assert_eq!(cjk_hits.len(), 1);
    assert_eq!(cjk_hits[0].segment_index, 1);
    assert_eq!(cjk_hits[0].line_number, 3);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn burst_write_oversized_segment_compression_and_reading() {
    let temp_dir = unique_test_dir();
    let raw_path = temp_dir.join("segment-000001.tlog");
    let comp_path = temp_dir.join("segment-000001.tlog.zst");

    // Write a burst of data that slightly exceeds 8 MiB (8 MiB + 64 KiB = 8,454,144 bytes)
    let extra_bytes = 64 * 1024;
    let total_size = (DEFAULT_SEGMENT_SIZE_BYTES as usize) + extra_bytes;
    let pattern = b"0123456789abcdef";
    let full_data = pattern
        .iter()
        .copied()
        .cycle()
        .take(total_size)
        .collect::<Vec<u8>>();

    fs::write(&raw_path, &full_data).expect("write oversized raw segment");
    compress_segment_file(&raw_path, &comp_path).expect("compress oversized segment");

    let info = SegmentFileInfo {
        index: 1,
        path: comp_path.clone(),
        is_compressed: true,
        file_size: fs::metadata(&comp_path).expect("meta").len(),
    };

    let discovered_size = get_segment_uncompressed_size(&info).expect("discovered size");
    assert_eq!(discovered_size, total_size as u64);

    let decompressed = read_segment_uncompressed(&info).expect("decompressed");
    assert_eq!(decompressed.len(), total_size);
    assert_eq!(decompressed, full_data);

    let tail_slice = read_segment_tail(&info, 128).expect("read tail");
    assert_eq!(tail_slice.len(), 128);
    assert_eq!(tail_slice, &full_data[total_size - 128..]);

    let _ = fs::remove_dir_all(&temp_dir);
}
