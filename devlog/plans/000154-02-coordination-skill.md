# 000154-02 — Coordination skill + label-aware MCP list

## Thinking

Session messaging is live on this branch, but agents have no know-how for
using it, and they cannot even address each other: the user distinguishes
sessions by label, yet custom labels are invisible over MCP today. The
daemon stores them (`SessionManager.custom_labels`, readable via
`SessionApi::get_rail_layout`), the websocket transport serves them to
remote clients, but the local IPC and MCP layers never exposed them.

Why enrich `list_sessions` instead of adding a `get_rail_layout` MCP tool:
the skill's core loop is list-then-match-then-send, and one call returning
id + label + snapshot keeps label matching to a single round-trip. The
addition is a purely additive JSON field, so existing consumers don't
break. IPC still needs the `GetRailLayout` variant pair underneath,
mirroring the messaging IPC step exactly (`IpcClient` method + dispatch
arm + socket test).

Why read-only: the user assigns labels in the UI; agents only need to read
them to route mail. A set-label MCP tool would need its own IPC variant
and trust discussion — out of scope.

Why mirror `install.sh` from agent-review-loop: the user asked for that
pattern explicitly. Same five targets (canonical `~/.agents/skills` plus
Muse/Claude/Codex/Antigravity), same `--link`/`--upgrade`/`--dry-run`
semantics, same fake-HOME `tests/verify-install.sh`. No refinements file:
this skill keeps no shared learnings. One skill only
(`triage-coordination`): the ask is coordination know-how, not a skill per
tool.

The MCP READMEs also still claim the server is read-only, which the
messaging tools already broke. This plan updates those docs and the tools
table (messaging tools + `custom_label`) as part of the same commit.

## Plan

1. **IPC** (`crates/triaged/src/ipc.rs`)
   - `WireRequest::GetRailLayout` + `WireSuccess::RailLayout(RailLayout)`;
     `IpcClient::get_rail_layout`; server dispatch arm.
   - Tests: extend the socket coverage (assert layout round-trips over a
     spawned server; labels set via the manager are visible to the client).

2. **MCP** (`crates/triage-mcp/src/main.rs`)
   - `list_sessions` items gain `"custom_label": <string|null>` from
     `api.get_rail_layout()`, keyed by session id.
   - Fake gains a layout; tests: label present/absent; existing
     `list_sessions` test keeps passing.
   - Update `crates/triage-mcp/README.md` (tools table + read-only claim)
     and the root README's read-only line.

3. **Skill** (`skills/triage-coordination/`)
   - `SKILL.md` (name + description frontmatter): when to use, the
     discover-by-label loop, send/poll/ack protocol with etiquette
     (poll, don't spin; ack promptly; keep bodies short; identify self),
     fallback matching (repo/branch/worktree/cwd/snippet) when no custom
     label is set, and the known limits (in-memory inboxes, caller-
     asserted sender, no push).
   - `agents/openai.yaml` interface stub mirroring the pattern.

4. **Installer** (`install.sh`, `tests/verify-install.sh`)
   - Mirror agent-review-loop's structure minus refinements; verify with a
     fake HOME, link mode, upgrade mode, and dry-run.

5. **Validation**
   - `cargo fmt --check`, clippy `-D warnings`, affected Rust suites,
     `tests/verify-install.sh`, then commit + push to PR #181.
