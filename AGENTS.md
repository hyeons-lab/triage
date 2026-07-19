# Triage — Project Conventions for Coding Agents

Triage is an attention-routing terminal supervisor: a long-running Rust daemon, a Ratatui local TUI, a Flutter remote client (web / iOS / Android / optional desktop), and an MCP server, all sharing one session API. The full design doc lives at `devlog/triage-design-doc.md`.

## Repository layout

- `crates/` — Cargo workspace
  - `triage-core` — session trait and shared types (every other crate depends on this)
  - `triaged` — long-running process; owns all session state
  - `triage` — Ratatui local client (terminal-mode)
  - `triage-transport-ws` — WebSocket transport adapter, server-side (consumed by remote clients)
  - `triage-mcp` — MCP server (stdio + optional TCP)
- `flutter/triage_client/` — Flutter app (scaffolded after the local daemon/TUI and remote web path are proven)
- `devlog/` — checked-in design notes, branch devlogs, and per-task plans.
- `worktrees/` — gitignored.

## Devlog conventions

Devlogs are checked in. Write devlog files at the repository root (`devlog/`) within your current worktree so they can be included in your branch commits.

- **Branch devlog:** `devlog/NNNNNN-<branch-name>.md` — one file per branch. `NNNNNN` is a zero-padded 6-digit sequence (check the highest in `devlog/` and increment). `<branch-name>` is the git branch with `/` replaced by `-`.
- **Plan file:** `devlog/plans/NNNNNN-NN-<description>.md`. `NN` is the per-branch plan sequence (01, 02, ...). Plan files use `## Thinking` then `## Plan` sections; plans are append-only.
- Branch devlogs use these sections (omit if empty): **Agent**, **Intent**, **What Changed**, **Decisions**, **Issues**, **Commits**, **Progress**, **Research & Discoveries**, **Lessons Learned**, **Next Steps**.
- Timestamps are ISO 8601 with UTC offset, e.g. `2026-05-11T12:58-0700`. Get the real time with `date "+%Y-%m-%dT%H:%M%z"`. Never fabricate or use placeholders like `00:00`.
- Track *why*, not just *what* — capture reasoning, not file diffs.
- Append-only across sessions: append to existing sections; don't rewrite or split into per-session subsections.
- Never log secrets, tokens, private URLs, personal filesystem paths, or private personal details. Use placeholders like `<API_KEY>` or `<local-path>`.

### Commits section — HEAD rule

The latest commit on the branch is always recorded as `HEAD — message`. **Never replace `HEAD` with the real hash.** When the *next* commit is made, the previous `HEAD` entry is updated to its real hash (with `git log --format="%h" -2 HEAD | tail -1`) as part of preparing that new commit, and the new commit becomes `HEAD`. Recording the hash on the same commit it refers to would require amending, which changes the hash — a self-reference loop.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[optional scope]: <description>

