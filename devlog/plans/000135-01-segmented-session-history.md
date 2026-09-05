# Plan: Segmented Session History with Rolling 8 MiB zstd Logs

## Thinking

### Problem & Motivation
Currently, Triage caps session output logs at 16 MiB (`MAX_SESSION_LOG_BYTES`) in a single file (`session-<id>-<birth_pid>.log`). When the log outgrows 16 MiB, `OutputState::trim_log_if_oversized` truncates the oldest 4 MiB, keeping only the trailing 12 MiB (`SESSION_LOG_RETAIN_BYTES`). For long-running sessions, this destroys early history, build logs, and diagnostic traces.

### Goals
1. **Unbounded Historical Storage**: Store complete session history across segmented files (`segment-NNNNNN.tlog` and `segment-NNNNNN.tlog.zst`).
2. **Fixed Segment Sizing**: Bound individual uncompressed segment files to 8 MiB.
3. **Background zstd Compression**: Compress rotated segments asynchronously to `.tlog.zst`, reducing storage footprint by 75-85%.
4. **Zero Hot-Path Overhead**: The live PTY read/write loop continues writing raw, uncompressed bytes to the active `.tlog` descriptor without database locks or serialization overhead.
5. **Cross-Segment Snapshot & Replay Assembly**: `read_raw_output_tail` (1 MiB snapshot history) and `read_replay_tail` (16 MiB terminal replay) must transparently decompress and stitch across multiple segment files when an active segment has less data than requested.
6. **Handover & Recovery Safety**: Ensure zero-downtime daemon handover and crash recovery maintain exact on-disk byte accounting without locking conflicts.
7. **On-Demand Search**: Implement parallel streaming zstd search with ANSI stripping across session segments.
8. **Legacy Migration**: Migrate legacy unsegmented `session-*.log` and `sessions.json` on startup.

### Architecture

#### Directory Structure
```
~/.local/state/triage/
  ├── sessions.json                     # Session manifest with segment catalog
  └── sessions/
      └── <session_id>/
          ├── segment-000001.tlog.zst   # Closed compressed segment
          ├── segment-000002.tlog.zst   # Closed compressed segment
          └── segment-000003.tlog       # Active uncompressed append segment
```

#### Segment Rotation & Lifecycle
1. Active segment is written directly by the session actor.
2. When the active file size reaches 8 MiB (8 * 1024 * 1024 bytes), the actor:
   - Rotates the active file handle to `segment-(N+1).tlog`.
   - Sends a compression job for `segment-N.tlog` to a background worker.
3. The background compression worker:
   - Compresses `segment-N.tlog` to `segment-N.tlog.zst.tmp`.
   - Atomically renames `segment-N.tlog.zst.tmp` to `segment-N.tlog.zst`.
   - Updates manifest segment metadata (`is_compressed = true`).
   - Deletes `segment-N.tlog`.
4. Readers check for `segment-N.tlog.zst` first, falling back to `segment-N.tlog` if compression is in flight.

## Plan

### Step 1: Add zstd Dependency
- Add `zstd = "0.13"` to `crates/triaged/Cargo.toml` and workspace `Cargo.toml`.

### Step 2: Implement Storage & Segment Types
- Define `SegmentMeta` tracking segment index, uncompressed size, compressed size, file path, sequence bounds (`start_seq..end_seq`), and timestamps.
- Implement segment manager helpers:
  - `rotate_active_segment`
  - `compress_segment_file` (using zstd level 3)
  - `read_segment_bytes` (handles both `.tlog` and `.tlog.zst`)
  - `read_multi_segment_tail` (reads up to N bytes across segment boundaries chronologically)

### Step 3: Update OutputState and SessionActor
- Update `OutputState` to write to the active segment within `sessions/<session_id>/`.
- Hook segment rotation at 8 MiB limit into `OutputState::ingest`.
- Replace single-file `read_raw_output_tail` and `read_replay_tail` with multi-segment readers.

### Step 4: Background Compression Worker
- Create a background compression worker loop in `triaged` to process closed segments without blocking PTY actor threads.

### Step 5: Legacy Log Migration
- On startup, detect legacy unsegmented `session-*.log` files and slice them into 8 MiB segments within `sessions/<session_id>/`.

### Step 6: On-Demand Search
- Implement `search_session_logs` streaming search with ANSI sequence filtering across `.tlog` and `.tlog.zst` files.

### Step 7: Tests & Validation
- Unit tests for segment rotation, zstd compression, cross-segment tail assembly, and search.
- Integration tests for restore, resize, and zero-downtime handover across segmented logs.
