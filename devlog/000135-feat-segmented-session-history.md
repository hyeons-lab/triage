# 000135: feat/segmented-session-history

**Agent:** Antigravity (gemini-3.7-flash) @ triage branch feat/segmented-session-history
**Agent (2026-09-04T21:31-0700):** Antigravity (gemini-3.8-flash) @ triage branch feat/segmented-session-history

## Intent
Implement complete session history retention using rolling 8 MiB segment log files with background zstd compression, transparent cross-segment snapshot/replay assembly, legacy log migration, and on-demand search.

## What Changed
- 2026-09-04T20:40-0700 `Cargo.toml`, `crates/triaged/Cargo.toml`, `Cargo.lock`: Added `zstd = "0.13"` dependency to the Cargo workspace and `triaged` crate.
- 2026-09-04T20:40-0700 `crates/triaged/src/lib.rs`: Exposed `storage` module with segment metadata, background compression worker, search engine, and migration logic.
- 2026-09-04T20:40-0700 `crates/triaged/src/storage.rs`: Added segment file naming and index parsers, background `CompressionWorker`, multi-segment snapshot and replay tail readers, streaming ANSI escape stripper, on-demand search engine, and legacy `.log` migration.
- 2026-09-04T20:40-0700 `crates/triaged/src/storage_tests.rs`: Comprehensive test suite covering segment compression, worker queuing, multi-segment tail stitching, ANSI stripping and search, and legacy log migration.
- 2026-09-04T20:40-0700 `crates/triaged/src/session.rs`: Integrated 8 MiB segment rotation into `OutputState`, multi-segment snapshot and replay assembly, background compression dispatch from `SessionActor`, legacy session migration on restore, directory-aware log removal, and exposed `search_session_logs`/`search_all_sessions`.
- 2026-09-04T21:16-0700 `crates/triaged/src/storage.rs`: Resolved worker shutdown hang with `WorkerMessage::Stop` and thread join; drained remaining jobs on teardown; preserved multi-byte UTF-8 in `strip_ansi_escapes`; extracted `resolve_active_segment` and `get_segment_uncompressed_size` with O(1) pledged frame header inspection; deterministic fallback path generation; PID-isolated temporary files and directories with atomic renames; zero-allocation ASCII search in `line_matches_query`.
- 2026-09-04T21:16-0700 `crates/triaged/src/session.rs`: Adopted `resolve_active_segment` in `spawn_adopted_pty_runtime` and `output_state_for_log`; logged warning on worker channel failure; removed redundant `log_path` from `ActorState` and `PtyRuntime`; enhanced `purge_orphaned_session_logs` to reclaim `.log.migrated` files and handle empty directories; used `line_matches_query` in `search_session_logs`.
- 2026-09-04T21:16-0700 `crates/triaged/src/handover.rs`: Used `resolve_active_segment` in `rename_recovered_session`.
- 2026-09-04T21:16-0700 `crates/triaged/src/storage_tests.rs`: Added comprehensive unit tests covering active segment resolution, replay tail memory bounding, fallback sizing, search query matching, and migrated log purging.
- 2026-09-04T22:05-0700 `crates/triaged/src/storage.rs`: Added `read_segment_tail_uncompressed` using direct `SeekFrom::Start` to avoid whole-file loading on uncompressed tail reads; added `read_segment_tail` helper; optimized `read_multi_segment_tail` and `read_multi_segment_replay_tail`; validated `segment_size > 0` in `migrate_legacy_session_log`.
- 2026-09-04T22:05-0700 `crates/triaged/src/storage_tests.rs`: Added unit tests for seek-based tail reading, multibyte UTF-8 and emoji searching across segments, and migration cleanup on error.
- 2026-09-04T22:05-0700 `devlog/000135-feat-segmented-session-history.md`: Clarified sequential on-demand search documentation.
- 2026-09-05T07:30-0700 `crates/triaged/src/handover.rs`: Defined `DAEMON_MAX_OPEN_FILES` (10240) and added `raise_fd_limit()` to increase `RLIMIT_NOFILE` soft limit to hard limit, avoiding descriptor exhaustion during multi-session handovers.
- 2026-09-05T07:30-0700 `crates/triaged/src/ipc.rs`: Called `raise_fd_limit()` in `handle_handover_server` before serializing live sessions, ensuring existing daemons can safely duplicate descriptors across handover.
- 2026-09-05T07:30-0700 `crates/triaged/src/main.rs`: Called `raise_fd_limit()` at startup before session restoration and service initialization.
- 2026-09-05T07:30-0700 `crates/triaged/src/service.rs`: Configured macOS LaunchAgent `SoftResourceLimits.NumberOfFiles` to `DAEMON_MAX_OPEN_FILES` (10240); moved constant assertion to a const block.
- 2026-09-05T07:30-0700 `crates/triaged/src/session.rs`: Implemented `original_session_id()` in `adopt_one_session()` to allow inherited live sessions to reclaim canonical base IDs instead of accumulating `-recovered-<pid>` suffixes; implemented `logs_belong_to_same_session()` so segmented logs are recognized across rotation and handover; added bounded timeout (1500ms with process termination) to `git_raw_output` to prevent daemon startup stalls on inaccessible filesystems; added cleanup of stale recovery placeholders.
- 2026-09-05T07:30-0700 `crates/triaged/src/storage.rs`: Propagated listing and read errors in `read_multi_segment_tail` instead of returning empty tails on transient I/O errors; documented failure-handling semantics.
- 2026-09-05T07:30-0700 `crates/triaged/src/storage_tests.rs`: Updated unit test callers of `read_multi_segment_tail` to handle `Result`.
- 2026-09-05T07:30-0700 `flutter/triage_client/lib/widgets/terminal_pane_web.dart`: Restored view-fit notifications (`widget.onViewFit`) for cached web terminal containers, triggered initial content write in post-frame callback, and safe terminal reset on clear.
- 2026-09-05T07:30-0700 `flutter/triage_client/lib/terminal/terminal_store.dart`: Bounded regex matching for unsupported private CSI escape sequences to the tail buffer slice, preventing regex stalls on multi-megabyte payloads.

