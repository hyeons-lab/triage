# Plan 000192-01: Clean TUI Side Rail Identity and Metadata

## Thinking

The Ratatui side rail in `crates/triage/src/main.rs` currently renders each session using raw internal identifiers, terminal dimensions, and redundant single-letter path rows:
1. Row 1: `> session-23 🤖  running` (`view.session_id`, emoji judge badge that falls back to `*` in limited console fonts, and literal `running` repeated for every live session).
2. Row 2: `  interactive  92x29` (`holder` plus `cols x rows`, which is identical across every session because `LocalSessionApp` resizes sessions to the TUI viewport).
3. Context rows: `  r <repo>`, `  w <worktree>`, `  b <branch>`, or `  c <cwd leaf>` (showing `c System32` repeatedly on Windows service-launched shells with no git context), plus empty spacer lines whenever repo or branch is absent.

Meanwhile `SessionSnapshot` and `SessionApi` already provide `custom_labels` (`get_rail_layout`), `snippet` (`snapshot.snippet` and `list_session_snippets`), `agent`, `context`, `pending_approval`, `pending_approval_reason`, and `exited`, none of which the TUI side rail uses effectively.

Design choices:
- Sync `custom_label` on `SessionView` (from `get_rail_layout()` on startup and via a background metadata poller in `IpcClient` mode, alongside `list_session_snippets()` so background session snippets stay current without blocking the UI loop). Also preserve overlaid `snippet` / `snippet_detail` / `pending_approval` across actor push snapshots in `merge_push_snapshot`.
- Replace raw `session-NN * running`, `interactive 92x29`, and `c system32` with concise, human-meaningful cards matching the Flutter rail's prioritization:
  - **Row 1 (Title + notable state)**: `custom_label` > distinct git worktree leaf > non-default git branch (`main`/`master` deferred to repo name when repo exists so sibling repos stay distinct) > repo name > meaningful non-system cwd leaf > `agent` name > `session_id`. Append `[exit]` only when `exited`, `[!]` when `pending_approval`, and ASCII judge tags (`[auto]` / `[ask]` or compact `[A]` / `[U]`) only when an agent is active or an explicit per-session override is set, avoiding emoji glyph fallback (`*`).
  - **Row 2 (Compact meta, omitted when empty)**: deduplicated ` · `-joined summary of `agent` badge (plus `agent` lease indicator if held), repo/branch context not already on Row 1, or meaningful cwd leaf (suppressing system boilerplate dirs like `System32` / `SysWOW64` / bare roots). Never emit `interactive` or `cols x rows`, and never emit blank placeholder rows inside a card.
  - **Row 3 (Activity/attention, omitted when empty)**: `pending_approval_reason` (prefixed with `! `) when awaiting approval, else `snapshot.snippet`.
  - Keep marquee horizontal scrolling on selected overflowing titles/snippets and update unit tests across `crates/triage`.

## Plan

1. Add `custom_label: Option<String>` to `SessionView` in `crates/triage/src/lib.rs`, load initial `custom_labels` (via `get_rail_layout()`) and snippets (via `list_session_snippets()`, best-effort) on `attach_existing_sessions` / refresh, preserve overlaid fields in `merge_push_snapshot`, and poll rail metadata (`RailLayout` custom labels + `list_session_snippets`) off the UI thread in `IpcClient` mode.
2. Redesign `session_sidebar_rows`, `selected_sidebar_context_overflows`, and helper formatting functions in `crates/triage/src/main.rs` to render clean 1-to-3 line cards without `session-NN` (when better identity exists), `* running`, `interactive NxM`, `c system32`, or empty context spacer lines.
3. Update existing sidebar unit tests in `crates/triage/src/main.rs` and add unit tests in `crates/triage/src/lib.rs` and `crates/triage/src/main.rs` covering title precedence, `System32` suppression, agent/context deduplication, `snippet` and `pending_approval` rows, custom labels, and ASCII judge badges.
4. Run `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`, `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --all-features --no-deps --locked`, and `cargo test -p triage --locked`.
