# feat/zero-downtime-handover

## Agent

- Antigravity, 2026-05-24T17:48-0700

## Intent

- Provide true zero-downtime upgrades of the `triaged` daemon on Unix-like systems (including WSL/Linux) by transferring active PTY sessions and network listening sockets without interrupting running shell processes.

## What Changed

- Added Unix-specific dependency `libc = "0.2"` to `Cargo.toml`.
- Created `handover.rs` implementing low-level `SCM_RIGHTS` file descriptor passing using raw libc FFI (`sendmsg`/`recvmsg`), supporting both PTY master descriptors and bound TCP listener sockets.
- Designed and implemented a strict, chronological Three-Phase Sync Protocol:
  - Phase 1 (Transfer): Old daemon serializes active session metadata and passes active PTY + TCP listener FDs to the new daemon over a Unix Domain Socket, then waits.
  - Phase 2 (Adoption & Sync): New daemon adopts FDs, reconstructs memory structures/terminal screens via log-replay, and writes a `SYNC_ADOPTED` (`0x01`) byte back.
  - Phase 3 (Teardown & Sync): Old daemon receives `0x01`, stops supervision, drops session references (closing its FDs), writes a `SYNC_CLOSED` (`0x02`) byte, unlinks the Unix socket, and exits.
- Modified `session.rs` to support `ActorCommand::ExtractHandoverState`, session serialization, live session clearing, and session adoption.
- Reconstructed virtual terminal memory and scrollback by replaying the session log file directly on adoption.
- Updated `main.rs` to parse `--handover` / `-U`, perform handover client fetches, adopt inherited sessions and TCP listeners, and synchronize phase transitions.
- Created `handover_tests.rs` containing a fully automated end-to-end integration test suite verifying zero-downtime process handover and shell continuity on Unix.
- Resolved platform view Shadow DOM CSS isolation by injecting `xterm.css` via a `LinkElement` directly inside the shadow container element.
- Deferred xterm.js initial content writing and cursor positioning until after the first successful fit layout (non-zero `clientWidth` and `clientHeight`), and implemented a live write buffer to guarantee chronological execution order, preventing cursor offsets caused by temporary size mismatches (80x24 vs actual container size).
- Mapped absolute cursor scrollback coordinates to viewport-relative indices by dynamically subtracting viewport offset in the web client, resolving multi-row viewport offsets and handling layout size transitions.
- Trimmed trailing whitespace from fallback rows before writing to xterm.js, preventing empty-cell wrapping glitches during container resizes.
- Fixed cached terminal wrapper lookup type-safety by identifying the `DivElement` wrapper explicitly, preventing cast exceptions on prepended `LinkElement` instances during session swaps.
- Refined exited session cursor clamping in the web client terminal view by restoring the conditional check `C > lastActiveRow`, preventing valid cursors from being overwritten by false prompt detections on status rows (such as in TUI sessions).
- Implemented static terminal redrawing on every layout fit/resize for exited sessions, guaranteeing that the viewport and cursor are always perfectly aligned and preventing empty viewports caused by intermediate layout ticks during widget rendering transitions.

## Decisions