## Decisions
- 2026-09-04T20:16-0700 8 MiB Segment Size: Rotate session log files at 8 MiB boundaries to balance mmap/IO performance, low file count, and fast decompression times.
- 2026-09-04T20:16-0700 Raw Uncompressed Active Segments: The live PTY output stream writes raw uncompressed bytes directly to active segment files without per-chunk serialization framing or database lock contention on the actor hot path.
- 2026-09-04T20:16-0700 Asynchronous zstd Compression: Closed segments are compressed to `.tlog.zst` in the background with atomic temporary file replacement (`.tlog.zst.tmp` to `.tlog.zst`) and reader fallback.
- 2026-09-04T20:16-0700 Multi-Segment Snapshot Stitching: Snapshot and replay readers assemble requested history tails seamlessly across active `.tlog` and compressed `.tlog.zst` files when the active segment has less than the requested cap.
- 2026-09-04T20:16-0700 On-Demand Segment Search: Search queries decompress and scan candidate segments sequentially on demand with streaming ANSI escape stripping rather than maintaining a heavy inverted index.
- 2026-09-04T20:30-0700 Safe Legacy Log Slicing: Keep `.log.migrated` marker during migration to guarantee crash resilience and non-destructive fallback if migration is interrupted.
- 2026-09-04T21:16-0700 Active Segment Resolution Strategy: Target the latest uncompressed segment if present, or `highest_index + 1` with an uncompressed segment of 0 bytes if all existing segments are compressed, preventing segment collision on restore.
- 2026-09-04T21:16-0700 O(1) Replay Tail Sizing: Pledge exact uncompressed byte size into the zstd frame header during compression, enabling constant-time stream size calculation across historical segments without decompressing into `io::sink()`.
- 2026-09-04T21:16-0700 Process-Isolated Atomic Migration: Stage legacy migration into `.tmp-migrate-<pid>-<session>` before renaming to prevent partial directory state on crash.
- 2026-09-04T22:05-0700 Seek-Based Uncompressed Tail Reading: For uncompressed active segments, seek directly to the tail slice on disk rather than reading the entire 8 MiB segment into memory, minimizing heap churn and I/O.
- 2026-09-05T07:30-0700 Canonical Session Recovery Reclaiming: When an inherited session bears a `-recovered-<pid>` suffix and the canonical base session is either historical or missing, adopt it directly under its canonical ID so persistent user custom labels and live shell attachments survive daemon handovers seamlessly.
- 2026-09-05T07:30-0700 Proactive Soft File Limit Elevation: Raise the soft `RLIMIT_NOFILE` to 10240 both at daemon startup and immediately upon receiving handover requests, ensuring `dup_cloexec` never fails with `EMFILE` when duplicating dozens of master PTYs during zero-downtime transfers.
- 2026-09-05T07:30-0700 Bounded Git Context Probing: Execute Git child commands with a strict 1500ms timeout and explicit kill/wait reap logic so that inaccessible directories or hung filesystems cannot wedge the supervisor event loop.

## Progress
- [x] Create worktree `worktrees/segmented-session-history` and branch `feat/segmented-session-history`
- [x] Create branch devlog and plan file `000135-01-segmented-session-history.md`
- [x] Add `zstd` dependency to Cargo workspace
- [x] Implement segmented log storage module and types
- [x] Wire segment rotation and multi-segment tail assembly into `OutputState`
- [x] Implement background compression worker
- [x] Add legacy log migration
- [x] Implement on-demand search
- [x] Add test suite and verify format, clippy, and unit tests
- [x] Execute 4-round review-fix loop until diff is verified clean and approved for merge
- [x] Address PR #158 review feedback and resolve review threads
- [x] Diagnose and fix recovery duplicate cascade, raised fd limit, and restored muse-triage session

## Commits
- 72a25aa: feat(storage): implement rolling 8 MiB segment logs with background zstd compression
- e674167: fix(storage): harden segment rotation, atomic migration, and zero-allocation search
- 540955b: fix(storage): optimize uncompressed segment tail reads and address review feedback
- HEAD: fix(daemon): resolve handover recovery duplication, raise file descriptor limits, and bound git timeouts

