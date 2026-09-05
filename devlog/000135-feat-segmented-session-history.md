# 000135: feat/segmented-session-history

**Agent:** Antigravity (gemini-3.7-flash) @ triage branch feat/segmented-session-history

## Intent
Implement complete session history retention using rolling 8 MiB segment log files with background zstd compression, transparent cross-segment snapshot/replay assembly, legacy log migration, and on-demand search.

## What Changed
- 2026-09-04T20:40-0700 `Cargo.toml`, `crates/triaged/Cargo.toml`, `Cargo.lock`: Added `zstd = "0.13"` dependency to the Cargo workspace and `triaged` crate.
- 2026-09-04T20:40-0700 `crates/triaged/src/lib.rs`: Exposed `storage` module with segment metadata, background compression worker, search engine, and migration logic.
- 2026-09-04T20:40-0700 `crates/triaged/src/storage.rs`: Added segment file naming and index parsers, background `CompressionWorker`, multi-segment snapshot and replay tail readers, streaming ANSI escape stripper, parallel search engine, and legacy `.log` migration.
- 2026-09-04T20:40-0700 `crates/triaged/src/storage_tests.rs`: Comprehensive test suite covering segment compression, worker queuing, multi-segment tail stitching, ANSI stripping and search, and legacy log migration.
- 2026-09-04T20:40-0700 `crates/triaged/src/session.rs`: Integrated 8 MiB segment rotation into `OutputState`, multi-segment snapshot and replay assembly, background compression dispatch from `SessionActor`, legacy session migration on restore, directory-aware log removal, and exposed `search_session_logs`/`search_all_sessions`.

## Decisions
- 2026-09-04T20:16-0700 8 MiB Segment Size: Rotate session log files at 8 MiB boundaries to balance mmap/IO performance, low file count, and fast decompression times.
- 2026-09-04T20:16-0700 Raw Uncompressed Active Segments: The live PTY output stream writes raw uncompressed bytes directly to active segment files without per-chunk serialization framing or database lock contention on the actor hot path.
- 2026-09-04T20:16-0700 Asynchronous zstd Compression: Closed segments are compressed to `.tlog.zst` in the background with atomic temporary file replacement (`.tlog.zst.tmp` to `.tlog.zst`) and reader fallback.
- 2026-09-04T20:16-0700 Multi-Segment Snapshot Stitching: Snapshot and replay readers assemble requested history tails seamlessly across active `.tlog` and compressed `.tlog.zst` files when the active segment has less than the requested cap.
- 2026-09-04T20:16-0700 On-Demand Parallel Search: Search queries decompress and scan candidate segments in parallel with streaming ANSI escape stripping rather than maintaining a heavy inverted index.
- 2026-09-04T20:30-0700 Safe Legacy Log Slicing: Keep `.log.migrated` marker during migration to guarantee crash resilience and non-destructive fallback if migration is interrupted.

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

## Commits
- HEAD: feat(storage): implement rolling 8 MiB segment logs with background zstd compression

