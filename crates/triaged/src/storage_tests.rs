use std::fs::{self, File};
use std::io::Write;
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
    let (start_offset, tail) = read_multi_segment_tail(&session_dir, total_bytes, 800);
    assert_eq!(start_offset, 1700);
    assert_eq!(tail.len(), 800);
    assert_eq!(&tail[..300], &vec![b'B'; 300][..]);
    assert_eq!(&tail[300..], &vec![b'C'; 500][..]);

    // Request tail of 2000 bytes: should get 500 bytes of 'A', 1000 bytes of 'B', 500 bytes of 'C'
    let (start_offset, tail) = read_multi_segment_tail(&session_dir, total_bytes, 2000);
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

    let tail = read_multi_segment_tail(&session_dir, 2560, 2560);
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

    tx.send(CompressionJob {
        raw_path: raw_path.clone(),
        compressed_path: compressed_path.clone(),
    })
    .expect("send job");

    // Wait for worker to finish job
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while !compressed_path.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    assert!(compressed_path.exists());
    assert!(!raw_path.exists());

    let _ = fs::remove_dir_all(&temp_dir);
}
