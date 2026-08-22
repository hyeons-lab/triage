# 000128 fix/terminal-newline-staircase

**Agent:** Antigravity (Gemini 3.7 Flash) @ triage branch fix/terminal-newline-staircase

## Intent

Fix terminal newline staircasing for CLI tool and command output in raw-mode sessions while preserving relative cursor movement escape sequences (`\x1b[...D`, `\x1b[...C`) for `agy` logo banners and spinner animations.
Plan: [plans/000128-01-fix-terminal-newline-staircase.md](plans/000128-01-fix-terminal-newline-staircase.md).

## What Changed

- 2026-08-21T10:05-0700 Created branch, worktree, and plan to implement smart newline translation in `triaged` and `triage_client`.
- 2026-08-21T10:09-0700 Implemented `is_followed_by_relative_cursor_movement` and `translate_newlines` in `crates/triaged/src/session.rs` for `OutputState::ingest` and `OutputState::advance_replayed_bytes`.
- 2026-08-21T10:09-0700 Implemented `_isFollowedByRelativeCursorMovement` and `_translateNewlines` in `flutter/triage_client/lib/terminal/terminal_store.dart` with cross-chunk `_pendingCarriageReturn` tracking and Mode 2026 synchronized output passthrough.
- 2026-08-21T10:09-0700 Added unit tests in Rust and Flutter and verified the entire workspace test suite passes (276 Rust tests, 341 Flutter tests).
- 2026-08-21T16:12-0700 Added `schedule`, `manage_task`, `manage_tasks`, `task_status`, `get_task_status`, `list_tasks`, and `refactor_tool` to `is_read_only_tool` in `crates/triage-core/src/judge_rules.rs`.
- 2026-08-21T16:12-0700 Updated `crates/triage-hook/src/main.rs` to support string argument payloads in `extract_path`, skip file path extraction on command tools, and generate comprehensive permission overrides for file and tool formats (including expanded and contracted home directory paths).
- 2026-08-21T17:30-0700 Fixed path expansion and contraction boundary checks in `crates/triage-hook/src/main.rs` to ensure matching on exact path or directory separator boundaries (`~`, `~/`, `~\`, and `$HOME`, `$HOME/`, `$HOME\`).
- 2026-08-21T17:30-0700 Optimized `_isFollowedByRelativeCursorMovement` in `flutter/triage_client/lib/terminal/terminal_store.dart` to inspect code units directly without allocating substring slices.
- 2026-08-21T17:30-0700 Hardened cross-chunk streaming in `crates/triaged/src/session.rs` and `flutter/triage_client/lib/terminal/terminal_store.dart` by statefully tracking `pending_carriage_return` and carrying incomplete trailing escape sequences (`\n\x1b...`) across chunk boundaries so split CRLFs and relative moves are preserved.
- 2026-08-21T17:30-0700 Added unit tests covering path expansion/contraction boundaries, split chunk CRLFs, and split chunk CSI relative movements across both Rust and Flutter.
- 2026-08-21T17:40-0700 Restricted `is_read_only_tool` in `crates/triage-core/src/judge_rules.rs` to exclude interactive / action-taking tools (`manage_task`, `manage_tasks`), keeping only dedicated status queries (`task_status`, `get_task_status`, `list_tasks`).
- 2026-08-21T17:40-0700 Sanitized wildcard directory permission overrides in `crates/triage-hook/src/main.rs` via `is_safe_wildcard_dir` to explicitly forbid parent wildcard grants on root, `/Users`, `/home`, `~`, `$HOME`, and dot paths, and excluded network URLs from filesystem path overrides.
- 2026-08-21T17:40-0700 Streamlined slice prefix inspection in `is_followed_by_relative_cursor_movement` and added `!bytes.contains(&b'\n')` fast path in `crates/triaged/src/session.rs`.
- 2026-08-21T19:38-0700 Filtered out non-tool message envelope discriminators (`message`, `text`, `thought`, `ping`, `assistant`, `user`) on the `"type"` fallback in `extract_tool_info` and allowed dot-relative paths (`./...`, `../...`, `.env`) in generic JSON object extraction in `crates/triage-hook/src/main.rs`.
- 2026-08-21T19:42-0700 Excluded `schedule` from `is_read_only_tool` in `crates/triage-core/src/judge_rules.rs`, broadened message envelope filters (`error`, `progress`, `status`, `notification`, `heartbeat`), normalized Windows path separators in tilde expansions, updated `_pendingCarriageReturn` tracking during synchronized output in Flutter, and eliminated buffer reallocation when merging chunk fragments in `OutputState`.
- 2026-08-21T19:45-0700 Added `flush_pending_translated_bytes()` to idle actor timeout ticks in `crates/triaged/src/session.rs` to ensure partial trailing escapes are displayed when processes pause waiting for user input.
- 2026-08-21T19:47-0700 Filtered standalone `.` and `..` directory references in `extract_path` across bare string and named key argument payloads in `crates/triage-hook/src/main.rs`.
- 2026-08-21T19:50-0700 Rejected private/experimental CSI parameter bytes (`?`, `>`, `<`, `=`) in relative cursor detection, synchronized `MAX_CARRY_ESCAPE_LEN = 32` bounded carry constants across Rust and Dart, and replaced temporary vector moves with in-place buffer draining in `OutputState`.
- 2026-08-21T19:52-0700 Added ASCII case-insensitive home matching on Windows in `crates/triage-hook/src/main.rs` and added pure throughput hot-path fast bypass in `advance_translated_bytes` in `crates/triaged/src/session.rs`.
- 2026-08-21T19:54-0700 Made URL scheme detection in `crates/triage-hook/src/main.rs` case-insensitive (`http://`, `https://`, `ws://`, `wss://`).
- 2026-08-21T19:56-0700 Added `payload`, `data`, and `body` to `raw_args` lookups in `crates/triage-hook/src/main.rs` and added `!bytes.contains(&b'\n')` fast return in `translate_newlines_with_state` in `crates/triaged/src/session.rs`.
- 2026-08-21T19:58-0700 Rejected private CSI parameter bytes (`?`, `>`, `<`, `=`) in `is_partial_relative_cursor_prefix` in `crates/triaged/src/session.rs`.
- 2026-08-21T20:01-0700 Stripped `file://` scheme prefixes in `crates/triage-hook/src/main.rs` and reused vector allocation in `flush_pending_translated_bytes` via `clear()` in `crates/triaged/src/session.rs`.

## Decisions

2026-08-21T10:05-0700 Use pattern-based relative cursor movement detection:
- If `\n` is followed by CSI cursor horizontal relative moves (`\x1b[<N>D` / `\x1b[<N>C`), preserve `\n` as bare `\n` to keep the current cursor column index intact for relative adjustments (`agy` logo / spinner).
- For all other `\n` (followed by text, whitespace, digits, newlines, or non-relative escape sequences like SGR colors `\x1b[...m`), translate `\n` to `\r\n` so CLI output (e.g. `cera-cli`, `llama-cli`, `println!`, JSON) starts at column 0 without staircasing.

2026-08-21T17:30-0700 Stateful multi-chunk carry for newline translation:
- Hold back trailing incomplete escape sequences starting after bare LF (`\n\x1b...`) until the next chunk arrives or watchdog flushes, avoiding premature CR injection when CSI relative movement commands (`CSI <N>D/C`) are split across PTY reads or WebSocket frames.
- Track `pending_carriage_return` across chunk boundaries to eliminate duplicate `\r` when CRLF is split across chunks (`\r` at end of chunk 1, `\n` at start of chunk 2).

2026-08-21T17:40-0700 Strict permission override scoping:
- Never generate `{dir}/*` wildcard permission overrides for root or user account homes (`/Users`, `/home`, `~`, `$HOME`), strictly confining wildcard permissions to project subdirectories.
- Keep interactive tools with input injection (`manage_task`) out of `is_read_only_tool`.

## Commits

- cbfb07f — fix(triaged): eliminate terminal newline staircasing while preserving relative cursor movements
- b325c51 — fix(judge): expand read-only tool coverage and path permission overrides in triage-hook
- a4f0776 — fix(hook): support nested subagent payloads and directory wildcard permission overrides
- 0fe51d2 — fix(triaged): harden cross-chunk newline streaming and path boundary overrides
- 790fe5e — fix(judge): restrict read-only tool scoping and sanitize wildcard directory overrides
- 7e48f37 — fix(hook): filter message envelope discriminators and permit dot-relative paths
- 6de3c75 — fix(judge): harden tool scoping, path separator normalization, and streaming carries
- 240e9dd — fix(triaged): flush trailing escape carry buffer on idle actor ticks
- 112d4e0 — fix(hook): filter standalone dot references across string and key payloads
- 79d634b — fix(triaged): reject private CSI markers and synchronize carry bounds across Rust and Dart
- 78f95a4 — fix(triaged): optimize zero-escape throughput and handle Windows home case-insensitivity
- 8e2185e — fix(hook): match URL schemes case-insensitively for path overrides
- 6d9a468 — fix(hook): expand raw_args lookup keys and optimize newline translation exit
- c5d95d7 — fix(triaged): reject private CSI markers in partial prefix detection
- HEAD — fix(hook): strip file scheme prefixes and reuse escape carry capacity