- Target true zero-downtime process handover specifically for Unix-like platforms (Linux and WSL, covering the user's WSL environment). Native Windows installations will fall back gracefully to the existing robust **Session Restore** flow.
- Use a strict **Three-Phase Chronological Sync Protocol** to eliminate concurrent PTY read races in the OS kernel PTY line discipline.
- Use log-replay to reconstruct virtual terminal states in memory, avoiding non-serializable screen memory structures.
- Pass the **active bound TCP listener socket itself** over the Unix socket via `SCM_RIGHTS` to achieve zero-downtime port binding.

## Commits

- HEAD — feat(handover): implement zero-downtime process handover upgrades on Unix

## Progress

- 2026-05-24T17:48-0700 — Created fix worktree and set up the branch plan and task checklist.
- 2026-05-25T01:05-0700 — Completed full implementation of low-level FFI FD passing, three-phase sync, session serialization/adoption, pre-bound TCP listener injection, and integration test suite. Passed all tests, formatting, and clippy lints successfully.
- 2026-05-24T18:28-0700 — Addressed portable_pty supertrait ChildKiller bound and Error variants for Unix target, fixing CI build.
- 2026-05-24T18:31-0700 — Updated handover child trait methods to return std::io::Result to perfectly match the portable_pty specifications.
- 2026-05-24T18:35-0700 — Allowed unsafe_code in triaged crate, implemented missing MasterPty methods, and removed unused imports to satisfy clippy.
- 2026-05-24T18:38-0700 — Changed portable_pty::Error references to anyhow::Error and removed unused imports in handover.rs to resolve clippy.
- 2026-05-24T18:41-0700 — Removed try_clone_killer from Child implementation for AdoptedChild because it is not part of the portable_pty::Child trait.
- 2026-05-24T18:45-0700 — Refactored static mutable globals in triaged to safe Mutex and AtomicI32 containers, removing unsafe blocks and ensuring compliance with Rust 2024.
- 2026-05-24T18:48-0700 — Collapsed nested if let chains, migrated from io::Error::new to io::Error::other, resolved manual slice size calculation, and fixed macOS socket FFI type mismatches.
- 2026-05-24T19:15-0700 — Addressed PR comments by refactoring session serialization to preserve supervising actors if handshake fails, and hardened SCM_RIGHTS FD passing with length prefixing and dynamic buffer allocation.
- 2026-05-25T04:45-0700 — Solved web terminal styling isolation inside Shadow DOM and deferred initial writing to eliminate the 3-row cursor offset layout bug. Recompiled and verified serving locally.
- 2026-05-25T04:49-0700 — Fixed an async timing regression by adding a live write buffer that holds incoming WebSocket data until after the terminal has been fully fitted and the initial content written.
- 2026-05-25T04:52-0700 — Fixed the absolute cursor row offset bug by converting absolute scrollback coordinates to visible viewport-relative indices using `styled_rows_start`.
- 2026-05-25T05:03-0700 — Solved viewport width wrapping glitches by dynamically stripping trailing whitespace spans from fallback rows before writing to xterm.js, and added unit tests validating this behavior.
- 2026-05-25T05:08-0700 — Fixed a type cast exception when retrieving cached terminal wrappers by using type-safe element identification (`firstWhere`).
- 2026-05-24T22:20-0700 — Prevented premature first-fit execution on small temporary layout dimensions and made terminal web input transmission non-blocking and fire-and-forget, eliminating cursor displacement and connection drop-outs.
- 2026-05-24T22:30-0700 — Prevented empty trailing lines from scrolling active text (welcome/prompt) out of the viewport on smaller terminal screens by restricting initial grid rendering and cursor offsets up to the last active row index.
- 2026-05-25T07:25-0700 — Resolved active session cursor misalignment by restricting prompt-based cursor clamping exclusively to exited sessions, restoring true daemon-reported coordinates for active shells and TUIs (Session 11 and 13).
- 2026-05-24T22:44-0700 — Resolved viewport scrolling and cursor range errors on existing sessions by mapping absolute cursor coordinates to relative indices in main.dart and using windowed initial content writing in terminal_pane_web.dart.
- 2026-05-24T22:47-0700 — Aligned exited session viewports and cursor placement to the last active prompt line, implemented robust ANSI-based cursor show/hide (\x1b[?25l/\x1b[?25h) to disable dead caret blocks completely, and added automated test suite validating coordinate clamping.
- 2026-05-25T06:56-0700 — Refined exited session cursor clamping to be conditional, implemented reset-and-rewrite on fit layout ticks for exited sessions, and verified all 23 unit/widget tests passed.
- 2026-05-25T14:14-0700 — Restored secure token authentication and refined web prompt clamping to unconditionally cover active/attached sessions and robustly ignore TUI status row text.
- 2026-05-25T14:21-0700 — Resolved active session layout shift by tracking fitted rows/cols changes and rewriting replayed log dynamically before live output arrives, and refined cursor column calculations to preserve single trailing prompt spaces.
- 2026-05-25T07:40-0700 — Solved persistent cursor misalignment on active sessions by passing isExited field to TerminalPane, enabling unconditional virtual cursor clamping for both active and exited sessions, and introducing look-ahead checking for intermediate empty and status/divider rows to prevent editor layout breakages.