[optional body]
```

Common types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `ci`, `chore`, `build`, `perf`.

## Branching and worktrees

- Never commit directly to `main`. All changes go through PRs.
- Every feature uses a git worktree — no direct branch switching in the main checkout.
- The main checkout stays on `main` and is used only for worktree creation and housekeeping.
- Create a worktree:
  ```bash
  # From the main checkout (on main branch)
  git fetch origin
  git worktree add worktrees/<branch-name> -b <type>/<branch-name> origin/main
  cd worktrees/<branch-name>
  git branch --unset-upstream
  ```
  `--unset-upstream` is required because git auto-tracks `origin/main` when branching from a remote ref — a push without it would target `main`. The correct upstream is set on the first `git push -u origin <type>/<branch-name>`.
- After PR merges, clean up from the main checkout:
  ```bash
  git worktree remove worktrees/<branch-name>
  git branch -d <type>/<branch-name>
  git pull origin main
  ```

## Plan-first workflow

Before writing code on a new branch:

1. Create the worktree (above).
2. Create a branch devlog: `devlog/NNNNNN-<branch-name>.md`.
3. Create a plan file: `devlog/plans/NNNNNN-NN-<description>.md`.
4. Write code, format, validate, update the devlog, then commit and push.
5. Open a PR via `gh pr create` (use `--draft` when work isn't review-ready).
6. Update the PR description to match the final commit body.

## Minimizing CI Pushes

Every push to GitHub triggers CI. CI runs are expensive — minimize waste:

- Update the devlog before committing — including the Commits section — so it reflects the commit before it lands.
- Batch related commits before pushing. Don't push after every commit.
- Prefer amending or fixup before pushing if you catch a mistake before push.
- Exception: push immediately when you need CI feedback on a specific change (e.g., testing a CI fix). Still bundle with any pending local commits.

## Build and test commands

- `cargo fmt --all -- --check` — format check (use `cargo fmt --all` to apply)
- `cargo clippy --all-targets --all-features -- -D warnings` — lint with warnings denied
- `cargo check --workspace` — type-check the whole workspace
- `cargo test --workspace` — run all tests
- `cargo run -p triaged` — start the daemon (writes to `$HOME/.local/state/triage/triaged.log`)

### Embedded web client

`triaged` embeds the Flutter web client, and its build script keeps that bundle current
so a build can't quietly ship a stale UI:

- A staged `crates/triaged/dist/` (what `publish.yml` produces) always wins and is never rebuilt.
- Otherwise, if any source under `flutter/triage_client/` (`lib/`, `web/`, `assets/`, `fonts/`,
  `pubspec.yaml`, `pubspec.lock`) is newer than `flutter/triage_client/build/web`, the build
  script runs `flutter build web --release` — matching the release build — before compiling.
- With no Flutter SDK on `PATH` (the Rust-only CI job) or no client sources (a crates.io
  tarball), it warns and builds against whatever bundle is present.
- `TRIAGE_SKIP_FLUTTER_BUILD=1` skips the rebuild and uses the existing bundle. Use it for a
  fast Rust-only iteration loop when you aren't touching Dart.

A failing `flutter build web` fails the cargo build rather than silently falling back.

## Versioning and releases

- The repo version is a single source of truth in the top-level `VERSION` file.
- To change it, run `scripts/bump-version.sh <X.Y.Z>` — it writes `VERSION` and propagates
  the number to `Cargo.toml` (`[workspace.package].version`, inherited by every crate via
  `version.workspace = true`, plus the internal `[workspace.dependencies]` pins), refreshes
  `Cargo.lock`, and updates `flutter/triage_client/pubspec.yaml` (the build name; the `+N`
  build suffix is preserved). The Flutter build name surfaces in the desktop About panel.
- Run with no argument to re-sync all files to the current `VERSION`; run `--check` to
  verify there is no drift without writing (suitable for CI).
- The publish workflow reads the version from `cargo metadata` (the `triaged` crate), so
  Cargo remains authoritative for the `v<X.Y.Z>` tag and release assets; the script just
  keeps `VERSION`, Cargo, and the Flutter client in lockstep.
- Don't hand-edit version literals across these files — use the script so they can't drift.

## Style

- No AI slop. Keep prose neutral and factual — no pitch-deck framing, epigraphs, or second-person scene-setting.
- Only add code comments when the *why* is non-obvious. Don't narrate what the code does.
- Don't add features, abstractions, or error handling beyond what the task requires.

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes` or `query_graph` instead of Grep
- **Understanding impact**: `get_impact_radius` instead of manually tracing imports
- **Code review**: `detect_changes` + `get_review_context` instead of reading entire files
- **Finding relationships**: `query_graph` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview` + `list_communities`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
| ------ | ---------- |
| `detect_changes` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context` | Need source snippets for review — token-efficient |
| `get_impact_radius` | Understanding blast radius of a change |
| `get_affected_flows` | Finding which execution paths are impacted |
| `query_graph` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes` | Finding functions/classes by name or keyword |
| `get_architecture_overview` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes` for code review.
3. Use `get_affected_flows` to understand impact.
4. Use `query_graph` pattern="tests_for" to check coverage.
